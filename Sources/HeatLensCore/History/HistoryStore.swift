import Darwin
import Foundation
import SQLite3

/// Local, bounded history of live ticks in SQLite, the copy that ships with macOS (brief 2c,
/// docs/v2/ADR-0005). Raw ticks are kept for `highResolutionWindow`; older ticks are rolled
/// into one row per minute, kept for the retention period. Written only from live ticks, and
/// only when the user turned on "Keep history".
///
/// The file holds timestamps, load, heat, swap, power, project names and folders, container
/// and process *names*. Never command lines, environment, file contents or process IDs.
public actor HistoryStore {
    public enum Failure: Error, Equatable {
        case open(String)
        case sql(String)
        case unsafeLocation(String)
    }

    public static let highResolutionWindow: TimeInterval = 60 * 60
    public static let retentionChoices = [1, 7, 30]
    public static let defaultRetentionDays = 7
    /// Rows per table that the store never exceeds, whatever the retention.
    static let maximumEvents = 20_000
    static let maximumRollupRows = 30 * 24 * 60
    static let maximumProjectRollupRows = 30 * 24 * 60 * 10
    /// Projects kept per tick: the busiest, so a hundred idle folders don't fill the file.
    public static let projectsPerTick = 8
    static let maintenanceInterval: TimeInterval = 60
    /// The row caps are a safety net behind retention; checking them sorts whole tables.
    static let capCheckInterval: TimeInterval = 60 * 60

    public nonisolated let url: URL
    // Touched only inside the actor, and by deinit once nothing else can.
    nonisolated(unsafe) private var db: OpaquePointer?
    private var retentionDays: Int
    private let now: @Sendable () -> Date
    private var lastMaintenance: Date?
    private var lastCapCheck: Date?
    /// `projects.key` → `projects.id`, so a tick doesn't look each one up.
    private var projectIDs: [String: Int64] = [:]

    /// `~/Library/Application Support/HeatLens/history.sqlite`.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HeatLens", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    /// Opens or creates the file. The folder is created `0700`, the file and its WAL `0600`, and
    /// a symlink at either is refused.
    public init(url: URL = HistoryStore.defaultURL, retentionDays: Int = HistoryStore.defaultRetentionDays,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        self.url = url
        self.retentionDays = Self.clampedRetention(retentionDays)
        self.now = now
        let directory = url.deletingLastPathComponent()
        try Self.prepareDirectory(directory)
        if Self.isSymlink(url.path) { throw Failure.unsafeLocation(url.path) }
        // The folder itself was checked above; resolving its parents (`/var` → `/private/var`)
        // lets NOFOLLOW refuse a symlink at the file without tripping on system links above it.
        guard let resolved = realpath(directory.path, nil) else { throw Failure.unsafeLocation(directory.path) }
        let path = String(cString: resolved) + "/" + url.lastPathComponent
        free(resolved)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close(handle)
            throw Failure.open(message)
        }
        db = handle
        do {
            try Self.exec(handle, """
                PRAGMA auto_vacuum = INCREMENTAL;
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA secure_delete = ON;
                PRAGMA trusted_schema = OFF;
                CREATE TABLE IF NOT EXISTS samples (
                    ts INTEGER PRIMARY KEY, thermal INTEGER NOT NULL, busy REAL NOT NULL, busy_peak REAL NOT NULL,
                    swap INTEGER NOT NULL, pressure INTEGER NOT NULL, cpu_temp REAL, system_w REAL, process_w REAL,
                    n INTEGER NOT NULL DEFAULT 1, rolled INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS projects (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS project_samples (
                    ts INTEGER NOT NULL, project INTEGER NOT NULL, cpu REAL NOT NULL, cpu_peak REAL NOT NULL,
                    memory INTEGER NOT NULL, watts REAL, rolled INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (ts, project)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS events (
                    ts INTEGER NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, project TEXT, inference INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
                CREATE INDEX IF NOT EXISTS samples_raw ON samples (ts) WHERE rolled = 0;
                CREATE INDEX IF NOT EXISTS project_samples_raw ON project_samples (ts) WHERE rolled = 0;
                """)
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
        Self.restrictPermissions(url)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Stores one tick. Rolls up and prunes at most once a minute.
    public func record(_ point: HistoryPoint, projects: [HistoryProjectPoint], events: [TimelineEvent]) throws {
        guard let db else { throw Failure.open("closed") }
        try Self.exec(db, "BEGIN")
        do {
            try run(db, "INSERT OR REPLACE INTO samples (ts, thermal, busy, busy_peak, swap, pressure, cpu_temp, system_w, process_w, n) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    [.int(Self.millis(point.timestamp)), .int(Int64(point.thermalState.rank)), .double(point.hostBusyFraction),
                     .double(point.hostBusyPeak), .int(Int64(clamping: point.swapUsedBytes)), .int(Int64(point.memoryPressure.rank)),
                     .optionalDouble(point.cpuTemperatureCelsius), .optionalDouble(point.systemWatts), .optionalDouble(point.processWatts),
                     .int(Int64(point.sampleCount))])
            for project in projects.prefix(Self.projectsPerTick) {
                let id = try projectID(db, key: String(project.projectID.prefix(1024)), name: String(project.name.prefix(80)))
                try run(db, "INSERT OR REPLACE INTO project_samples (ts, project, cpu, cpu_peak, memory, watts) VALUES (?,?,?,?,?,?)",
                        [.int(Self.millis(project.timestamp)), .int(id), .double(project.cpuPercent), .double(project.cpuPeakPercent),
                         .int(Int64(clamping: project.memoryBytes)), .optionalDouble(project.watts)])
            }
            for event in events {
                try run(db, "INSERT INTO events (ts, kind, title, project, inference) VALUES (?,?,?,?,?)",
                        [.int(Self.millis(event.timestamp)), .text(event.kind.rawValue), .text(event.title),
                         event.projectName.map { .text($0) } ?? .null, .int(event.isInference ? 1 : 0)])
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
        let date = now()
        if lastMaintenance.map({ date.timeIntervalSince($0) >= Self.maintenanceInterval }) ?? true {
            try maintain()
        }
    }

    public func setRetention(days: Int) throws {
        retentionDays = Self.clampedRetention(days)
        try maintain()
    }

    /// Rolls raw ticks older than the high-resolution window into minutes, then drops what is
    /// past retention or over the row caps.
    public func maintain() throws {
        guard let db else { throw Failure.open("closed") }
        let date = now()
        lastMaintenance = date
        let cutoff = (Self.millis(date.addingTimeInterval(-Self.highResolutionWindow)) / 60_000) * 60_000
        let retention = Self.millis(date.addingTimeInterval(-TimeInterval(retentionDays) * 86_400))
        let hourly = lastCapCheck.map({ date.timeIntervalSince($0) >= Self.capCheckInterval }) ?? true
        try Self.exec(db, "BEGIN")
        do {
            try run(db, """
                INSERT OR REPLACE INTO samples (ts, thermal, busy, busy_peak, swap, pressure, cpu_temp, system_w, process_w, n, rolled)
                SELECT (ts / 60000) * 60000, MAX(thermal), SUM(busy * n) / SUM(n), MAX(busy_peak), MAX(swap), MAX(pressure),
                       MAX(cpu_temp), AVG(system_w), AVG(process_w), SUM(n), 1
                FROM samples WHERE rolled = 0 AND ts < ? GROUP BY ts / 60000
                """, [.int(cutoff)])
            try run(db, "DELETE FROM samples WHERE rolled = 0 AND ts < ?", [.int(cutoff)])
            try run(db, """
                INSERT OR REPLACE INTO project_samples (ts, project, cpu, cpu_peak, memory, watts, rolled)
                SELECT (ts / 60000) * 60000, project, AVG(cpu), MAX(cpu_peak), MAX(memory), AVG(watts), 1
                FROM project_samples WHERE rolled = 0 AND ts < ? GROUP BY ts / 60000, project
                """, [.int(cutoff)])
            try run(db, "DELETE FROM project_samples WHERE rolled = 0 AND ts < ?", [.int(cutoff)])
            try run(db, "DELETE FROM samples WHERE ts < ?", [.int(retention)])
            try run(db, "DELETE FROM project_samples WHERE ts < ?", [.int(retention)])
            try run(db, "DELETE FROM events WHERE ts < ?", [.int(retention)])
            if hourly {
                lastCapCheck = date
                try run(db, "DELETE FROM events WHERE rowid IN (SELECT rowid FROM events ORDER BY ts DESC LIMIT -1 OFFSET ?)",
                        [.int(Int64(Self.maximumEvents))])
                try run(db, "DELETE FROM samples WHERE ts IN (SELECT ts FROM samples ORDER BY ts DESC LIMIT -1 OFFSET ?)",
                        [.int(Int64(Self.maximumRollupRows + 720))])
                try run(db, """
                    DELETE FROM project_samples WHERE ts < (SELECT ts FROM project_samples ORDER BY ts DESC LIMIT 1 OFFSET ?)
                    """, [.int(Int64(Self.maximumProjectRollupRows + 720 * Self.projectsPerTick))])
                try Self.exec(db, "DELETE FROM projects WHERE id NOT IN (SELECT DISTINCT project FROM project_samples)")
                projectIDs.removeAll()
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
        // SQLite checkpoints the WAL itself every 1,000 pages; once an hour also give space back.
        if hourly { try Self.exec(db, "PRAGMA incremental_vacuum; PRAGMA wal_checkpoint(TRUNCATE);") }
    }

    /// Points, project points and events from `since` on, oldest first.
    public func window(since: Date) throws -> HistoryWindow {
        guard let db else { throw Failure.open("closed") }
        let from = Self.millis(since)
        var points: [HistoryPoint] = []
        try query(db, "SELECT ts, thermal, busy, busy_peak, swap, pressure, cpu_temp, system_w, process_w, n FROM samples WHERE ts >= ? ORDER BY ts",
                  [.int(from)]) { row in
            points.append(HistoryPoint(timestamp: Self.date(row.int(0)), thermalState: ThermalState(rank: Int(row.int(1))),
                                       hostBusyFraction: row.double(2), hostBusyPeak: row.double(3), swapUsedBytes: UInt64(max(0, row.int(4))),
                                       memoryPressure: MemoryPressureLevel(rank: Int(row.int(5))), cpuTemperatureCelsius: row.optionalDouble(6),
                                       systemWatts: row.optionalDouble(7), processWatts: row.optionalDouble(8), sampleCount: Int(row.int(9))))
        }
        var projects: [HistoryProjectPoint] = []
        try query(db, """
            SELECT s.ts, p.key, p.name, s.cpu, s.cpu_peak, s.memory, s.watts
            FROM project_samples s JOIN projects p ON p.id = s.project WHERE s.ts >= ? ORDER BY s.ts
            """, [.int(from)]) { row in
            projects.append(HistoryProjectPoint(timestamp: Self.date(row.int(0)), projectID: row.text(1), name: row.text(2),
                                                cpuPercent: row.double(3), cpuPeakPercent: row.double(4),
                                                memoryBytes: UInt64(max(0, row.int(5))), watts: row.optionalDouble(6)))
        }
        var events: [TimelineEvent] = []
        try query(db, "SELECT ts, kind, title, project, inference FROM events WHERE ts >= ? ORDER BY ts", [.int(from)]) { row in
            guard let kind = TimelineEvent.Kind(rawValue: row.text(1)) else { return }
            events.append(TimelineEvent(timestamp: Self.date(row.int(0)), kind: kind, title: row.text(2),
                                        projectName: row.optionalText(3), isInference: row.int(4) != 0))
        }
        return HistoryWindow(points: points, projects: projects, events: events)
    }

    /// Row counts, for tests and Settings.
    public func counts() throws -> (samples: Int, projectSamples: Int, events: Int) {
        guard let db else { throw Failure.open("closed") }
        var result = [0, 0, 0]
        for (index, table) in ["samples", "project_samples", "events"].enumerated() {
            try query(db, "SELECT COUNT(*) FROM \(table)", []) { result[index] = Int($0.int(0)) }
        }
        return (result[0], result[1], result[2])
    }

    /// Closes the database. Further calls throw.
    public func close() {
        sqlite3_close(db)
        db = nil
    }

    /// Removes the database and its WAL and shared-memory files. Closes `store` first if given.
    public static func deleteHistory(at url: URL = HistoryStore.defaultURL, closing store: HistoryStore? = nil) async throws {
        await store?.close()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            if unlink(path) != 0, errno != ENOENT {
                throw Failure.sql("couldn't delete \((path as NSString).lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Bytes on disk for the database and its WAL.
    public nonisolated var fileSize: UInt64 {
        ["", "-wal"].reduce(0) { total, suffix in
            var info = Darwin.stat()
            return total + (stat(url.path + suffix, &info) == 0 ? UInt64(info.st_size) : 0)
        }
    }

    private func projectID(_ db: OpaquePointer, key: String, name: String) throws -> Int64 {
        if let id = projectIDs[key] { return id }
        try run(db, "INSERT INTO projects (key, name) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET name = excluded.name",
                [.text(key), .text(name)])
        var id: Int64 = 0
        try query(db, "SELECT id FROM projects WHERE key = ?", [.text(key)]) { id = $0.int(0) }
        projectIDs[key] = id
        return id
    }

    // MARK: - Helpers

    static func clampedRetention(_ days: Int) -> Int { min(max(days, 1), 30) }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1000) }

    static func isSymlink(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func prepareDirectory(_ directory: URL) throws {
        if isSymlink(directory.path) { throw Failure.unsafeLocation(directory.path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = Darwin.stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw Failure.unsafeLocation(directory.path)
        }
        chmod(directory.path, 0o700)
    }

    static func restrictPermissions(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { chmod(url.path + suffix, 0o600) }
    }

    enum Value {
        case int(Int64)
        case double(Double)
        case optionalDouble(Double?)
        case text(String)
        case null
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func optionalDouble(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite3_exec failed"
            sqlite3_free(error)
            throw Failure.sql(message)
        }
    }

    /// Values are always bound, never spliced into SQL.
    private func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        try query(db, sql, values) { _ in }
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ values: [Value], row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .optionalDouble(let v): if let v { sqlite3_bind_double(statement, index, v) } else { sqlite3_bind_null(statement, index) }
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { try row(Row(statement: statement)); continue }
            guard status == SQLITE_DONE else { throw Failure.sql(String(cString: sqlite3_errmsg(db))) }
            return
        }
    }
}
