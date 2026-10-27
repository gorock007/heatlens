import Foundation

/// Stops a confirmed list of processes one at a time, in order, through `stop` (the app passes
/// `ProcessTerminator.requestStop`, which revalidates each pid and start time right before its
/// SIGTERM). Never parallel, never a process group, never a retry.
public struct BatchStop: Sendable {
    public typealias Stopper = @Sendable (ProcessIdentity) async -> StopOutcome

    /// Where one identity is in the run.
    public enum ItemStatus: Equatable, Sendable {
        case pending
        /// `stop` has been called for it and hasn't returned yet.
        case stopping
        case finished(StopOutcome)
        /// The run was cancelled before it got here; nothing was sent.
        case notAttempted
    }

    private let stop: Stopper

    public init(stop: @escaping Stopper) {
        self.stop = stop
    }

    /// Calls `stop` for each identity in order and reports every status change through `onUpdate`
    /// (item index, new status). Cancelling the calling task stops the run before the next item:
    /// the item in progress finishes its own stop and wait, and the rest come back `.notAttempted`.
    /// Returns one final status per identity, in the same order.
    @discardableResult
    public func run(_ identities: [ProcessIdentity],
                    onUpdate: @escaping @Sendable (Int, ItemStatus) async -> Void = { _, _ in }) async -> [ItemStatus] {
        var statuses = Array(repeating: ItemStatus.pending, count: identities.count)
        for (index, identity) in identities.enumerated() {
            if Task.isCancelled {
                for rest in index..<identities.count {
                    statuses[rest] = .notAttempted
                    await onUpdate(rest, .notAttempted)
                }
                break
            }
            statuses[index] = .stopping
            await onUpdate(index, .stopping)
            // Unstructured so a cancel doesn't cut this item's exit wait short and misreport it.
            let stop = self.stop
            let outcome = await Task { await stop(identity) }.value
            statuses[index] = .finished(outcome)
            await onUpdate(index, .finished(outcome))
        }
        return statuses
    }
}
