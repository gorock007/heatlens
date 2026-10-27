import Foundation
import Testing
@testable import HeatLensCore

/// Fixture JSON only; nothing here touches the network.
@Suite("Update check")
struct UpdateCheckTests {
    /// A trimmed copy of the shape GitHub returns for `releases/latest`.
    private func json(tag: String = "v1.2.1",
                      url: String = "https://github.com/gorock007/heatlens/releases/tag/v1.2.1",
                      draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {
          "url": "https://api.github.com/repos/gorock007/heatlens/releases/1",
          "html_url": "\(url)",
          "id": 1,
          "tag_name": "\(tag)",
          "name": "HeatLens \(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-10-27T18:00:00Z",
          "assets": [],
          "body": "Notes"
        }
        """.utf8)
    }

    private func release(_ version: String) -> ReleaseInfo {
        ReleaseInfo(version: version, url: URL(string: ReleaseInfo.releasesPrefix + "tag/v\(version)")!,
                    draft: false, prerelease: false)
    }

    @Test("Parses GitHub's latest-release shape and strips the leading v")
    func parsesRealShape() throws {
        let info = try ReleaseInfo.parse(json())
        #expect(info.version == "1.2.1")
        #expect(info.url.absoluteString == "https://github.com/gorock007/heatlens/releases/tag/v1.2.1")
        #expect(!info.draft && !info.prerelease)
        #expect(try ReleaseInfo.parse(json(tag: "1.3.0")).version == "1.3.0")
    }

    @Test("Rejects drafts and prereleases")
    func rejectsDraftAndPrerelease() {
        #expect(throws: ReleaseInfo.ParseError.draft) { try ReleaseInfo.parse(json(draft: true)) }
        #expect(throws: ReleaseInfo.ParseError.prerelease) { try ReleaseInfo.parse(json(prerelease: true)) }
    }

    @Test("Rejects a release page outside gorock007/heatlens", arguments: [
        "https://example.com/gorock007/heatlens/releases/tag/v9.0.0",
        "http://github.com/gorock007/heatlens/releases/tag/v9.0.0",
        "https://github.com/someone/heatlens/releases/tag/v9.0.0",
        "https://github.com/gorock007/heatlens-evil/releases/tag/v9.0.0",
    ])
    func rejectsForeignURL(url: String) {
        #expect(throws: ReleaseInfo.ParseError.foreignURL) { try ReleaseInfo.parse(json(url: url)) }
    }

    @Test("Rejects JSON that isn't a release")
    func rejectsMalformed() {
        #expect(throws: ReleaseInfo.ParseError.malformed) { try ReleaseInfo.parse(Data(#"{"message":"API rate limit exceeded"}"#.utf8)) }
        #expect(throws: ReleaseInfo.ParseError.malformed) { try ReleaseInfo.parse(Data("<html>".utf8)) }
    }

    @Test("Compares versions numerically per component")
    func numericCompare() {
        #expect(UpdateCheck.status(current: "1.9.0", latest: release("1.10.0"))
            == .available("1.10.0", release("1.10.0").url))
        #expect(UpdateCheck.status(current: "1.2", latest: release("1.2.0")) == .upToDate("1.2"))
        #expect(UpdateCheck.status(current: "1.2.0", latest: release("1.2")) == .upToDate("1.2.0"))
        #expect(UpdateCheck.status(current: "1.2.0", latest: release("1.2.1"))
            == .available("1.2.1", release("1.2.1").url))
    }

    @Test("An older or equal latest release is up to date")
    func olderLatest() {
        #expect(UpdateCheck.status(current: "1.2.0", latest: release("1.1.9")) == .upToDate("1.2.0"))
        #expect(UpdateCheck.status(current: "1.2.0", latest: release("1.2.0")) == .upToDate("1.2.0"))
    }

    @Test("A malformed tag is never reported as an update", arguments: ["", "latest", "2.0.0-beta", "2..0", "9.x", "١.٢.٣"])
    func malformedTag(tag: String) {
        #expect(UpdateCheck.status(current: "1.2.0", latest: release(tag)) == .upToDate("1.2.0"))
    }
}
