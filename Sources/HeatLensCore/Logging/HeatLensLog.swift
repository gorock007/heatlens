import Foundation
import os

/// The one place HeatLens writes to the unified log (docs/v2/PHASE-4-PLAN.md, 4d). Read it with
/// `log show --last 1h --info --predicate 'subsystem == "dev.heatlens"'`. There is no log file of
/// our own, and nothing here is ever sent anywhere.
///
/// The types decide what is public: numbers, flags and static words are `.public`; the only
/// `String` is `.name`, always `.private`, so a saved log shows `<private>`. Never log PIDs, paths,
/// argv, environment or Docker IDs. Per-tick detail is `debug` only (macOS doesn't persist it).
public enum HeatLensLog {
    public enum Category: String, Sendable {
        case live, background, history, docker, alerts, actions, helper, export
    }

    public enum Level: Sendable {
        case debug, notice, error
    }

    public enum Value: Sendable {
        case count(Int), seconds(Double), percent(Double), flag(Bool), word(StaticString)
        /// A process, project or container name: always `privacy: .private`.
        case name(String)
    }

    /// One logged line as the tests see it: the public part is already text, the names are apart.
    struct Entry: Sendable, Equatable {
        let level: Level
        let category: Category
        let event: String
        /// `key=value` pairs of the non-name values.
        let publicText: String
        /// `key=name` pairs; logged `.private`.
        let privateText: String
    }

    /// Tests set this (task-local, so parallel suites don't see each other's lines). While set,
    /// lines go here instead of the unified log.
    @TaskLocal static var sink: (@Sendable (Entry) -> Void)?

    public static func notice(_ category: Category, _ event: StaticString, _ values: KeyValuePairs<StaticString, Value> = [:]) {
        write(.notice, category, event, values)
    }

    public static func error(_ category: Category, _ event: StaticString, _ values: KeyValuePairs<StaticString, Value> = [:]) {
        write(.error, category, event, values)
    }

    /// Per-tick detail; not persisted by macOS.
    public static func debug(_ category: Category, _ event: StaticString, _ values: KeyValuePairs<StaticString, Value> = [:]) {
        write(.debug, category, event, values)
    }

    private static func write(_ level: Level, _ category: Category, _ event: StaticString, _ values: KeyValuePairs<StaticString, Value>) {
        var publicText = ""
        var privateText = ""
        for (key, value) in values {
            switch value {
            case .name(let name): privateText += " \(key)=\(name)"
            case .count(let n): publicText += " \(key)=\(n)"
            case .seconds(let s): publicText += " \(key)=\(String(format: "%.1f", s))s"
            case .percent(let p): publicText += " \(key)=\(String(format: "%.0f", p))%"
            case .flag(let b): publicText += " \(key)=\(b)"
            case .word(let w): publicText += " \(key)=\(w)"
            }
        }
        if let sink {
            sink(Entry(level: level, category: category, event: "\(event)", publicText: publicText, privateText: privateText))
            return
        }
        let logger = Logger(subsystem: "dev.heatlens", category: category.rawValue)
        // `event` is a StaticString and `publicText` holds only numbers, flags and static words;
        // names are in `privateText` alone.
        switch level {
        case .debug:
            logger.debug("\(event, privacy: .public)\(publicText, privacy: .public)\(privateText, privacy: .private)")
        case .notice:
            logger.notice("\(event, privacy: .public)\(publicText, privacy: .public)\(privateText, privacy: .private)")
        case .error:
            logger.error("\(event, privacy: .public)\(publicText, privacy: .public)\(privateText, privacy: .private)")
        }
    }
}
