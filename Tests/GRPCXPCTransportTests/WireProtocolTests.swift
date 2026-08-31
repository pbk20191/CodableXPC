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
            } catch {
                // `error` is an `RPCError` by type -- `WireCodec.decode` is `throws(RPCError)`.
                // This used to be `catch let error as RPCError` plus an `XCTFail` fallback for
                // "threw something that is not an RPCError"; that fallback is now unrepresentable
                // rather than merely unobserved, so the assertion it guarded is made by the
                // compiler and the branch is gone.
                XCTAssertEqual(error.code, .internalError, label)
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
    ///
    /// # And the gate order, which was verified by reading only until this test grew two arms
    ///
    /// §O2 requires `refuseOpen(_:dueTo:)` to run the same gates `openInbound` does, in the same
    /// order: **role, then id legality, then the fixed literal.** The byte-identity arms above use a
    /// server core and stream id 1, which passes both gates, so they cannot see the order at all.
    /// The two arms at the end of this test enter each gate:
    ///
    /// * a **client** core must answer with `cancel`, never `status` -- a client never accepts, so a
    ///   `status` would tell the peer an RPC it never agreed to had failed;
    /// * a **reserved** id (0, or any even id) must be refused on the id, before the `status` its
    ///   malformed body would otherwise earn;
    /// * and a **client** receiving a **reserved** id -- the only shape in which both gates apply at
    ///   once, and therefore the only one that can see which runs *first*. The first two arms cannot:
    ///   measured, swapping the two guards survives them both (P31).
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

        func refusal(
            for input: Data, label: String, role: RPCTransportCore.Role = .server
        ) throws -> [GRPCSwiftData] {
            let core = CoreUnderTest(role: role, label: label)
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

        // -------------------------------------------------------------------------------
        // The gate order: ROLE first, then id legality. Neither gate is reached above.
        // -------------------------------------------------------------------------------
        //
        // `refuseOpen(_:dueTo:)` deliberately mirrors `openInbound`'s own gate order for the two
        // checks it can make without a successfully-decoded `method`, and §O2 says **the role gate
        // must run first**: a malformed `openStream` arriving at a *client* transport must get
        // `openInbound`'s treatment -- a client never accepts, so `cancel`, not `status` -- and
        // checking id legality or answering with `status` before checking role would have a client
        // transport answer an `openStream` it must never accept.
        //
        // Everything above this line uses a **server** core and stream id **1**, which passes both
        // gates, so until these two arms existed the ordering was verified by reading only.

        // Arm 1: the role gate. A client core must answer with the fixed-literal `cancel`.
        let atAClient = try refusal(for: tiny, label: "refuse-at-a-client", role: .client)
        XCTAssertEqual(atAClient.count, 1, "a client must still answer -- silently dropping hangs the peer")
        let clientOps = try Self.codec.decode(try XCTUnwrap(atAClient.first))
        XCTAssertEqual(
            Self.describe(clientOps),
            ["op(cancel(1, reason: a client transport does not accept streams))"],
            "a client transport must refuse with `cancel`, never `status`: a `status` says 'your RPC "
                + "failed', which presumes an RPC a client never agreed to accept")

        // Arm 2: the id-legality gate, on a server, for the ids §O1/§O4 reserve. These must be
        // refused with `cancel` too -- there is no legitimate RPC to answer with a status -- and
        // they must be refused *because of the id*, before the `status` reply the body's own
        // rejection would otherwise produce.
        for illegalID: RPCStreamID in [0, 2, 4_294_967_294] {
            let body = RawOpBytes.fieldList([], declaredCount: 0xFFFF)
            let reply = try refusal(
                for: RawOpBytes.op(.openStream, streamID: illegalID, body: body),
                label: "refuse-illegal-id-\(illegalID)")
            XCTAssertEqual(reply.count, 1, "id \(illegalID): exactly one blob goes back")
            XCTAssertEqual(
                Self.describe(try Self.codec.decode(try XCTUnwrap(reply.first))),
                [
                    "op(cancel(\(illegalID), reason: stream id \(illegalID) is not a legal "
                        + "client-allocated id (must be odd and non-zero)))"
                ],
                "id \(illegalID) is reserved (0 is the connection window per §O4; even ids are not "
                    + "client-allocated per §O1), so it must be refused with `cancel` on the id, "
                    + "not with the `status` its malformed body would otherwise earn")
        }

        // Arm 3: **the order itself, which arms 1 and 2 cannot see.**
        //
        // Each of them enters one gate and then falls straight through to the answer, so swapping
        // the two guards changes nothing for either: for a legal odd id only the role gate can
        // fire, and for a server core the role gate never fires. **Measured -- without this arm,
        // swapping the two guards survives the entire target (mutation P31).**
        //
        // Only a **client** receiving an **illegal** id makes both gates applicable at once, and
        // then the reason on the wire says which one ran. §O2 says role wins, and the reason it
        // gives is not stylistic: the id is irrelevant to a transport that accepts nothing, so
        // reporting it would tell the peer to retry with a different id on a connection where no id
        // will ever work.
        for illegalID: RPCStreamID in [0, 2] {
            let reply = try refusal(
                for: RawOpBytes.op(
                    .openStream, streamID: illegalID,
                    body: RawOpBytes.fieldList([], declaredCount: 0xFFFF)),
                label: "refuse-client-illegal-\(illegalID)", role: .client)
            XCTAssertEqual(
                Self.describe(try Self.codec.decode(try XCTUnwrap(reply.first))),
                ["op(cancel(\(illegalID), reason: a client transport does not accept streams))"],
                "both gates apply to id \(illegalID) at a client, and §O2 puts role first: the peer "
                    + "must be told this transport does not accept streams, not that its id was "
                    + "illegal")
        }
    }

    // =======================================================================================
    // MARK: - What user metadata may put on the wire
    // =======================================================================================

    /// **No pseudo-header reaches the wire from user metadata.** Task 4's report calls this "exactly
    /// the assertion that would have caught it" about a fix that shipped, and it did not exist -- no
    /// test file targets `StreamStateMachines.swift` at all.
    ///
    /// A caller can put anything in `Metadata`, including `:path` or `content-type`. Those names
    /// belong to the transport: `openStream`'s field list carries the real ones, and a `metadata` op
    /// that also carried them would either be ignored by a conforming peer or -- worse -- override
    /// the method the call is actually for. So the reserved set is stripped on the way out.
    ///
    /// Both directions are asserted, and only one of them is mutation-proven:
    ///
    /// * **a non-reserved key survives byte-exact**, which is discriminating by construction -- an
    ///   encoder that dropped or mangled values fails it;
    /// * **every reserved key is stripped.** The mutation that would prove this half (removing the
    ///   `isReservedName` filter in `GRPCWireHeaders.userMetadataFields`) lands in a file carrying
    ///   the user's live typed-throws WIP, so it was **not run** -- recorded rather than claimed.
    ///
    /// The `openStream` op in the same blob is asserted to keep its own pseudo-headers, so the test
    /// cannot pass by stripping them everywhere.
    func testNoPseudoHeaderReachesTheWireFromUserMetadata() throws {
        try runBounded("user metadata on the wire", timeout: 20) {
            let core = CoreUnderTest(role: .client, label: "pseudo-headers")
            defer { core.shutDown() }

            let opened = try core.core.openStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "pkg.Svc", method: "Real"),
                timeout: nil)

            var metadata = Metadata()
            metadata.addString("kept", forKey: "x-user-key")
            for reserved in [
                ":method", ":scheme", ":path", ":status", "te", "content-type", "grpc-timeout",
                "grpc-status", "grpc-message",
            ] {
                metadata.addString("smuggled", forKey: reserved)
            }
            try await opened.stream.outbound.write(.metadata(metadata))

            let ops = core.pipe.takeSentOps()

            // `openStream` is prepended by `RequestOpEncoder` on the first write, and it *must* keep
            // its pseudo-headers -- they are how the peer learns the method.
            XCTAssertEqual(
                ops.compactMap { if case .openStream = $0 { return $0.testDescription } else { return nil } },
                ["openStream(1, method: pkg.Svc/Real, timeout: nil)"],
                "the deferred openStream must still name the real method")

            let metadataFields: [HTTPField] = ops.compactMap {
                if case .metadata(_, let fields) = $0 { return fields }
                return nil
            }.first ?? []

            XCTAssertEqual(
                metadataFields.map { "\($0.name)=\($0.value)" }, ["x-user-key=kept"],
                "the metadata op may carry the user's own field and nothing else: every reserved "
                    + "name must be stripped, or a caller can override the method the call is for")
        }
    }

    // =======================================================================================
    // MARK: - The byte layout, kind by kind
    // =======================================================================================

    /// **Every one of §O3's eight op kinds, encoded and decoded back.** No such test existed for any
    /// of them: the codec's round trip was exercised only incidentally, by ops the transport happened
    /// to send in other tests, which covers `openStream`/`metadata`/`message`/`halfClose`/`status`/
    /// `cancel`/`credit` in the shapes the transport itself produces and nothing else.
    ///
    /// The values are chosen to sit on the edges the encoding actually has:
    ///
    /// * `credit` at **0** and at **`UInt32.max`** -- both legal *at this layer*. The 4-byte body is
    ///   the whole encoding, so there is nothing for the codec to reject; it is `FlowControlWindow`
    ///   that refuses an over-ceiling credit and `RPCTransportCore` that fails the connection for it
    ///   (`ReceiveWindowTests.testAnOverflowingCreditFailsTheConnection`). A codec that clamped or
    ///   rejected here would silently change the protocol.
    /// * a `grpc-timeout` on `openStream`, which is the only field that is *interpreted* rather than
    ///   copied -- it goes out as an 8-digit-max unit string and has to come back the same `Duration`.
    /// * an empty-named, empty-valued metadata field, and a multi-byte UTF-8 value: the field-list
    ///   encoding is length-prefixed, so a zero length and a length that is not the character count
    ///   are the two ways to get it wrong.
    /// * a `status` with a code, a message and trailers, since the op carries `code`/`message` split
    ///   out of the field list and has to reassemble them.
    func testEveryOpKindRoundTripsThroughTheWire() throws {
        let cases: [(label: String, op: RPCOp)] = [
            ("openStream, no timeout", .openStream(1, method: "pkg.Svc/Method", timeout: nil)),
            (
                "openStream, with a timeout",
                .openStream(3, method: "pkg.Svc/Method", timeout: .milliseconds(1_500))
            ),
            (
                "metadata, including an empty field and multi-byte UTF-8",
                .metadata(5, fields: [("a", "b"), ("", ""), ("k", "안녕 hello")])
            ),
            ("metadata, empty field list", .metadata(5, fields: [])),
            ("message", .message(7, payload: GRPCSwiftData(Array(0..<40).map { UInt8($0) }))),
            ("message, empty payload", .message(7, payload: GRPCSwiftData([]))),
            ("halfClose", .halfClose(9)),
            (
                "status with a message and trailers",
                .status(11, code: 5, message: "no such method", trailers: [("t", "1")])
            ),
            ("status, ok and bare", .status(11, code: 0, message: "", trailers: [])),
            ("cancel", .cancel(13, reason: "because")),
            ("cancel, empty reason", .cancel(13, reason: "")),
            ("credit at zero", .credit(15, bytes: 0)),
            ("credit at UInt32.max", .credit(15, bytes: .max)),
            ("credit on the connection window", .credit(0, bytes: 32_767)),
            ("goAway", .goAway(lastStreamID: 12_345)),
            ("goAway at zero", .goAway(lastStreamID: 0)),
        ]

        for (label, op) in cases {
            let blob = try Self.codec.encode([op])
            XCTAssertEqual(
                Self.describe(try Self.codec.decode(blob)), ["op(\(op.testDescription))"], label)
        }

        // And all of them in one blob, in order: a blob carries several ops back to back, and the
        // per-op advance is what keeps them separable.
        let everything = try Self.codec.encode(cases.map(\.op))
        XCTAssertEqual(
            Self.describe(try Self.codec.decode(everything)),
            cases.map { "op(\($0.op.testDescription))" },
            "one blob carrying all sixteen ops must decode to exactly those ops, in order")
    }

    /// `goAway` is connection-scoped, so **the header's `streamID` field is meaningless for it**: the
    /// codec writes 0 there on encode and must ignore whatever it reads on decode. The real payload
    /// is the 4-byte body.
    ///
    /// Worth its own case because the header id is the one field a hostile peer can set freely on an
    /// op whose body-level rejection is *connection-fatal*: if the decoder read `lastStreamID` from
    /// the header instead of the body, a peer could drain a connection to an id of its choosing and
    /// the body would go unread.
    func testGoAwayIgnoresTheHeadersOwnStreamID() throws {
        var body = Data()
        RawOpBytes.appendBE(UInt32(12_345), to: &body)

        for headerID: RPCStreamID in [0, 1, 777, .max] {
            XCTAssertEqual(
                Self.describe(
                    try Self.codec.decode(
                        RawOpBytes.offsetBlob(
                            RawOpBytes.op(.goAway, streamID: headerID, body: body)))),
                ["op(goAway(lastStreamID: 12345))"],
                "the body decides `lastStreamID`, not the header (header id \(headerID))")
        }

        // Encode writes 0 into that field, so a wire-compatible peer sees the documented shape.
        let encoded = try Self.codec.encode([.goAway(lastStreamID: 12_345)])
        let bytes = Array(encoded)
        XCTAssertEqual(bytes.count, RawOpBytes.headerLength + 4)
        XCTAssertEqual(
            Array(bytes[2..<6]), [0, 0, 0, 0],
            "encode must write the header's streamID as 0 for goAway; it is meaningless there and "
                + "writing a real id would invite a decoder to read it")
    }

    /// A `status` op's field list may legally carry only one `grpc-status`; a peer can send more.
    /// **The first wins, and the rest fall through to `trailers`** -- they are not an error, and they
    /// do not overwrite the code.
    ///
    /// The second half of the case is what makes the first half safe: a duplicate reserved field
    /// landing in `trailers` would reach the application as trailing metadata under a reserved name,
    /// which gRPC forbids. It does not, because `ResponseOpDecoder` runs the trailers through
    /// `GRPCWireHeaders.parseUserMetadata`, which excludes reserved names -- so the codec's
    /// permissiveness is contained one layer up. Both layers are asserted, because the containment is
    /// the reason the permissiveness is acceptable.
    func testADuplicateGrpcStatusTakesTheFirstAndTheRestBecomeTrailers() throws {
        let blob = RawOpBytes.offsetBlob(
            RawOpBytes.op(
                .status, streamID: 1,
                body: RawOpBytes.fieldList([
                    ("grpc-status", "5"),
                    ("grpc-status", "7"),
                    ("grpc-message", "first wins"),
                    ("grpc-message", "second does not"),
                    ("x-trailer", "kept"),
                ])))

        let items = try Self.codec.decode(blob)
        guard items.count == 1, case .op(.status(let id, let code, let message, let trailers)) = items[0]
        else {
            return XCTFail("expected one status op; got \(Self.describe(items))")
        }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(code, 5, "the first `grpc-status` wins")
        XCTAssertEqual(message, "first wins", "the first `grpc-message` wins")
        XCTAssertEqual(
            trailers.map { "\($0.name)=\($0.value)" },
            ["grpc-status=7", "grpc-message=second does not", "x-trailer=kept"],
            "the duplicates fall through to trailers in wire order, alongside the real trailer")

        // And they are contained one layer up: the application never sees a reserved name.
        try runBounded("a duplicate grpc-status at the mux", timeout: 20) {
            let core = CoreUnderTest(role: .client, label: "duplicate-status")
            defer { core.shutDown() }
            let opened = try core.core.openStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "pkg.Svc", method: "M"),
                timeout: nil)
            core.pipe.deliverRaw(blob)

            var seen: [String] = []
            var status: Status?
            for try await part in opened.stream.inbound {
                if case .status(let received, let metadata) = part {
                    status = received
                    seen = metadata.map(\.key).sorted()
                }
            }
            XCTAssertEqual(status?.code, .notFound, "grpc-status 5 is notFound")
            XCTAssertEqual(status?.message, "first wins")
            XCTAssertEqual(
                seen, ["x-trailer"],
                "the duplicated reserved fields must not reach the application as trailing "
                    + "metadata; only the real trailer may")
        }
    }

    /// §O2: **user metadata travels in its own `metadata` op and never inside `openStream`'s field
    /// list**, and an `openStream` whose field list carries anything outside the reserved set is
    /// rejected -- loudly, because the alternative is a peer smuggling up to 16 MiB of extra
    /// field-list bytes into every call it opens, and a silent skip would destroy the only evidence.
    ///
    /// Built by adding one field to an otherwise-valid body, so the rejection cannot be for some
    /// unrelated reason: the same body without `extraFields` is asserted to decode cleanly first.
    func testAnOpenStreamCarryingStrayMetadataIsRejected() throws {
        let clean = RawOpBytes.op(
            .openStream, streamID: 1, body: RawOpBytes.openStreamBody(method: "pkg.Svc/Method"))
        XCTAssertEqual(
            Self.describe(try Self.codec.decode(RawOpBytes.offsetBlob(clean))),
            ["op(openStream(1, method: pkg.Svc/Method, timeout: nil))"],
            "the control: the same body without the stray field must decode")

        let stray = RawOpBytes.op(
            .openStream, streamID: 1,
            body: RawOpBytes.openStreamBody(
                method: "pkg.Svc/Method", extraFields: [("x-smuggled", "1")]))
        let items = try Self.codec.decode(RawOpBytes.offsetBlob(stray))
        XCTAssertEqual(
            Self.describe(items), ["streamOpenFailure(1)"],
            "a stray field must fail that stream's open, not be skipped and not fail the connection")
        guard case .streamOpenFailure(_, let error) = items[0] else { return XCTFail() }
        XCTAssertTrue(
            error.message.contains("x-smuggled"),
            "the rejection must name the stray field -- that name is the only evidence the "
                + "smuggling happened; got '\(error.message)'")
    }

    /// `sendControl(_:)` drops its failure **"here and only here"**, per its own doc comment: a
    /// control op has no caller to report to, and if the substrate is gone there is no peer to
    /// inform.
    ///
    /// The reachable consequence, and the one worth pinning: **a refusal that cannot be sent must not
    /// take the connection down or trap.** A peer can provoke a refusal at zero state cost (no table
    /// entry is created), so if a failed send on that path were fatal, a peer racing a teardown would
    /// have a lever on it.
    func testARefusalThatCannotBeSentIsDroppedNotFatal() throws {
        let core = CoreUnderTest(role: .server, label: "unsendable-refusal")
        defer { core.shutDown() }

        core.pipe.failNextSends(
            with: RPCError(code: .unavailable, message: "the substrate is gone"))

        // A malformed `openStream`, which `refuseOpen` answers through `sendControl`.
        core.pipe.deliverRaw(
            RawOpBytes.offsetBlob(
                RawOpBytes.op(
                    .openStream, streamID: 1,
                    body: RawOpBytes.fieldList([], declaredCount: 0xFFFF))))

        XCTAssertEqual(
            core.pipe.sentBlobs.count, 0, "the send failed, so nothing reached the wire")
        XCTAssertFalse(
            core.pipe.isCancelled,
            "a refusal that could not be sent must not fail the connection: the peer would "
                + "otherwise have a one-op lever on a connection that is merely losing its "
                + "substrate")
        XCTAssertEqual(core.core.liveStreamCount, 0)

        // And the core still routes afterwards rather than being wedged by the swallowed error.
        core.pipe.deliverRaw(
            RawOpBytes.offsetBlob(RawOpBytes.op(.halfClose, streamID: 9_999, body: Data())))
        XCTAssertFalse(core.pipe.isCancelled)
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
            // The shape, not merely "it threw": the `credit` rows beside this check which item came
            // back, and a bare `XCTAssertThrowsError` here would accept any error at all --
            // including one from a codec that had started rejecting the *framing* rather than the
            // body, which is a different rule.
            var goAwayFailure: (any Error)?
            do {
                let items = try Self.codec.decode(
                    RawOpBytes.offsetBlob(
                        RawOpBytes.op(
                            .goAway, streamID: 0, body: Data(repeating: 0, count: length))))
                XCTFail(
                    "a \(length)-byte goAway body must be connection-fatal; decode returned "
                        + "\(Self.describe(items))")
            } catch {
                goAwayFailure = error
            }
            let goAwayError = goAwayFailure as? RPCError
            XCTAssertEqual(
                goAwayError?.code, .internalError,
                "a \(length)-byte goAway body must fail as RPCError(.internalError); got "
                    + "\(goAwayFailure.map { "\($0)" } ?? "no error")")
            XCTAssertTrue(
                goAwayError?.message.contains("goAway") ?? false,
                "the failure must name goAway's own body rule -- otherwise this passes on a framing "
                    + "rejection, which is a different rule; got '\(goAwayError?.message ?? "")'")
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

    // =======================================================================================
    // MARK: - Pre-admission work: parsing an `openStream`'s field list
    // =======================================================================================

    /// **`GRPCWireHeaders.parseRequest` walks a peer-supplied field list exactly once.**
    ///
    /// The amplification this pins is pre-admission by construction: `CompactWireCodec.decode`
    /// parses an `openStream` body *before* `RPCTransportCore.route` has run its stream-count
    /// admission check, so nothing has yet decided the peer may open a stream at all. `count` is a
    /// peer-chosen `UInt16`, so one ~393 KB body can declare 65 535 fields, and the parser used to
    /// walk them three times -- once for `:path`, once for `grpc-timeout`, once for user metadata
    /// -- lowercasing every name on every walk. With `:path` ordered *last*, that is ~200 000
    /// `String` allocations per message, repeatable at will.
    ///
    /// **The assertion is on work done, not on elapsed time.** A timing assertion on a shared CI
    /// box measures the box, not the parser. The seam is the parameter type instead:
    /// `parseRequest` takes any `Collection` of `HTTPField`, so ``CountingFields`` can count every
    /// element the parser pulls out and the test can assert the exact count. One pass over `n`
    /// fields is `n` accesses; the three-pass shape is `3n`, and `n` is chosen large enough that
    /// no off-by-a-few can blur the two.
    ///
    /// `:path` is deliberately the **last** field, and `grpc-timeout` deliberately absent: that is
    /// the worst case for the old shape (no early exit on either lookup) and it is also the shape
    /// a hostile peer would send.
    func testParseRequestWalksAPeerSuppliedFieldListExactlyOnce() throws {
        try runBounded("one-pass request parse", timeout: 20) {
            let padding = 4_096
            var fields: [HTTPField] = (0..<padding).map { ("x-pad-\($0)", "v") }
            fields.append((":path", "/pkg.Svc/Method"))

            let counter = FieldAccessCounter()
            let parsed = try GRPCWireHeaders.parseRequest(CountingFields(fields, counter: counter))

            XCTAssertEqual(parsed.path, "/pkg.Svc/Method")
            XCTAssertNil(parsed.timeout)
            XCTAssertEqual(
                parsed.metadata.count, padding,
                "the control: every non-reserved field must still have become user metadata, so "
                    + "the access count below is a count of a walk that did the whole job")

            XCTAssertEqual(
                counter.accesses, fields.count,
                "parseRequest must touch each field exactly once; \(counter.accesses) accesses "
                    + "for \(fields.count) field(s) means it is walking the list "
                    + "\(counter.accesses / fields.count)x, and every extra walk is peer-commanded "
                    + "work done before any admission gate")
        }
    }

    /// The fast path must not change **which** names match.
    ///
    /// `parseRequest` no longer calls `lowercased()` on every field name; it folds ASCII case
    /// byte-by-byte instead. That is only sound because HTTP field names are ASCII -- and it is
    /// only *exactly* sound because non-ASCII names still take the `lowercased()` path. Both
    /// halves are asserted here, because the ASCII shortcut is the kind of change that silently
    /// narrows a match set:
    ///
    /// * ASCII case still folds: `:PATH`, `GRPC-Timeout`, `TE`, `Content-Type` are still the
    ///   reserved names they were, and a mixed-case metadata name still arrives lowercased.
    /// * Non-ASCII still folds the Unicode way: U+212A KELVIN SIGN lowercases to `"k"`, so a field
    ///   named `"\u{212A}-bin"` must still land under the key `"k-bin"` -- an ASCII-only fold
    ///   would have left it as `"\u{212A}-bin"`, a different key with a different `-bin` meaning.
    func testFieldNameMatchingIsUnchangedByTheASCIICaseFold() throws {
        let fields: [HTTPField] = [
            (":METHOD", "POST"),
            ("TE", "trailers"),
            ("Content-Type", "application/grpc"),
            ("X-Mixed-Case", "kept"),
            ("\u{212A}", "kelvin"),
            ("GRPC-Timeout", "1500000u"),
            (":Path", "/pkg.Svc/Method"),
        ]
        let parsed = try GRPCWireHeaders.parseRequest(fields)

        XCTAssertEqual(parsed.path, "/pkg.Svc/Method", "`:Path` must still match `:path`")
        XCTAssertEqual(
            parsed.timeout, .microseconds(1_500_000),
            "`GRPC-Timeout` must still match `grpc-timeout`")
        XCTAssertEqual(
            parsed.metadata.map(\.key).sorted(), ["k", "x-mixed-case"],
            "every reserved name must still be stripped whatever its case, an ASCII metadata name "
                + "must still arrive lowercased, and U+212A must still fold to \"k\" the way "
                + "`lowercased()` folds it")
    }

    /// Rejection precedence is part of the contract the one-pass rewrite had to preserve.
    ///
    /// The three-pass shape reached `:path` first, `grpc-timeout` second and user metadata last, so
    /// which error a doubly-malformed request produced was decided by that order. A single pass
    /// reaches all three at once, so the order now has to be re-established deliberately -- a
    /// malformed `-bin` value is held and rethrown last rather than escaping where it was raised.
    /// If it were not, this request would report a base64 failure instead of the malformed path
    /// that is the more useful diagnosis, and the `unimplemented` refusal a malformed `:path` earns
    /// would silently become `invalidArgument`.
    func testRejectionPrecedenceSurvivesTheSinglePass() throws {
        func code(of fields: [HTTPField]) -> RPCError.Code? {
            do {
                _ = try GRPCWireHeaders.parseRequest(fields)
                return nil
            } catch {
                return error.code
            }
        }

        XCTAssertEqual(
            code(of: [("x-bin", "!!not base64!!"), ("grpc-timeout", "nope"), (":path", "no-slash")]),
            .unimplemented,
            "a malformed `:path` outranks both a malformed timeout and a malformed `-bin` value")
        XCTAssertEqual(
            code(of: [("x-bin", "!!not base64!!"), ("grpc-timeout", "nope"), (":path", "/pkg.Svc/M")]),
            .invalidArgument,
            "a malformed timeout outranks a malformed `-bin` value")
        XCTAssertEqual(
            code(of: [("x-bin", "!!not base64!!"), (":path", "/pkg.Svc/M")]),
            .invalidArgument,
            "a malformed `-bin` value is still rejected, just last")
        XCTAssertEqual(
            code(of: [("x-bin", "!!not base64!!"), ("grpc-timeout", "nope")]),
            .invalidArgument,
            "and a missing `:path` still outranks everything")
    }

    // =======================================================================================
    // MARK: - An unrecognized `grpc-status` code
    // =======================================================================================

    /// **An unrecognized `grpc-status` code completes the RPC as `UNKNOWN`; it does not fail the
    /// stream.**
    ///
    /// gRPC's rule is that a client which does not recognise a status code maps it to `UNKNOWN`
    /// (2). This decoder used to reject it instead: `Status.Code(rawValue: 17)` is `nil`, so the
    /// stream failed with `.internalError` and the mux sent a `cancel` back at a peer that had just
    /// terminated *cleanly* -- it sent a status, and the grammar was obeyed. Codes 0...16 have been
    /// frozen for years, so nothing on the wire today produces this; the case exists so that a
    /// newer peer sharing this wire format is not mistaken for a broken one.
    ///
    /// Both halves matter and both are asserted: the application must see a completed RPC with an
    /// `unknown` status **and** nothing may go back out on the wire. A version that mapped the code
    /// but still cancelled would pass the first assertion alone.
    func testAnUnrecognizedGrpcStatusCodeCompletesTheRPCAsUnknown() throws {
        let blob = RawOpBytes.offsetBlob(
            RawOpBytes.op(
                .status, streamID: 1,
                body: RawOpBytes.fieldList([
                    ("grpc-status", "17"),
                    ("grpc-message", "from a newer peer"),
                    ("x-trailer", "kept"),
                ])))

        // The codec itself is not where the mapping happens: it carries the raw code through.
        let items = try Self.codec.decode(blob)
        guard items.count == 1, case .op(.status(_, let code, _, _)) = items[0] else {
            return XCTFail("expected one status op; got \(Self.describe(items))")
        }
        XCTAssertEqual(code, 17, "the codec moves the code verbatim; the mapping is the decoder's")

        try runBounded("an unrecognized grpc-status at the mux", timeout: 20) {
            let core = CoreUnderTest(role: .client, label: "unknown-status")
            defer { core.shutDown() }
            let opened = try core.core.openStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "pkg.Svc", method: "M"),
                timeout: nil)
            _ = core.pipe.takeSentOps()

            core.pipe.deliverRaw(blob)

            var status: Status?
            var trailerKeys: [String] = []
            for try await part in opened.stream.inbound {
                if case .status(let received, let metadata) = part {
                    status = received
                    trailerKeys = metadata.map(\.key).sorted()
                }
            }
            XCTAssertEqual(
                status?.code, .unknown,
                "gRPC maps an unrecognized status code to UNKNOWN; the application must see a "
                    + "completed RPC, not a transport internal error")
            XCTAssertEqual(
                status?.message, "from a newer peer",
                "the peer's own explanation of the code must survive the remap")
            XCTAssertEqual(trailerKeys, ["x-trailer"], "and so must its trailers")

            XCTAssertEqual(
                core.pipe.takeSentOps().cancels(forStream: 1), [],
                "a peer that terminated cleanly must not be answered with a cancel")
            XCTAssertFalse(core.pipe.isCancelled, "and certainly not with a connection teardown")
        }
    }

    /// `readBE` reads through `loadUnaligned` now, which means the byte offset it computes is
    /// `index - data.startIndex` rather than `index`. A blob that starts at index 0 cannot tell
    /// those apart, so this one does not: `offsetBlob` pads by 7, putting the header at index 7 and
    /// a body at index 17 -- odd, and not a multiple of 4, so an alignment assumption would trap
    /// rather than quietly succeed.
    ///
    /// Every big-endian field is covered at once: the header's `streamID` (offset 2) and
    /// `bodyLength` (offset 6) are read off the padded header, and `credit`'s 4-byte body is read
    /// off `body.startIndex`, the one call site whose index is a *body's* start rather than the
    /// blob's.
    func testBigEndianReadsAreOffsetFromTheBuffersOwnStartIndex() throws {
        var creditBody = Data()
        RawOpBytes.appendBE(UInt32(0xDEAD_BEEF), to: &creditBody)

        for padding in [0, 1, 7, 13] {
            let blob = RawOpBytes.offsetBlob(
                RawOpBytes.op(.credit, streamID: 0x0102_0304, body: creditBody),
                leadingPadding: padding)
            XCTAssertEqual(
                Self.describe(try Self.codec.decode(blob)),
                ["op(credit(16909060, bytes: 3735928559))"],
                "every offset must derive from the buffer's own startIndex (padding \(padding))")
        }
    }
}

// ===========================================================================================
// MARK: - Counting the work a parser does
// ===========================================================================================

/// Counts how many elements a `Collection` handed out. A `final class` because the count has to
/// survive the `struct` `Collection` being copied around by whatever generic algorithm is walking
/// it; a `Mutex` because `runBounded` bodies are `@Sendable`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class FieldAccessCounter: Sendable {
    private let box = Mutex<Int>(0)
    func bump() { box.withLock { $0 += 1 } }
    var accesses: Int { box.withLock { $0 } }
}

/// A `[HTTPField]` that reports every element read through it.
///
/// This is the seam `testParseRequestWalksAPeerSuppliedFieldListExactlyOnce` measures through, and
/// the reason `GRPCWireHeaders.parseRequest` is generic over `Collection` rather than taking an
/// `[HTTPField]`: an `Array` cannot tell anyone how many times it was walked, and the alternative
/// -- asserting on elapsed time -- would measure the machine rather than the parser.
///
/// `Collection`'s default `makeIterator()` is `IndexingIterator`, which subscripts once per
/// element, so `accesses` after one full walk is exactly `count`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct CountingFields: Collection {
    private let fields: [HTTPField]
    private let counter: FieldAccessCounter

    init(_ fields: [HTTPField], counter: FieldAccessCounter) {
        self.fields = fields
        self.counter = counter
    }

    var startIndex: Int { fields.startIndex }
    var endIndex: Int { fields.endIndex }
    func index(after i: Int) -> Int { i + 1 }

    subscript(position: Int) -> HTTPField {
        counter.bump()
        return fields[position]
    }
}
