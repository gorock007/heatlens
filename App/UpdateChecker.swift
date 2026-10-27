import Foundation
import HeatLensCore
import Observation

/// The click-only update check. `check()` is the only network request HeatLens makes, and it
/// runs only when the user clicks Check for updates: no timer, no launch check, nothing sent
/// beyond a User-Agent. It never installs anything.
@MainActor @Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(message: String)
    }

    static let releasesPage = URL(string: "https://github.com/gorock007/heatlens/releases")!
    private static let endpoint = URL(string: "https://api.github.com/repos/gorock007/heatlens/releases/latest")!

    private(set) var state: State = .idle

    let currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func check() async {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("HeatLens/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failed(message: "Couldn't check for updates.")
                return
            }
            let latest = try ReleaseInfo.parse(data)
            switch UpdateCheck.status(current: currentVersion, latest: latest) {
            case .upToDate: state = .upToDate
            case .available(let version, let url): state = .available(version: version, url: url)
            }
        } catch {
            state = .failed(message: "Couldn't check for updates.")
        }
    }
}
