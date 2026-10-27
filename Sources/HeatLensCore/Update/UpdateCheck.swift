import Foundation

/// The parts of GitHub's "latest release" JSON the click-only update check reads. Only a
/// published, non-prerelease HeatLens release on github.com passes `parse`.
public struct ReleaseInfo: Hashable, Sendable {
    public static let releasesPrefix = "https://github.com/gorock007/heatlens/releases/"

    /// The tag without a leading `v`, for example `1.2.1`.
    public let version: String
    public let url: URL
    public let draft: Bool
    public let prerelease: Bool

    public enum ParseError: Error, Equatable {
        case malformed
        case draft
        case prerelease
        case foreignURL
    }

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw ParseError.malformed }
        if payload.draft == true { throw ParseError.draft }
        if payload.prerelease == true { throw ParseError.prerelease }
        guard payload.html_url.hasPrefix(releasesPrefix), let url = URL(string: payload.html_url) else {
            throw ParseError.foreignURL
        }
        var tag = payload.tag_name.trimmingCharacters(in: .whitespaces)
        if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
        return ReleaseInfo(version: tag, url: url, draft: false, prerelease: false)
    }
}

public enum UpdateStatus: Hashable, Sendable {
    case upToDate(String)
    case available(String, URL)
}

public enum UpdateCheck {
    /// `.available` only when the latest tag is numerically newer than `current`. A tag that
    /// isn't dotted numbers is never reported as an update.
    public static func status(current: String, latest: ReleaseInfo) -> UpdateStatus {
        guard let newer = components(latest.version), let installed = components(current),
              compare(newer, installed) > 0
        else { return .upToDate(current) }
        return .available(latest.version, latest.url)
    }

    /// `1.2.0` → `[1, 2, 0]`; nil for anything but dot-separated non-negative integers.
    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// Per component, missing components count as 0, so 1.2 == 1.2.0.
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
