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
    static let repository = "brandonee916/claude-mcp-manager"

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
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
            guard let tag = body["tag_name"]?.stringValue else {
                throw UpdateError.unavailable("the reply had no release tag.")
            }
            let formatter = ISO8601DateFormatter()
            return Release(
                version: normalise(tag),
                title: body["name"]?.stringValue ?? tag,
                notes: body["body"]?.stringValue ?? "",
                pageURL: body["html_url"]?.stringValue.flatMap(URL.init(string:))
                    ?? repositoryURL.appendingPathComponent("releases"),
                publishedAt: body["published_at"]?.stringValue.flatMap(formatter.date(from:))
            )
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
    @Published var available: Release?
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
            let release = try await UpdateChecker.latestRelease()
            if UpdateChecker.isNewer(release.version, than: currentVersion) {
                available = release
                return true
            }
            available = nil
            confirmedUpToDate = true
            return false
        } catch {
            if announceFailures { lastError = error.localizedDescription }
            throw error
        }
    }
}
