import Darwin
import Foundation

/// Finds the repository root above a directory by checking whether marker files *exist*
/// (`fstatat`, never `open`), so no file content is ever read (PRD-v2 Phase 2, docs/v2/ADR-0004).
///
/// Rules:
/// - The nearest ancestor holding `.git` (a directory, or the file a worktree has) is the root.
/// - With no `.git` below the home directory, the nearest ancestor holding a project manifest
///   (`package.json`, `Package.swift`, `Cargo.toml`, …) is the root.
/// - The walk stops below the home directory (a dotfiles `~/.git` would otherwise claim every
///   project) and after `maximumDepth` levels.
/// - Folders macOS guards with a privacy prompt (Desktop, Documents, Downloads, iCloud Drive,
///   other volumes, network mounts) are never touched: a stat there can make macOS ask the user
///   for access, or hang on an unreachable share. Directories there keep their cwd.
///
/// Results, including "no root", are cached for `cacheLifetime`, so live mode does a handful of
/// stats per new directory rather than per tick.
public final class ProjectRootLocator: @unchecked Sendable {
    public struct Root: Hashable, Sendable {
        public let path: String
        /// The marker that ended the walk: ".git", "package.json", …
        public let marker: String
    }

    static let repositoryMarker = ".git"
    static let manifestMarkers = ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod",
                                  "pom.xml", "build.gradle", "build.gradle.kts", "Gemfile", "composer.json",
                                  "compose.yaml", "docker-compose.yml"]
    static let maximumDepth = 16
    static let cacheLimit = 2_048
    static let cacheLifetime: TimeInterval = 300

    private let home: String
    private let exists: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: (root: Root?, at: Date)] = [:]
    /// Stats issued, for tests and the probe.
    public private(set) var statCount = 0

    /// One per app, so scans and live sessions share the cache.
    public static let shared = ProjectRootLocator()

    public init(home: String = NSHomeDirectory(), exists: @escaping @Sendable (String) -> Bool = ProjectRootLocator.pathExists,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.home = (home as NSString).standardizingPath
        self.exists = exists
        self.now = now
    }

    /// The root for `directory`, or nil when no marker was found or the directory is off-limits.
    public func root(for directory: String) -> Root? {
        guard directory.hasPrefix("/") else { return nil }
        let start = (directory as NSString).standardizingPath
        guard isSearchable(start) else { return nil }
        let date = now()
        if let hit = lock.withLock({ cache[start] }), date.timeIntervalSince(hit.at) < Self.cacheLifetime {
            return hit.root
        }
        let found = walk(from: start)
        lock.withLock {
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[start] = (found, date)
        }
        return found
    }

    /// Whether the walk may stat inside `path` at all.
    func isSearchable(_ path: String) -> Bool {
        let lower = path.lowercased()
        let homeLower = home.lowercased()
        for blocked in ["/volumes", "/network", "/system", "/library", "/private", "/dev", "/cores"]
        where lower == blocked || lower.hasPrefix(blocked + "/") {
            return false
        }
        for protected in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"] {
            let prefix = homeLower + "/" + protected.lowercased()
            if lower == prefix || lower.hasPrefix(prefix + "/") { return false }
        }
        // Inside home only below it, never home itself; outside home, at least two levels deep.
        if lower == homeLower { return false }
        if !lower.hasPrefix(homeLower + "/") && path.split(separator: "/").count < 2 { return false }
        return true
    }

    private func walk(from start: String) -> Root? {
        var manifest: Root?
        var current = start
        for _ in 0..<Self.maximumDepth {
            guard isSearchable(current) else { break }
            if check(current + "/" + Self.repositoryMarker) {
                return Root(path: current, marker: Self.repositoryMarker)
            }
            if manifest == nil, let marker = Self.manifestMarkers.first(where: { check(current + "/" + $0) }) {
                manifest = Root(path: current, marker: marker)
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { break }
            current = parent
        }
        return manifest
    }

    private func check(_ path: String) -> Bool {
        lock.withLock { statCount += 1 }
        return exists(path)
    }

    /// `fstatat` without following a final symlink: existence only, no content.
    public static let pathExists: @Sendable (String) -> Bool = { path in
        var info = Darwin.stat()
        return fstatat(AT_FDCWD, path, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
}
