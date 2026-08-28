import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// Scaffolding for the flow-control-and-protocol slice. Two things live here that the earlier
// slices' support files do not have, and both exist for the same reason: **this slice's subject is
// what the mux does with bytes the peer chose**, and a conforming `GRPCClient` cannot be made to
// send a malformed op, an over-window burst or a credit for a stream that does not exist.
//
// 1. **``TestPipe``** -- a `MessagePipe` conformer that is not XPC. The test *is* the peer: it
//    hands the core exact bytes and reads back exactly what the core sent.
// 2. **``CoreUnderTest``** -- one `RPCTransportCore` over a ``TestPipe``, with the accept loop
//    already running.
//
// ## Why a second `MessagePipe` is legitimate here, and is not a "second accept path"
//
// The hazards this suite carries are all properties of **`XPCPipe` and libxpc**: never drop the
// pipe `accepting` returns inside the accept window, never install a second `onReceive`, one serial
// queue per connection distinct from the listener's, no nudge blob. ``TestPipe`` touches none of
// that surface -- there is no `XPCListener`, no `XPCSession`, no accept `Decision` and therefore no
// accept window to violate. It conforms to `MessagePipe`, which is the seam `RPCTransportCore` was
// written against (`RPCOp.swift`: "nothing in this file, or in anything built on `RPCOp`, may
// assume XPC is on the other side of it"), and it keeps that protocol's two contractual promises:
//
// * **ordering** -- every delivery is one `queue.sync`, from one test thread at a time, so blobs
//   reach `onReceive` in the order the test handed them over;
// * **`queue`, and only `queue`** -- both handlers are invoked inside `queue.sync`, which is what
//   satisfies `RPCTransportCore.receive`'s `dispatchPrecondition` tripwire (L4).
//
// The tests whose subject is the *substrate* (ordering across a real libxpc channel, backpressure
// against a real reader) still use two real XPC sessions through `XPCPairHarness`. This type is for
// the tests a conforming peer cannot express.

// ===========================================================================================
// MARK: - TestPipe
// ===========================================================================================

/// A `MessagePipe` the test drives from both ends: it captures every blob the core sends and
/// delivers whatever blobs the test chooses, in order, on the pipe's own serial queue.
///
/// `@unchecked Sendable` for the house reason: the `Mutex` *is* the synchronisation for every
/// mutable field, and the two handler closures are `@Sendable` by their own signatures. The
/// existential `any Error` in `sendFailure` is what rules out a checked conformance.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class TestPipe: MessagePipe, @unchecked Sendable {

    let queue: DispatchSerialQueue

    private struct State {
        var onReceive: (@Sendable (GRPCSwiftData) -> Void)?
        var onPeerDeath: (@Sendable () -> Void)?
        /// Every blob handed to ``send(_:)``, in send order. Never cleared by the pipe itself --
        /// ``takeSentOps()`` is the test's own reset.
        var sent: [GRPCSwiftData] = []
        var isCancelled = false
        /// How many blobs the test has delivered. A test whose subject is *how ops were packed
        /// into blobs* has no other way to see it: `sent` records the outbound direction, and the
        /// inbound blobs are consumed by the core rather than kept.
        var deliveredBlobs = 0
        /// When set, ``send(_:)`` throws this instead of recording -- for the "the substrate is
        /// gone" arm of a test that has nothing to do with XPC.
        var sendFailure: (any Error)?
        /// See ``onEachSend(_:)``. Nil for every test that does not ask for it, which is all but
        /// one.
        var sendObserver: (@Sendable (GRPCSwiftData) -> Void)?
    }

    private let state = Mutex(State())
    private let codec = CompactWireCodec()

    init(label: String) {
        self.queue = DispatchSerialQueue(label: "GRPCXPCTransportTests.TestPipe.\(label)")
    }

    // -------------------------------------------------------------------------------------
    // MARK: MessagePipe
    // -------------------------------------------------------------------------------------

    func send(_ blob: GRPCSwiftData) throws {
        // Read under the lock, called **outside** it. An observer runs inside whatever core call is
        // doing the sending, and may reach back into the core or the transport above it; doing that
        // with this pipe's lock held would deadlock the moment it sent anything. (It may not send
        // *anything* from in there either, but for a different reason and not because of this lock
        // -- see ``onEachSend(_:)``.)
        if let observer = state.withLock({ $0.sendObserver }) { observer(blob) }
        try state.withLock { state in
            if let failure = state.sendFailure { throw failure }
            guard !state.isCancelled else {
                throw RPCError(
                    code: .unavailable,
                    message: "the test pipe has been cancelled; no blob may be sent")
            }
            state.sent.append(blob)
        }
    }

    func onReceive(_ handler: @escaping @Sendable (GRPCSwiftData) -> Void) {
        state.withLock { state in
            precondition(
                state.onReceive == nil,
                "MessagePipe.onReceive is set-once; RPCTransportCore.init installs it and nothing "
                    + "else may")
            state.onReceive = handler
        }
    }

    func onPeerDeath(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { state in
            precondition(state.onPeerDeath == nil, "MessagePipe.onPeerDeath is set-once")
            state.onPeerDeath = handler
        }
    }

    func cancel() { state.withLock { $0.isCancelled = true } }

    // -------------------------------------------------------------------------------------
    // MARK: The test's end
    // -------------------------------------------------------------------------------------

    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    /// How many blobs have been delivered into the core. `OrderingStressTests` asserts on this to
    /// pin that its ops really were *packed together* into one blob per round rather than sent one
    /// per blob -- a distinction no observation of the decoded parts can make, and one a mutation
    /// proved this suite could not otherwise see.
    var deliveredBlobCount: Int { state.withLock { $0.deliveredBlobs } }

    /// Makes every subsequent ``send(_:)`` throw `error` instead of recording the blob.
    ///
    /// The substrate being gone is a state the core has to survive without a caller to report to:
    /// `sendControl(_:)` is documented as dropping its failure "here and only here". Read by
    /// `WireProtocolTests.testARefusalThatCannotBeSentIsDroppedNotFatal`.
    func failNextSends(with error: any Error) { state.withLock { $0.sendFailure = error } }

    /// Installs a hook run **on the sending thread, inside the core call that is sending**, before
    /// the blob is recorded.
    ///
    /// This is the suite's one deterministic way to stand *in the middle of* a core operation
    /// rather than before or after it, and it exists because one of this transport's ordering
    /// defects is only observable there: `beginGracefulShutdown()` calls `core.beginDraining()`,
    /// which sets the mux's `localDraining` flag and then sends `goAway` -- so a hook that blocks
    /// here holds the process at exactly the instant "the mux is draining, and the transport's own
    /// shutdown bookkeeping has not finished". A test that hoped to hit that window by racing
    /// would be sampling a distribution; this one stops time in it.
    ///
    /// Blocking in here is the intended use. Blocking *forever* is not: the observer runs on
    /// whatever thread called `send`, so give it its own bound (L8 applies to the hook as much as
    /// to the test).
    ///
    /// - Important: **an observer must not itself send anything, on this thread.** It runs inside
    ///   `RPCTransportCore`'s submission lock -- that lock is exactly "the decision to send and the
    ///   submission are one step", so a nested send from inside a send deadlocks on it. Reaching
    ///   back into the core for anything that does *not* send is fine, and so is handing the send to
    ///   another thread: `CancelOrderingTests` does exactly that, and the other thread blocking on
    ///   the submission lock until this hook returns is the property it measures.
    func onEachSend(_ observer: @escaping @Sendable (GRPCSwiftData) -> Void) {
        state.withLock { $0.sendObserver = observer }
    }

    /// Encodes `ops` into one blob and delivers it, exactly as a peer's single XPC message would.
    func deliver(_ ops: [RPCOp]) throws {
        try deliverRaw(codec.encode(ops))
    }

    /// Delivers bytes the codec did not produce -- the hostile-input path. Blocks until the core
    /// has finished routing the blob, which is what makes every assertion after it a statement
    /// about a completed routing turn rather than a race.
    func deliverRaw(_ blob: GRPCSwiftData) {
        guard let handler = state.withLock({ $0.onReceive }) else {
            XCTFail("no onReceive handler is installed on this TestPipe")
            return
        }
        state.withLock { $0.deliveredBlobs += 1 }
        // `queue.sync`, not `async`: `MessagePipe` promises delivery *on* `queue`, and running it
        // synchronously additionally means a test's next line observes the finished turn.
        queue.sync { handler(blob) }
    }

    /// Fires the peer-death handler, on `queue`, exactly as `XPCPipe` does when libxpc reports the
    /// peer gone. The only reader of ``onPeerDeath(_:)``'s stored handler, and therefore the only
    /// thing that keeps this pipe's peer-death path from being dead support code: read by
    /// `ReceiveWindowTests.testPeerDeathSweepsTheTableAndWakesAParkedWriter`.
    func killPeer() {
        guard let handler = state.withLock({ $0.onPeerDeath }) else { return }
        queue.sync { handler() }
    }

    var sentBlobs: [GRPCSwiftData] { state.withLock { $0.sent } }

    /// Every op this side has sent since the last ``takeSentOps()``, decoded back through the
    /// codec, and the buffer cleared.
    ///
    /// Decoding rather than pattern-matching bytes is deliberate: the assertion is about *which op
    /// went out*, and a byte-level assertion would also pin the encoding, which is a different
    /// test's job (`testAMalformedOpenStreamRefusalIsAFixedLiteral` is the one that wants bytes).
    func takeSentOps() -> [RPCOp] {
        let blobs = state.withLock { state -> [GRPCSwiftData] in
            let taken = state.sent
            state.sent = []
            return taken
        }
        return Self.ops(in: blobs)
    }

    private static func ops(in blobs: [GRPCSwiftData]) -> [RPCOp] {
        let codec = CompactWireCodec()
        var ops: [RPCOp] = []
        for blob in blobs {
            guard let items = try? codec.decode(blob) else {
                XCTFail("a blob this transport produced did not decode: \(Array(blob).prefix(40))")
                continue
            }
            for item in items {
                if case .op(let op) = item { ops.append(op) }
            }
        }
        return ops
    }
}

// ===========================================================================================
// MARK: - Op description, for readable failures
// ===========================================================================================

/// `RPCOp` is deliberately not `Equatable` (a `message`'s payload and a `status`'s trailers make
/// equality ambiguous), so assertions in this slice compare descriptions. Every field an assertion
/// might care about is in the string, and nothing that varies run to run is.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension RPCOp {
    var testDescription: String {
        switch self {
        case .openStream(let id, let method, let timeout):
            return "openStream(\(id), method: \(method), timeout: \(timeout.map { "\($0)" } ?? "nil"))"
        case .metadata(let id, let fields):
            let rendered = fields.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
            return "metadata(\(id), [\(rendered)])"
        case .message(let id, let payload):
            return "message(\(id), \(payload.count) byte(s))"
        case .halfClose(let id):
            return "halfClose(\(id))"
        case .status(let id, let code, let message, let trailers):
            return "status(\(id), code: \(code), message: \(message), trailers: \(trailers.count))"
        case .cancel(let id, let reason):
            return "cancel(\(id), reason: \(reason))"
        case .credit(let id, let bytes):
            return "credit(\(id), bytes: \(bytes))"
        case .goAway(let last):
            return "goAway(lastStreamID: \(last))"
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension [RPCOp] {
    var testDescriptions: [String] { map(\.testDescription) }

    /// The `cancel` ops addressed to `id`, in order.
    func cancels(forStream id: RPCStreamID) -> [String] {
        compactMap {
            if case .cancel(let cancelled, let reason) = $0, cancelled == id { return reason }
            return nil
        }
    }

    /// The `status` ops addressed to `id`, in order, as `(code, message)`.
    func statuses(forStream id: RPCStreamID) -> [(code: Int, message: String)] {
        compactMap {
            if case .status(let sid, let code, let message, _) = $0, sid == id {
                return (code, message)
            }
            return nil
        }
    }

    /// Every `credit` op's `(streamID, bytes)`, in order.
    var credits: [(id: RPCStreamID, bytes: UInt32)] {
        compactMap {
            if case .credit(let id, let bytes) = $0 { return (id, bytes) }
            return nil
        }
    }
}

// ===========================================================================================
// MARK: - CoreUnderTest
// ===========================================================================================

/// One `RPCTransportCore` over a ``TestPipe``, with the accept loop already draining.
///
/// The accept loop matters even for a test that never looks at an accepted stream: pulling an item
/// is what releases its slot against `maxConcurrentInboundStreams`
/// (`AcceptedStreamSequence.Iterator.next`), so a core whose accepts are never drained silently
/// runs out of admissions after 256 `openStream` ops. Draining into an array keeps that honest and
/// hands the test the built `RPCStream`s it needs to read.
///
/// # Ownership
///
/// The accept task captures the *box*, never `self`: `RPCTransportCore` holds the accept
/// sequence's slot-releasing callback weakly (L6), and a task that captured this wrapper strongly
/// would keep the core alive past the test and defeat the `deinit` this type relies on for cleanup.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class CoreUnderTest: Sendable {

    let pipe: TestPipe
    let core: RPCTransportCore

    private let accepted = Observed<[AcceptedRPCStream]>([])
    private let acceptTask: Task<Void, Never>

    init(role: RPCTransportCore.Role, label: String) {
        let pipe = TestPipe(label: label)
        let core = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: role)
        self.pipe = pipe
        self.core = core

        let box = accepted
        let sequence = core.acceptedStreams
        self.acceptTask = Task.detached {
            for await stream in sequence { box.append(stream) }
        }
    }

    deinit {
        acceptTask.cancel()
    }

    /// Every stream accepted so far, in accept order.
    var acceptedStreams: [AcceptedRPCStream] { accepted.value }

    func acceptedStream(_ id: RPCStreamID) -> AcceptedRPCStream? {
        accepted.value.first { $0.id == id }
    }

    /// Waits until `count` accepts have been pulled off the sequence. The accept loop is a
    /// *task*, so an `openStream` delivered synchronously by ``TestPipe/deliverRaw(_:)`` has been
    /// admitted and yielded by the time `deliverRaw` returns, but not necessarily *pulled*.
    func waitForAccepts(
        _ count: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await waitUntil(
            "\(count) accepted stream(s)", file: file, line: line
        ) { self.accepted.value.count >= count }
    }

    /// Tears the connection down and stops the accept loop. Call from a `defer` so a failing test
    /// does not leave a task running into the next one.
    func shutDown() {
        core.close()
        acceptTask.cancel()
    }
}

// ===========================================================================================
// MARK: - Raw op construction, for the hostile-input tests
// ===========================================================================================

/// Builds op bytes by hand: the 10-byte header from `CompactWireCodec`'s own layout, and whatever
/// body the test wants -- including bodies the codec would never produce.
///
/// The header layout is restated here rather than reached for, because `CompactWireCodec`'s
/// `appendHeader` is `private` and, more importantly, because a hostile-input test that built its
/// input with the encoder under test could only ever produce input the encoder considers valid.
/// **The duplication is the test.** If §O3's header ever changes, these tests must be updated
/// deliberately -- which is the correct amount of friction for a wire format.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum RawOpBytes {

    /// §O3's op kinds, by their wire numbers.
    enum Kind: UInt8 {
        case openStream = 1
        case metadata = 2
        case message = 3
        case halfClose = 4
        case status = 5
        case cancel = 6
        case credit = 7
        case goAway = 8
    }

    static let headerLength = 10

    /// One op: `kind(1) | flags(1) | streamID(4 BE) | bodyLength(4 BE) | body`.
    ///
    /// - Parameter declaredBodyLength: what the header *claims*, defaulting to `body.count`. Pass a
    ///   different number to build the exact shape a peer uses to make a reader slice past the end
    ///   of the buffer.
    static func op(
        kind: UInt8, streamID: RPCStreamID, body: Data, declaredBodyLength: UInt32? = nil,
        flags: UInt8 = 0
    ) -> Data {
        var out = Data()
        out.append(kind)
        out.append(flags)
        appendBE(streamID, to: &out)
        appendBE(declaredBodyLength ?? UInt32(body.count), to: &out)
        out.append(body)
        return out
    }

    static func op(
        _ kind: Kind, streamID: RPCStreamID, body: Data, declaredBodyLength: UInt32? = nil,
        flags: UInt8 = 0
    ) -> Data {
        op(
            kind: kind.rawValue, streamID: streamID, body: body,
            declaredBodyLength: declaredBodyLength, flags: flags)
    }

    /// §O3's field-list body: a 2-byte BE count, then per field a 2-byte BE name length, the name's
    /// UTF-8, a 4-byte BE value length, the value's UTF-8.
    ///
    /// - Parameter declaredCount: what the body's leading count field claims, defaulting to
    ///   `fields.count`.
    static func fieldList(_ fields: [(name: String, value: String)], declaredCount: UInt16? = nil)
        -> Data
    {
        var out = Data()
        appendBE(declaredCount ?? UInt16(fields.count), to: &out)
        for field in fields {
            let name = Array(field.name.utf8)
            appendBE(UInt16(name.count), to: &out)
            out.append(contentsOf: name)
            let value = Array(field.value.utf8)
            appendBE(UInt32(value.count), to: &out)
            out.append(contentsOf: value)
        }
        return out
    }

    /// A legal `openStream` body for `method`: §O3's reserved field set, and nothing else unless
    /// `extraFields` asks for it.
    ///
    /// - Parameter timeout: a `grpc-timeout` value, e.g. `"1500000u"`.
    /// - Parameter extraFields: appended verbatim. §O2 says user metadata travels in its own
    ///   `metadata` op and never inside `openStream`'s field list, so anything passed here makes the
    ///   body **illegal** -- which is exactly what
    ///   `WireProtocolTests.testAnOpenStreamCarryingStrayMetadataIsRejected` needs, and it must be
    ///   built by adding a field to an otherwise-valid body rather than by hand, or the test could
    ///   be failing for some unrelated reason.
    static func openStreamBody(
        method: String, timeout: String? = nil,
        extraFields: [(name: String, value: String)] = []
    ) -> Data {
        var fields: [(name: String, value: String)] = [
            (":method", "POST"), (":scheme", "https"), (":path", "/" + method),
            ("te", "trailers"), ("content-type", "application/grpc"),
        ]
        if let timeout { fields.append(("grpc-timeout", timeout)) }
        fields.append(contentsOf: extraFields)
        return fieldList(fields)
    }

    static func appendBE<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
    }

    static func blob(_ parts: Data...) -> GRPCSwiftData {
        var out = Data()
        for part in parts { out.append(part) }
        return GRPCSwiftData(viewing: out)
    }

    /// A blob whose bytes do **not** start at index 0.
    ///
    /// `CompactWireCodec` derives every offset from the buffer's own `startIndex` because in
    /// production its input is always a slice of a received XPC payload -- `GRPCSwiftData` indices
    /// do not rebase to zero. A codec test whose input always starts at 0 cannot tell a correct
    /// offset from a hardcoded one, so the field-list and boundary cases run against a slice.
    static func offsetBlob(_ data: Data, leadingPadding: Int = 7) -> GRPCSwiftData {
        var padded = Data(repeating: 0xEE, count: leadingPadding)
        padded.append(data)
        return GRPCSwiftData(viewing: padded[(padded.startIndex + leadingPadding)...])
    }
}

// ===========================================================================================
// MARK: - Flow-control payload sizes
// ===========================================================================================

/// The sizes this slice's arithmetic is written against, named so a reader can check the
/// arithmetic without recomputing the constants.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum WindowSizes {
    /// §O4's initial window, restated so an assertion reads as arithmetic rather than as a
    /// re-derivation of the production constant. Pinned equal to it by
    /// `testTheReceiveWindowBoundaryIsExactlyInitialWindow`.
    static let initial = 65_535

    /// A message size chosen so the backpressure bound is a clean division with a **non-zero**
    /// remainder: 13 × 5 000 = 65 000 fits, and the 14th needs 5 000 with only 535 left. A size
    /// that divided evenly would make "the last write parks" and "the last write completes"
    /// indistinguishable at the boundary.
    static let backpressureMessage = 5_000
    static let backpressureWritesThatFit = initial / backpressureMessage           // 13
    static let backpressureBytesThatFit = backpressureWritesThatFit * backpressureMessage  // 65 000

    static func payload(_ byteCount: Int, seed: UInt8 = 0x41) -> GRPCSwiftData {
        GRPCSwiftData(repeating: seed, count: byteCount)
    }
}
