import Foundation

/// Correlates replies with the requests that are waiting for them.
///
/// This exists because the XPC reply channel is deliberately unused: every packet
/// goes out one-way, so a reply is just an inbound packet that happens to carry a
/// `seq` we recognise. That is what lets either side originate a call.
///
/// There is no timeout. A request waits until the peer replies, the calling task
/// is cancelled, or the transport dies.
public actor RequestTable {

    public enum Outcome: Sendable {
        case reply(Packet.Payload)
        case failed(TransportError)
    }

    private var waiters: [UInt64: CheckedContinuation<Outcome, Never>] = [:]

    /// Set by ``failAll(with:)`` and never cleared: the transport is gone and is not
    /// coming back, so every later caller gets this instead of a waiter.
    ///
    /// Without it, a caller that entered *after* `failAll` registered into a table
    /// nothing would ever complete — and this protocol has no timeout, so that is a
    /// permanent hang rather than a slow failure. The bug was real and was masked:
    /// `Transport.cancel` cancels the raw transport before failing the table, so the
    /// later `send()` threw and the catch path resumed the caller. Its only guard was
    /// an ordering in a different type, with nothing pinning it.
    ///
    /// Apple has the same problem and solves it in the same shape.
    /// `RequestManager.Request.State` is
    /// `initial -> (active(handler) | cancelled(B?)) -> completed`, and `cancelled`
    /// *stores* an outcome that arrived before any reply handler was installed;
    /// installing one then delivers it immediately and reports `false`. Theirs is
    /// per-request and ours is per-table, which is the right granularity for the one
    /// event we have: the transport dying takes every request with it.
    private var terminalFailure: TransportError?

    public init() {}

    public var pendingCount: Int { waiters.count }

    /// Register `seq`, run `send`, and suspend until an outcome arrives.
    ///
    /// `send` runs while the actor is still synchronously executing, so a reply
    /// that lands on another task cannot slip in before the waiter is registered.
    /// Named `waitForReply` rather than `await` because `await` as a method name
    /// collides with the keyword at every call site.
    ///
    /// A `seq` that is already in flight fails the *new* caller and leaves the
    /// existing waiter untouched. Overwriting would strand the displaced continuation:
    /// nothing would ever resume it, and with no timeout in this protocol its caller
    /// would hang forever. Callers reach this only by reusing an id from
    /// `Transport.allocateSeq()`, which is a programming error, so it is reported as
    /// one rather than papered over.
    public func waitForReply(
        seq: UInt64,
        sending send: () throws(RawTransportError) -> Void
    ) async -> Outcome {
        // Checked first: once the transport is gone there is nothing to send on, and
        // registering a waiter would be a hang. Deliberately *before* `send` runs, so
        // this does not depend on the raw transport reporting the failure a second
        // time — it usually does, which is what hid this.
        if let terminalFailure {
            return .failed(terminalFailure)
        }
        // Checked before installing the cancellation handler, so the early return
        // cannot let `onCancel` complete the *other* caller's waiter.
        guard waiters[seq] == nil else {
            return .failed(.transportCancelled(
                message: "duplicate request seq \(seq): already in flight"
            ))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failed(.taskCancelled))
                    return
                }
                waiters[seq] = continuation
                do {
                    try send()
                } catch {
                    waiters.removeValue(forKey: seq)
                    continuation.resume(
                        returning: .failed(.transportCancelled(message: "\(error)"))
                    )
                }
            }
        } onCancel: {
            Task { await self.complete(seq: seq, with: .failed(.taskCancelled)) }
        }
    }

    /// Deliver an outcome. Unknown or already-completed `seq` values are ignored:
    /// a duplicated reply must not resume a continuation twice.
    public func complete(seq: UInt64, with outcome: Outcome) {
        guard let continuation = waiters.removeValue(forKey: seq) else { return }
        continuation.resume(returning: outcome)
    }

    /// Fail every outstanding request, and every future one. Used when the transport
    /// dies, which is not a state anything recovers from — see ``terminalFailure``.
    public func failAll(with error: TransportError) {
        terminalFailure = error
        let outstanding = waiters
        waiters.removeAll()
        for (_, continuation) in outstanding {
            continuation.resume(returning: .failed(error))
        }
    }
}
