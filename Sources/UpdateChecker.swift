import Foundation
import SwiftUI

/// A published release, as GitHub describes it.
struct Release: Sendable {
    let version: String
    let title: String
    /// The release notes, which are the changelog section for that version.
    let notes: String
    let pageURL: URL
    let publishedAt: Date?
}

enum UpdateError: LocalizedError {
    case notPublic
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notPublic:
            return "No releases are visible. If the repository is still private, update checking starts working once it's public."
        case .unavailable(let detail):
            return "Couldn't reach GitHub — \(detail)"
        }
    }
}

enum UpdateChecker {
    static let repository = "brandonee916/brace"

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Every published release, newest first.
    ///
    /// The whole list rather than just the newest: someone three versions behind
    /// should see everything they missed, not only the most recent entry.
    static func releases(limit: Int = 30) async throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(limit)")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A private repository is indistinguishable from a missing one.
            if code == 404 { throw UpdateError.notPublic }
            guard (200..<300).contains(code) else {
                throw UpdateError.unavailable("GitHub returned HTTP \(code).")
            }
            let body = try JSONValue.parse(String(decoding: data, as: UTF8.self))
            guard let entries = body.arrayValues else {
                throw UpdateError.unavailable("the reply wasn't a list of releases.")
            }

            let formatter = ISO8601DateFormatter()
            let releases: [Release] = entries.compactMap { entry in
                guard let tag = entry["tag_name"]?.stringValue else { return nil }
                // Drafts never appear unauthenticated; pre-releases are skipped so
                // this matches what "latest" would have offered.
                if entry["prerelease"]?.boolValue == true { return nil }
                if entry["draft"]?.boolValue == true { return nil }
                return Release(
                    version: normalise(tag),
                    title: entry["name"]?.stringValue ?? tag,
                    notes: entry["body"]?.stringValue ?? "",
                    pageURL: entry["html_url"]?.stringValue.flatMap(URL.init(string:))
                        ?? repositoryURL.appendingPathComponent("releases"),
                    publishedAt: entry["published_at"]?.stringValue.flatMap(formatter.date(from:))
                )
            }
            guard !releases.isEmpty else { throw UpdateError.notPublic }
            return releases.sorted { isNewer($0.version, than: $1.version) }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.unavailable(error.localizedDescription)
        }
    }

    /// Strips a leading `v` so `v1.2.0` and `1.2.0` compare equal.
    static func normalise(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }

    /// Numeric comparison, so 1.10.0 is correctly newer than 1.9.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = normalise(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let right = normalise(current).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Owns the once-a-day check and whatever it found.
@MainActor
final class UpdateModel: ObservableObject {
    /// The newest release, when it is newer than what's running.
    @Published var available: Release?
    /// Everything newer than the running version, newest first — so the notes can
    /// cover every version that was skipped, not just the last one.
    @Published var missed: [Release] = []
    @Published var isChecking = false
    @Published var lastError: String?
    /// Set only by an explicit check, so the About window can say "you're current".
    @Published var confirmedUpToDate = false

    private static let lastCheckKey = "lastUpdateCheck"
    private let minimumInterval: TimeInterval = 60 * 60 * 24

    var currentVersion: String { UpdateChecker.currentVersion }

    /// Runs at most once a day and stays silent on failure — being offline should
    /// never produce a nag.
    func checkInBackgroundIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < minimumInterval { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        _ = try? await check(announceFailures: false)
    }

    @discardableResult
    func checkNow() async -> Bool {
        (try? await check(announceFailures: true)) ?? false
    }

    @discardableResult
    private func check(announceFailures: Bool) async throws -> Bool {
        isChecking = true
        lastError = nil
        confirmedUpToDate = false
        defer { isChecking = false }

        do {
            let releases = try await UpdateChecker.releases()
            let newer = releases.filter { UpdateChecker.isNewer($0.version, than: currentVersion) }
            if let newest = newer.first {
                available = newest
                missed = newer
                return true
            }
            available = nil
            missed = []
            confirmedUpToDate = true
            return false
        } catch {
            if announceFailures { lastError = error.localizedDescription }
            throw error
        }
    }
}
