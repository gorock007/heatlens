import Foundation
import HeatLensCore

/// Owns the one history database (brief 2c, docs/v2/ADR-0005). Nothing opens or creates the
/// file until "Keep history" is on and a live session starts.
@MainActor
final class HistoryService {
    static let shared = HistoryService()

    private(set) var store: HistoryStore?
    private(set) var lastError: String?
    private let url: URL

    init(url: URL = HistoryStore.defaultURL) {
        self.url = url
    }

    /// The open store, opened on first use; nil (with `lastError`) when it can't be opened.
    func store(retentionDays: Int) -> HistoryStore? {
        if let store {
            Task { try? await store.setRetention(days: retentionDays) }
            return store
        }
        do {
            let opened = try HistoryStore(url: url, retentionDays: retentionDays)
            store = opened
            lastError = nil
            return opened
        } catch {
            lastError = "History couldn't be opened: \(error)"
            return nil
        }
    }

    func setRetention(days: Int) {
        guard let store else { return }
        Task { try? await store.setRetention(days: days) }
    }

    /// Closes and removes the database and its WAL. A running live session stops saving until
    /// it restarts (closing Settings restarts it).
    func deleteHistory() async {
        do {
            try await HistoryStore.deleteHistory(at: url, closing: store)
            store = nil
            lastError = nil
        } catch {
            lastError = "History couldn't be deleted: \(error)"
        }
    }

    /// Bytes on disk, whether or not the store is open.
    var fileSize: UInt64 {
        ["", "-wal"].reduce(0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? UInt64) ?? nil
            return total + (size ?? 0)
        }
    }
}
