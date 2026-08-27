import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// §O2's per-op decode and §O3's framing, against input the peer chose. Two layers, and the split
// is deliberate:
//
// * **`CompactWireCodec.decode(_:)` directly** for the questions that are about the *encoding* --
//   which blast radius a rejection gets, what a declared length is checked against, where the
//   field-list boundary is;
// * **an `RPCTransportCore` over a ``TestPipe``** for the questions that are about the *core's
//   answer* -- that the clean ops around a rejected one still route, that a malformed `openStream`
//   is answered with a fixed literal, that a cancel reason is bounded before it goes back out.
//
// Every input here is built by ``RawOpBytes``, by hand, from §O3's layout -- **not** by the encoder
// under test. A hostile-input test whose input came from the encoder could only ever produce input
// the encoder considers valid, which is the one thing the tests need not to be.
//
// Several cases run against ``RawOpBytes/offsetBlob(_:leadingPadding:)``, a blob whose bytes do not
// start at index 0. `GRPCSwiftData` indices do not rebase to zero and in production the codec's
// input is always a slice of a received XPC payload, so an offset input is what distinguishes a
// correct offset from a hardcoded one.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class WireProtocolTests: XCTestCase {

    private static let codec = CompactWireCodec()
    private static let method = "xpc.flowcontrol.Wire/Push"

    private static func open(_ core: CoreUnderTest, _ id: RPCStreamID) throws {
        try core.pipe.deliver([.openStream(id, method: method, timeout: nil)])
    }

    /// Renders a decode result so a failure names what came back rather than "not equal".
    private static func describe(_ items: [WireDecodeItem]) -> [String] {
        items.map { item in
            switch item {
            case .op(let op): return "op(\(op.testDescription))"
            case .streamFailure(let id, _): return "streamFailure(\(id))"
            case .streamOpenFailure(let id, _): return "streamOpenFailure(\(id))"
            }
        }
    }

    // =======================================================================================
    // MARK: - Blast radius: a body rejection is not a connection failure
    // =======================================================================================

    /// §O2's amendment, at both layers: **a body-level rejection fails that stream, and the cleanly
    /// decoded ops before *and after* it still route.**
    ///
    /// The "after" half is what makes this more than a restatement. Stopping at the first failure
    /// would hand a hostile peer a truncation lever -- one malformed op appended to a blob would
    /// silently discard every other stream's legitimate traffic in it -- so `decode(_:)` is
    /// skip-and-continue, advancing past a rejected body with the same `bodyLength` the header
    /// already gave up.
    ///
    /// One blob, three streams: a legal `metadata` for 1, an illegal (non-empty-bodied) `halfClose`
    /// for 3, a legal `message` for 5. Then the same blob through the core, where the observable is
    /// that stream 5's application half really received its message while stream 3 was cancelled.
    func testABodyRejectionFailsThatStreamAndTheCleanOpsAroundItStillRoute() throws {
        let blob = RawOpBytes.offsetBlob(
            RawOpBytes.op(.metadata, streamID: 1, body: RawOpBytes.fieldList([]))
                // A `halfClose` body MUST be empty. This one is not, which is one of the three
                // shapes §O2's review found killing every other stream on the connection.
                + RawOpBytes.op(.halfClose, streamID: 3, body: Data([0x01]))
                + RawOpBytes.op(.message, streamID: 5, body: Data(repeating: 0x5A, count: 40)))

        let items = try Self.codec.decode(blob)
        XCTAssertEqual(
            Self.describe(items),
            ["op(metadata(1, []))", "streamFailure(3)", "op(message(5, 40 byte(s)))"],
            "the rejected op must become an item naming its own stream, and both neighbours must "
                + "still decode")

        try runBounded("a body rejection at the core", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "blast-radius")
            defer { core.shutDown() }

            for id: RPCStreamID in [1, 3, 5] { try Self.open(core, id) }
            try await core.waitForAccepts(3)
            let survivor = try XCTUnwrap(core.acceptedStream(5))
            _ = core.pipe.takeSentOps()

            core.pipe.deliverRaw(blob)

            let ops = core.pipe.takeSentOps()
            XCTAssertEqual(
                ops.cancels(forStream: 3).count, 1,
                "the rejected stream must be cancelled; got \(ops.testDescriptions)")
            XCTAssertEqual(ops.cancels(forStream: 1), [], "stream 1's op was legal")
            XCTAssertEqual(ops.cancels(forStream: 5), [], "stream 5's op was legal")
            XCTAssertEqual(
                core.core.liveStreamCount, 2,
                "exactly one stream may have been removed")
            XCTAssertFalse(
                core.pipe.isCancelled,
                "a body-level rejection must never fail the connection")

            // The op *after* the rejection genuinely reached its application half.
            var iterator = survivor.stream.inbound.makeAsyncIterator()
            _ = try await iterator.next()                    // the synthesised leading metadata
            let delivered = try await iterator.next()
            guard case .message(let body) = delivered else {
                return XCTFail("expected a message part, got \(String(describing: delivered))")
            }
            XCTAssertEqual(body.count, 40)
        }
    }

    /// A **header**-level failure is connection-fatal, and takes the whole blob with it.
    ///
    /// Three shapes, all of them a declared length the codec cannot trust: a truncated 10-byte
    /// header, a declared body length over the 16 MiB cap, and a declared body length past the
    /// bytes actually remaining. None leaves a stream id to attribute a failure to (the header that
    /// would name one is what did not parse) and none leaves framing to resynchronise to.
    ///
    /// The last case in the list is the important one for hostile input: the length is checked
    /// **before** it is used to slice. A codec that sliced first would trap, not throw -- so the
    /// observable "it threw an `RPCError`" is also the observable "it did not crash".
    func testAHeaderLevelFailureIsConnectionFatalAndDiscardsTheWholeBlob() throws {
        let legal = RawOpBytes.op(.message, streamID: 1, body: Data(repeating: 0x11, count: 20))

        let cases: [(label: String, blob: GRPCSwiftData)] = [
            ("a truncated header", RawOpBytes.offsetBlob(Data([0x03, 0x00, 0x00, 0x00, 0x01]))),
            (
                "a legal op followed by a truncated header",
                RawOpBytes.offsetBlob(legal + Data([0x03, 0x00, 0x00]))
            ),
            (
                "a declared body length over the 16 MiB cap",
                RawOpBytes.offsetBlob(
                    RawOpBytes.op(
                        .message, streamID: 1, body: Data(),
                        declaredBodyLength: UInt32(CompactWireCodec.maxBodyLength + 1)))
            ),
            (
                "a declared body length past the bytes remaining",
                RawOpBytes.offsetBlob(
                    RawOpBytes.op(
                        .message, streamID: 1, body: Data(repeating: 0x22, count: 10),
                        declaredBodyLength: 1_000))
            ),
            (
                "a malformed goAway body (§O2's carve-out: no stream to name)",
                RawOpBytes.offsetBlob(RawOpBytes.op(.goAway, streamID: 0, body: Data([0x01, 0x02])))
            ),
        ]

        for (label, blob) in cases {
            do {
                let items = try Self.codec.decode(blob)
                XCTFail("\(label): decode returned \(Self.describe(items)) instead of throwing")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .internalError, label)
            } catch {
                XCTFail("\(label): threw \(type(of: error)) rather than an RPCError")
            }
        }

        try runBounded("a header failure at the core", timeout: 20) {
            let core = CoreUnderTest(role: .server, label: "header-failure")
            defer { core.shutDown() }

            try Self.open(core, 1)
            try await core.waitForAccepts(1)
            let victim = try XCTUnwrap(core.acceptedStream(1))
            _ = core.pipe.takeSentOps()

            core.pipe.deliverRaw(RawOpBytes.offsetBlob(legal + Data([0x03, 0x00, 0x00])))

            XCTAssertTrue(
                core.pipe.isCancelled,
                "an undecodable blob must fail the connection: the framing cannot be "
                    + "resynchronised")

            var iterator = victim.stream.inbound.makeAsyncIterator()
            var thrown: (any Error)?
            do {
                while try await iterator.next() != nil {}
            } catch {
                thrown = error
            }
            let error = try XCTUnwrap(thrown as? RPCError)
            XCTAssertTrue(
                error.message.contains("undecodable blob"),
                "expected the connection-level framing error; got '\(error.message)'")
        }
    }

    // =======================================================================================
    // MARK: - The fixed-literal refusal
    // =======================================================================================

    /// **A malformed `openStream` is answered with a fixed literal whose size is independent of the
    /// input.**
    ///
    /// `openStream` is the one kind whose body-level rejection is *answered* rather than dropped,
    /// because it is the one kind whose semantics create state: the peer owns the id the moment it
    /// sends the op and is definitionally waiting on a reply. But rejecting it never creates a table
    /// entry, so the peer can trigger the reply as many times as it likes for free -- and the decode
    /// error can embed up to 16 MiB of peer-chosen bytes. Echoing even a *truncated* form of it
    /// would still let the peer's input size drive the reply's size, repeatably.
    ///
    /// The test is therefore not "the reply is short", it is **"the reply is byte-identical"**: two
    /// cores, same stream id, one fed a 12-byte malformed `openStream` and the other fed one whose
    /// `:path` fills the entire 16 MiB body cap. A reply whose size depended on the input in any
    /// way at all -- including through a truncation that kept a prefix -- fails this.
    func testAMalformedOpenStreamRefusalIsAFixedLiteral() throws {
        // Twelve bytes total: a 10-byte header and a 2-byte body declaring 65 535 fields, which
        // cannot possibly fit. The cheapest malformed `openStream` there is.
        let tinyBody = RawOpBytes.fieldList([], declaredCount: 0xFFFF)
        let tiny = RawOpBytes.op(.openStream, streamID: 1, body: tinyBody)
        XCTAssertEqual(tiny.count, 12, "this case's whole point is that the input is 12 bytes")

        // A `:path` with no `/` in it is malformed, and this one is as large as §O3's 16 MiB body
        // cap allows: the field list's own overhead for a single `:path` field is 13 bytes
        // (2-byte count, 2-byte name length, 5-byte name, 4-byte value length).
        let fieldListOverhead = 13
        let hugePath = String(repeating: "p", count: CompactWireCodec.maxBodyLength - fieldListOverhead)
        let hugeBody = RawOpBytes.fieldList([(":path", hugePath)])
        XCTAssertEqual(
            hugeBody.count, CompactWireCodec.maxBodyLength,
            "the huge case must sit exactly on the body cap, not over it -- over it would be a "
                + "header-level failure and a different test")
        let huge = RawOpBytes.op(.openStream, streamID: 1, body: hugeBody)

        // Both are body-level rejections attributed to the same stream, not thrown.
        XCTAssertEqual(
            Self.describe(try Self.codec.decode(RawOpBytes.offsetBlob(tiny))),
            ["streamOpenFailure(1)"])
        XCTAssertEqual(
            Self.describe(try Self.codec.decode(RawOpBytes.offsetBlob(huge))),
            ["streamOpenFailure(1)"],
            "a malformed `:path` must be a stream-open failure, not a connection failure")

        func refusal(for input: Data, label: String) throws -> [GRPCSwiftData] {
            let core = CoreUnderTest(role: .server, label: label)
            defer { core.shutDown() }
            core.pipe.deliverRaw(RawOpBytes.offsetBlob(input))
            XCTAssertEqual(
                core.core.liveStreamCount, 0,
                "\(label): a refused open must create no table entry -- that is why the reply has "
                    + "to be a fixed literal")
            return core.pipe.sentBlobs
        }

        let tinyReply = try refusal(for: tiny, label: "refuse-tiny")
        let hugeReply = try refusal(for: huge, label: "refuse-huge")

        XCTAssertEqual(tinyReply.count, 1, "exactly one blob goes back")
        XCTAssertEqual(
            tinyReply, hugeReply,
            "the refusal for a 16 MiB `:path` is not byte-identical to the refusal for a 12-byte "
                + "op, so the peer's input size drives the reply's size")

        // And it is the documented shape, so this cannot pass on two identically-broken replies.
        let decoded = try Self.codec.decode(try XCTUnwrap(tinyReply.first))
        XCTAssertEqual(
            Self.describe(decoded),
            ["op(status(1, code: \(Status.Code.invalidArgument.rawValue), message: malformed openStream, trailers: 0))"],
            "the refusal must be `status(.invalidArgument, \"malformed openStream\")`")
    }

    // =======================================================================================
    // MARK: - Unknown kinds, and reserved flags
    // =======================================================================================

    /// §O3's forward-compatibility rule: **an unknown `kind` is skipped by its declared body
    /// length**, and `flags` is ignored on receive.
    ///
    /// This is the whole mechanism by which the encoding can grow without breaking an older peer,
    /// and the only thing that makes it work is that the skip uses the same `bodyLength` advance a
    /// rejected body uses. A codec that skipped a fixed number of bytes, or that stopped, would
    /// pass a test that only fed it *one* unknown op -- so the unknown op here is sandwiched between
    /// two legal ones with a body long enough that a wrong advance lands mid-op.
    func testAnUnknownOpKindIsSkippedByItsDeclaredBodyLength() throws {
        let blob = RawOpBytes.offsetBlob(
            RawOpBytes.op(.metadata, streamID: 1, body: RawOpBytes.fieldList([]))
                + RawOpBytes.op(kind: 99, streamID: 7, body: Data(repeating: 0xAB, count: 37))
                // `flags` is reserved: this codec writes 0 and must ignore whatever it reads.
                + RawOpBytes.op(
                    .message, streamID: 1, body: Data(repeating: 0x33, count: 12), flags: 0xFF))

        XCTAssertEqual(
            Self.describe(try Self.codec.decode(blob)),
            ["op(metadata(1, []))", "op(message(1, 12 byte(s)))"],
            "an unknown kind must be skipped silently by its body length, and reserved flags must "
                + "be ignored rather than rejected")

        // A zero-length unknown op is the degenerate case: the advance is the header alone.
        XCTAssertEqual(
            Self.describe(
                try Self.codec.decode(
                    RawOpBytes.offsetBlob(
                        RawOpBytes.op(kind: 200, streamID: 0, body: Data())
                            + RawOpBytes.op(.halfClose, streamID: 3, body: Data())))),
            ["op(halfClose(3))"])
    }

    // =======================================================================================
    // MARK: - The field-list boundary
    // =======================================================================================

    /// The `decodeFieldList` minimum-length guard is **exact, not approximate**.
    ///
    /// A declared field count needs at least `6 * count` bytes (a 2-byte name length, a 0-byte name,
    /// a 4-byte value length, a 0-byte value is the smallest possible field), and the guard exists
    /// so that a 12-byte `metadata` op declaring 65 535 fields cannot make `reserveCapacity` reserve
    /// ~2 MiB before throwing on field 1 -- once per such op in the blob, since §O2's
    /// skip-and-continue means decoding resumes after each rejection.
    ///
    /// So the boundary has to be tested from *both* sides, and this is the test that would catch an
    /// off-by-one that turned a legitimate maximal field list into a rejection:
    ///
    /// * `2 + 6 × 65 535` bytes carrying 65 535 empty fields **decodes**;
    /// * one byte short **throws** (as a stream-scoped rejection, `metadata` being the kind).
    func testTheFieldListMinimumLengthBoundaryIsExact() throws {
        let count = 65_535
        var body = Data()
        RawOpBytes.appendBE(UInt16(count), to: &body)
        for _ in 0..<count {
            RawOpBytes.appendBE(UInt16(0), to: &body)   // a zero-length name
            RawOpBytes.appendBE(UInt32(0), to: &body)   // a zero-length value
        }
        XCTAssertEqual(body.count, 2 + 6 * count, "2 + 6 x 65 535 = 393 212")

        let items = try Self.codec.decode(
            RawOpBytes.offsetBlob(RawOpBytes.op(.metadata, streamID: 1, body: body)))
        guard items.count == 1, case .op(.metadata(let id, let fields)) = items[0] else {
            return XCTFail(
                "a maximal 65 535-field list must decode; got \(Self.describe(items))")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(fields.count, count)
        XCTAssertEqual(fields.first?.name, "")
        XCTAssertEqual(fields.first?.value, "")

        // One byte short. The header's declared length is shortened with it, so this is the
        // field-list guard firing rather than a header-level failure.
        let short = body.dropLast()
        let shortItems = try Self.codec.decode(
            RawOpBytes.offsetBlob(
                RawOpBytes.op(
                    .metadata, streamID: 1, body: short,
                    declaredBodyLength: UInt32(short.count))))
        XCTAssertEqual(
            Self.describe(shortItems), ["streamFailure(1)"],
            "one byte short of the minimum a 65 535-field list needs must be rejected")
        guard case .streamFailure(_, let error) = shortItems[0] else { return XCTFail() }
        XCTAssertTrue(
            error.message.contains("393210") && error.message.contains("393209"),
            "the rejection must name what was needed and what remained; got '\(error.message)'")
    }

    // =======================================================================================
    // MARK: - Hostile input: every peer-supplied length
    // =======================================================================================

    /// **Every peer-supplied length is checked against the bytes actually remaining before it is
    /// used to slice.** A missed check here is not a wrong answer, it is a trap -- `Data`'s
    /// subscript traps on an out-of-range slice -- so a *remote* trap, which is the worst outcome
    /// available on this surface.
    ///
    /// The observable for all of them is the same and is what makes this a single test: the codec
    /// **returned**, with a stream-scoped rejection, rather than trapping or throwing the whole
    /// connection away. Each row also has to be attributed to the right stream, or the core would
    /// answer (or not answer) about the wrong one.
    ///
    /// Every body here goes into a `metadata` op, whose rejection radius is one stream, so a row
    /// that mistakenly produced a *header*-level failure would show up as a thrown error and fail.
    func testEveryPeerSuppliedLengthIsCheckedBeforeSlicing() throws {
        var trailing = RawOpBytes.fieldList([("a", "b")])
        trailing.append(contentsOf: [0x00, 0x00])

        let bodies: [(label: String, body: Data)] = [
            ("an empty body -- no room for the 2-byte count", Data()),
            ("a 1-byte body -- the count itself is truncated", Data([0x00])),
            (
                "a declared count of 1 with only 5 bytes to hold it",
                RawOpBytes.fieldList([], declaredCount: 1) + Data([0, 0, 0, 0, 0])
            ),
            (
                "a name length past the end of the field list",
                Data([0x00, 0x01]) + Data([0xFF, 0xFF]) + Data([0x61])
            ),
            (
                "a truncated 4-byte value length",
                Data([0x00, 0x01]) + Data([0x00, 0x01]) + Data([0x61]) + Data([0x00, 0x00])
            ),
            (
                "a value length past the end of the field list",
                Data([0x00, 0x01]) + Data([0x00, 0x01]) + Data([0x61])
                    + Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data([0x62])
            ),
            ("trailing bytes after the declared field count", trailing),
            (
                "a non-UTF-8 field name",
                Data([0x00, 0x01]) + Data([0x00, 0x02]) + Data([0xFF, 0xFE])
                    + Data([0x00, 0x00, 0x00, 0x00])
            ),
            (
                "a non-UTF-8 field value",
                Data([0x00, 0x01]) + Data([0x00, 0x01]) + Data([0x61])
                    + Data([0x00, 0x00, 0x00, 0x02]) + Data([0xFF, 0xFE])
            ),
        ]

        for (label, body) in bodies {
            let blob = RawOpBytes.offsetBlob(
                RawOpBytes.op(.metadata, streamID: 9, body: body))
            var decoded: [String]?
            do {
                decoded = Self.describe(try Self.codec.decode(blob))
            } catch {
                XCTFail("\(label): decode threw \(error) instead of rejecting one stream")
            }
            XCTAssertEqual(decoded, ["streamFailure(9)"], label)
        }

        // The two fixed-width bodies, for completeness: `credit` must be exactly 4 bytes (a stream
        // rejection) and `goAway` must be exactly 4 (a connection failure, per §O2's carve-out).
        for length in [0, 3, 5] {
            XCTAssertEqual(
                Self.describe(
                    try Self.codec.decode(
                        RawOpBytes.offsetBlob(
                            RawOpBytes.op(
                                .credit, streamID: 9, body: Data(repeating: 0, count: length))))),
                ["streamFailure(9)"],
                "a \(length)-byte credit body must be rejected")
            XCTAssertThrowsError(
                try Self.codec.decode(
                    RawOpBytes.offsetBlob(
                        RawOpBytes.op(
                            .goAway, streamID: 0, body: Data(repeating: 0, count: length)))),
                "a \(length)-byte goAway body has no stream to fail and must be connection-fatal")
        }
    }

    /// The 16 MiB body cap, from both directions.
    ///
    /// On **decode** it is checked before the length is used for anything at all -- the blob here is
    /// 10 bytes long and merely *declares* 16 MiB + 1, so a codec that allocated first would either
    /// reserve 16 MiB or trap. On **encode** the same cap means this codec refuses to produce a blob
    /// its own decoder would reject, which is what keeps the two halves from disagreeing about what
    /// is legal.
    func testTheSixteenMiBBodyCapIsCheckedBeforeAnythingIsAllocated() throws {
        XCTAssertEqual(CompactWireCodec.maxBodyLength, 16 * 1024 * 1024)

        let declaresTooMuch = RawOpBytes.op(
            .message, streamID: 1, body: Data(),
            declaredBodyLength: UInt32(CompactWireCodec.maxBodyLength + 1))
        XCTAssertEqual(declaresTooMuch.count, RawOpBytes.headerLength)
        XCTAssertThrowsError(try Self.codec.decode(RawOpBytes.offsetBlob(declaresTooMuch))) { error in
            XCTAssertTrue(
                (error as? RPCError)?.message.contains("16 MiB") ?? false,
                "expected the body-cap rejection; got \(error)")
        }

        // Exactly at the cap is legal (declared *and* present), which is what makes the check a
        // boundary rather than a guess.
        let atTheCap = RawOpBytes.op(
            .message, streamID: 1, body: Data(repeating: 0x7E, count: CompactWireCodec.maxBodyLength))
        XCTAssertEqual(
            Self.describe(try Self.codec.decode(RawOpBytes.offsetBlob(atTheCap))),
            ["op(message(1, \(CompactWireCodec.maxBodyLength) byte(s)))"])

        // Encode refuses to produce what decode would reject.
        XCTAssertThrowsError(
            try Self.codec.encode([
                .message(
                    1,
                    payload: GRPCSwiftData(
                        repeating: 0x01, count: CompactWireCodec.maxBodyLength + 1))
            ]))
    }

    // =======================================================================================
    // MARK: - The cancel reason's bound
    // =======================================================================================

    /// `truncatedForWire(_:)` must bound **UTF-8 bytes, not grapheme clusters**.
    ///
    /// This truncated on `text.prefix(512)` until re-review, which bounds `Character`s -- and a
    /// `Character` has no length bound. One base character followed by four million combining marks
    /// is a **single** grapheme cluster, so a multi-megabyte peer value made of a handful of
    /// enormous clusters passed `prefix(512)` completely unchanged and went straight back out on a
    /// control op that is exempt from flow control.
    ///
    /// **A long-ASCII value does not discriminate here**: `prefix(512)` truncates that correctly
    /// too. So the input has to be the pathological one, and the assertion has to be on
    /// `utf8.count`.
    func testTheWireReasonBoundIsUTF8BytesNotGraphemeClusters() {
        let pathological = "a" + String(repeating: "\u{0301}", count: 4_000_000)
        XCTAssertEqual(
            pathological.count, 1,
            "the premise: four million combining marks are one grapheme cluster, so a "
                + "Character-based prefix would not truncate this at all")
        XCTAssertEqual(pathological.utf8.count, 1 + 2 * 4_000_000)

        let truncated = RPCTransportCore.truncatedForWire(pathological)
        let marker = "… [truncated]"
        // The bound is 512 bytes, plus the marker, plus a small measured allowance: the 512-byte
        // slice can land mid-scalar (here it splits the 256th combining mark), and
        // `String(decoding:as:)` substitutes one 3-byte U+FFFD for the maximal subpart rather than
        // failing -- which is the behaviour that keeps a truncation from ever throwing or falling
        // back to the untruncated string. Measured: 529 bytes out, i.e. 512 + 2 + 15.
        let replacementAllowance = 4
        XCTAssertLessThanOrEqual(
            truncated.utf8.count,
            RPCTransportCore.maxWireReasonLength + marker.utf8.count + replacementAllowance,
            "the cap must bound bytes: \(truncated.utf8.count) byte(s) came back from a "
                + "\(pathological.utf8.count)-byte input")
        XCTAssertTrue(truncated.hasSuffix(marker), "a truncation must say so")

        // The other two directions, so the cap is a boundary and not a one-sided clamp: a value at
        // the cap passes through untouched, and one byte over is truncated.
        let atTheCap = String(repeating: "z", count: RPCTransportCore.maxWireReasonLength)
        XCTAssertEqual(
            RPCTransportCore.truncatedForWire(atTheCap), atTheCap,
            "a value exactly at the cap must not be marked as truncated")
        let overByOne = atTheCap + "z"
        XCTAssertTrue(RPCTransportCore.truncatedForWire(overByOne).hasSuffix(marker))
    }

    /// The same bound, where it actually matters: on the wire.
    ///
    /// A peer-supplied value reaches a `cancel` op's `reason` through a decoder's error message, and
    /// the route used here is the shortest one available -- a `status` op whose `grpc-status` value
    /// is not an integer, which `CompactWireCodec.decodeOne` rejects with **the value interpolated
    /// into the message**. That becomes a `.streamFailure`, which `failStream` turns into
    /// `cancel(id, reason: "\(error)")`, truncated on the way out.
    ///
    /// A client-role core, because `status` is a response-direction op and needs a client stream to
    /// be addressed to. The pathological value is the combining-mark one for the reason above: an
    /// 8 MB ASCII value would be bounded by the broken code as well.
    func testAPeerSuppliedValueCannotDriveTheSizeOfTheCancelItProvokes() throws {
        let pathological = "a" + String(repeating: "\u{0301}", count: 4_000_000)

        let reason = try runBounded("the cancel reason's bound on the wire", timeout: 60) {
            () -> String in
            let core = CoreUnderTest(role: .client, label: "reason-bound")
            defer { core.shutDown() }

            let opened = try core.core.openStream(
                descriptor: MethodDescriptor(
                    fullyQualifiedService: "xpc.flowcontrol.Wire", method: "Push"),
                timeout: nil)
            XCTAssertEqual(opened.id, 1, "a client core allocates odd ids from 1")
            _ = core.pipe.takeSentOps()

            core.pipe.deliverRaw(
                RawOpBytes.offsetBlob(
                    RawOpBytes.op(
                        .status, streamID: 1,
                        body: RawOpBytes.fieldList([("grpc-status", pathological)]))))

            let cancels = core.pipe.takeSentOps().cancels(forStream: 1)
            XCTAssertEqual(cancels.count, 1, "the rejected status must cancel exactly that stream")
            return cancels.first ?? ""
        }

        // The bound is generous: the reason is built from an `RPCError`'s whole description, which
        // wraps the truncated message in its own `code: "..."` shell, and `failStream` truncates
        // the *local* message separately before `removeStream` truncates the wire reason. What is
        // asserted is that the peer's own 8 MB is not in there.
        XCTAssertLessThan(
            reason.utf8.count, 4 * RPCTransportCore.maxWireReasonLength,
            "the cancel reason came back at \(reason.utf8.count) byte(s) from an "
                + "\(pathological.utf8.count)-byte peer value; the peer's input size is driving "
                + "the size of the op sent back at it")
    }
}
