import Foundation

/// Correlates replies with the requests that are waiting for them.
///
/// This exists because the XPC reply channel is deliberately unused: every packet
/// goes out one-way, so a reply is just an inbound packet that happens to carry a
/// `seq` we recognise. That is what lets either side originate a call.
///
/// There is no timeout. A request waits until the peer replies, the calling task
/// is cancelled, or the transport dies.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public actor RequestTable {

    public enum Outcome: Sendable {
        case reply(Packet.Payload)
        case failed(TransportError)
    }

    private var waiters: [UInt64: CheckedContinuation<Outcome, Never>] = [:]

    public init() {}

    public var pendingCount: Int { waiters.count }

    /// Register `seq`, run `send`, and suspend until an outcome arrives.
    ///
    /// `send` runs while the actor is still synchronously executing, so a reply
    /// that lands on another task cannot slip in before the waiter is registered.
    /// Named `waitForReply` rather than `await` because `await` as a method name
    /// collides with the keyword at every call site.
    public func waitForReply(
        seq: UInt64,
        sending send: () throws(RawTransportError) -> Void
    ) async -> Outcome {
        await withTaskCancellationHandler {
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

    /// Fail every outstanding request. Used when the transport dies.
    public func failAll(with error: TransportError) {
        let outstanding = waiters
        waiters.removeAll()
        for (_, continuation) in outstanding {
            continuation.resume(returning: .failed(error))
        }
    }
}
