import Foundation
import HeatLensCore
import Observation
import os

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

    /// The store if the file already exists, without creating one: reading saved actions from
    /// Settings must not leave an empty database behind.
    func existingStore(retentionDays: Int) -> HistoryStore? {
        store ?? (fileSize > 0 ? store(retentionDays: retentionDays) : nil)
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
            ActionLog.shared.savedHistoryChanged()
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

/// The session's action log (brief 3e-1): the one `StopLedger` that process stops, force quits
/// and container stops share, kept in memory until HeatLens quits, and each new record saved to
/// history while Keep history is on (docs/v2/ADR-0005 Addendum 3e). A record made while Keep
/// history was off is never saved later; turning it on saves from that moment.
@MainActor @Observable
final class ActionLog {
    static let shared = ActionLog()

    @ObservationIgnored nonisolated let ledger: StopLedger
    /// Bumped for every new record and when saved history changes, so the Settings list reloads.
    private(set) var revision = 0
    private(set) var saveError: String?

    /// Keep history, mirrored where the ledger can read it at the moment a record is added.
    @ObservationIgnored private nonisolated let saving: OSAllocatedUnfairLock<Bool>
    @ObservationIgnored private var settings: SettingsModel?
    @ObservationIgnored private let history: HistoryService

    init(history: HistoryService = .shared) {
        self.history = history
        let saving = OSAllocatedUnfairLock(initialState: false)
        self.saving = saving
        let (added, continuation) = AsyncStream.makeStream(of: (record: ActionRecord, save: Bool).self)
        // Runs on the ledger's actor as the record is added; the save decision is made right there.
        ledger = StopLedger { record in
            continuation.yield((record, saving.withLock { $0 }))
        }
        Task { [weak self] in
            for await entry in added { self?.added(entry.record, save: entry.save) }
        }
    }

    /// Starts mirroring Settings' Keep history. Call once, at launch.
    func follow(_ settings: SettingsModel) {
        self.settings = settings
        mirrorKeepHistory()
    }

    /// The newest `limit` records of this session and, with `includingSaved`, of saved history,
    /// once each, newest first; and how many there are in all.
    func recent(limit: Int = 50, includingSaved: Bool, retentionDays: Int) async -> (records: [ActionRecord], total: Int) {
        var byID: [UUID: ActionRecord] = [:]
        for record in await ledger.records() { byID[record.id] = record }
        if includingSaved, let store = history.existingStore(retentionDays: retentionDays) {
            for record in (try? await store.actions(since: .distantPast)) ?? [] { byID[record.id] = record }
        }
        let sorted = byID.values.sorted { $0.at > $1.at }
        return (Array(sorted.prefix(limit)), sorted.count)
    }

    func savedHistoryChanged() {
        saveError = nil
        revision += 1
    }

    private func mirrorKeepHistory() {
        guard let settings else { return }
        let on = withObservationTracking { settings.keepHistory } onChange: { [weak self] in
            // Called before the change lands; read the new value on the next turn.
            Task { @MainActor in self?.mirrorKeepHistory() }
        }
        saving.withLock { $0 = on }
    }

    private func added(_ record: ActionRecord, save: Bool) {
        revision += 1
        // Checked again here, so a record made just as Keep history was turned off isn't saved.
        guard save, let settings, settings.keepHistory else { return }
        guard let store = history.store(retentionDays: settings.historyRetentionDays) else {
            saveError = history.lastError
            return
        }
        Task {
            do {
                try await store.record(actions: [record])
                saveError = nil
            } catch {
                saveError = "Action not saved to history: \(error)"
            }
        }
    }
}
