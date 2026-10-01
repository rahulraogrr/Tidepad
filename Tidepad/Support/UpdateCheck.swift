import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux, for the checks.
#endif

/// Whether a newer TidePad has been released: asks GitHub Releases for the latest release of the
/// repository, with Foundation's URLSession. Only the request itself is sent (no identifiers, no
/// usage data). Releases are tagged with their version ("v1.0" or "1.0"); drafts and pre-releases
/// are ignored.
enum UpdateCheck {
    static let latestRelease = URL(string: "https://api.github.com/repos/rahulraogrr/Tidepad/releases/latest")!
    /// How often the automatic check runs, at most.
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    struct Release: Equatable, Sendable {
        let version: String
        let page: URL
        let notes: String
    }

    enum Outcome: Equatable, Sendable {
        case upToDate
        case available(Release)
        /// Nothing has been released yet (or the repository isn't public).
        case noReleases
        case failed(String)
    }

    /// GitHub's answer for the latest release, or nil if it isn't a usable release.
    static func release(from data: Data) -> Release? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.draft != true, payload.prerelease != true else { return nil }
        var version = payload.tag_name.trimmingCharacters(in: .whitespaces)
        if version.lowercased().hasPrefix("v") { version.removeFirst() }
        guard !version.isEmpty else { return nil }
        return Release(version: version, page: payload.html_url, notes: payload.body ?? "")
    }

    /// Whether `version` is newer than `current`, comparing the numbers in turn: 1.10 is newer than
    /// 1.9, and 1.0 is the same as 1.
    static func isNewer(_ version: String, than current: String) -> Bool {
        func numbers(_ text: String) -> [Int] { text.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
        let new = numbers(version), old = numbers(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func check(current: String, session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TidePad/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .noReleases }
            guard status == 200 else { return .failed("GitHub answered with status \(status).") }
            guard let release = release(from: data) else { return .noReleases }
            return isNewer(release.version, than: current) ? .available(release) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
