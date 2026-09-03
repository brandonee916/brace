import Foundation

/// A server as published to the MCP registry.
///
/// Everything here is a declaration the *author* wrote and uploaded — nothing is
/// discovered by inspecting the package or talking to the server. That's why the
/// UI shows the published version alongside what the package registry actually
/// ships: the two drift, sometimes badly.
struct RegistryServer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let title: String
    let summary: String
    let version: String
    let repositoryURL: String?
    let websiteURL: String?
    let packages: [RegistryPackage]
    let remotes: [RegistryRemote]

    /// The last path component, e.g. `unifi-network-mcp` from
    /// `io.github.sirkirby/unifi-network-mcp`.
    var shortName: String {
        name.components(separatedBy: "/").last ?? name
    }

    var displayTitle: String { title.isEmpty ? shortName : title }
}

struct RegistryPackage: Hashable {
    let registryType: String      // "pypi", "npm", "oci", "mcpb"
    let identifier: String
    let version: String
    let runtimeHint: String?
    let transportType: String
    let runtimeArguments: [RegistryArgument]
    let packageArguments: [RegistryArgument]
    let environmentVariables: [RegistryEnvironmentVariable]

    /// Launchers a registry entry is allowed to ask for.
    ///
    /// `runtimeHint` is published by whoever wrote the entry, so taking it at face
    /// value would let a listing nominate any program on the machine — including
    /// an absolute path of its choosing.
    static let allowedRuntimes: Set<String> = ["uvx", "npx", "pipx", "bunx", "deno"]

    /// The launcher this package needs. `runtimeHint` is usually absent, so it's
    /// inferred from the package registry.
    var runtime: String? {
        if let runtimeHint, !runtimeHint.isEmpty,
           Self.allowedRuntimes.contains((runtimeHint as NSString).lastPathComponent) {
            return (runtimeHint as NSString).lastPathComponent
        }
        switch registryType {
        case "pypi": return "uvx"
        case "npm": return "npx"
        default: return nil
        }
    }

    var isSupported: Bool { runtime != nil }
}

struct RegistryArgument: Hashable {
    let type: String              // "positional" or "named"
    let name: String?
    let value: String?
    let defaultValue: String?
    let description: String
    let isRequired: Bool

    /// Command-line pieces for this argument, in order.
    var commandLineParts: [String] {
        let resolved = value ?? defaultValue
        if type == "named" {
            guard let name else { return [] }
            if let resolved, !resolved.isEmpty { return [name, resolved] }
            return [name]
        }
        guard let resolved, !resolved.isEmpty else { return [] }
        return [resolved]
    }
}

struct RegistryEnvironmentVariable: Hashable {
    let name: String
    let description: String
    let isRequired: Bool
    let isSecret: Bool
    let defaultValue: String?
}

/// A hosted server, reachable over the network rather than launched locally.
struct RegistryRemote: Hashable {
    let type: String              // "streamable-http" or "sse"
    let url: String
}

// MARK: - Client

enum RegistryError: LocalizedError {
    case badResponse(Int)
    case malformed(String)
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "The registry returned an error (HTTP \(code))."
        case .malformed(let detail): return "Couldn't read the registry's reply — \(detail)"
        case .offline(let detail): return "Couldn't reach the registry — \(detail)"
        }
    }
}

struct RegistryClient {
    static let baseURL = URL(string: "https://registry.modelcontextprotocol.io")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Searches the registry, keeping only the newest entry per server name.
    static func search(_ query: String, limit: Int = 40) async throws -> [RegistryServer] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v0/servers"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "search", value: query),
        ]
        let root = try await fetchJSON(components.url!)

        var newestByName: [String: (server: RegistryServer, isLatest: Bool)] = [:]
        var order: [String] = []
        for entry in root["servers"]?.arrayValues ?? [] {
            guard let body = entry["server"], let server = parse(server: body) else { continue }
            let isLatest = entry["_meta"]?["io.modelcontextprotocol.registry/official"]?["isLatest"]?.boolValue ?? false
            if let existing = newestByName[server.name] {
                // Several versions of the same server come back; prefer the current one.
                if isLatest && !existing.isLatest {
                    newestByName[server.name] = (server, isLatest)
                }
            } else {
                newestByName[server.name] = (server, isLatest)
                order.append(server.name)
            }
        }
        return order.compactMap { newestByName[$0]?.server }
    }

    /// What the package registry actually ships right now.
    ///
    /// Registry entries are published by hand and go stale, so this is the check
    /// that catches a manifest describing a version from a year ago.
    static func latestPublishedVersion(of package: RegistryPackage) async -> String? {
        // The identifier comes from the registry, so it is somebody else's data.
        // Percent-encode it and never force-unwrap the result: today's Foundation
        // is lenient about odd URL strings, but the app also runs on macOS 14,
        // and a nil here would take the whole app down.
        guard let escaped = package.identifier
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }

        switch package.registryType {
        case "pypi":
            guard let url = URL(string: "https://pypi.org/pypi/\(escaped)/json") else { return nil }
            return try? await fetchJSON(url)["info"]?["version"]?.stringValue
        case "npm":
            guard let url = URL(string: "https://registry.npmjs.org/\(escaped)/latest") else { return nil }
            return try? await fetchJSON(url)["version"]?.stringValue
        default:
            return nil
        }
    }

    private static func fetchJSON(_ url: URL) async throws -> JSONValue {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw RegistryError.badResponse(http.statusCode)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw RegistryError.malformed("the response wasn't text")
            }
            return try JSONValue.parse(text)
        } catch let error as RegistryError {
            throw error
        } catch let error as JSONParseError {
            throw RegistryError.malformed(error.localizedDescription)
        } catch {
            throw RegistryError.offline(error.localizedDescription)
        }
    }

    // MARK: - Parsing

    static func parse(server body: JSONValue) -> RegistryServer? {
        guard let name = body["name"]?.stringValue, !name.isEmpty else { return nil }
        return RegistryServer(
            name: name,
            title: body["title"]?.stringValue ?? "",
            summary: body["description"]?.stringValue ?? "",
            version: body["version"]?.stringValue ?? "",
            repositoryURL: body["repository"]?["url"]?.stringValue,
            websiteURL: body["websiteUrl"]?.stringValue,
            packages: (body["packages"]?.arrayValues ?? []).compactMap(parse(package:)),
            remotes: (body["remotes"]?.arrayValues ?? []).compactMap { remote in
                guard let url = remote["url"]?.stringValue else { return nil }
                return RegistryRemote(type: remote["type"]?.stringValue ?? "streamable-http", url: url)
            }
        )
    }

    private static func parse(package body: JSONValue) -> RegistryPackage? {
        guard let identifier = body["identifier"]?.stringValue else { return nil }
        return RegistryPackage(
            registryType: body["registryType"]?.stringValue ?? "",
            identifier: identifier,
            version: body["version"]?.stringValue ?? "",
            runtimeHint: body["runtimeHint"]?.stringValue,
            transportType: body["transport"]?["type"]?.stringValue ?? "stdio",
            runtimeArguments: (body["runtimeArguments"]?.arrayValues ?? []).map(parse(argument:)),
            packageArguments: (body["packageArguments"]?.arrayValues ?? []).map(parse(argument:)),
            environmentVariables: (body["environmentVariables"]?.arrayValues ?? []).compactMap { variable in
                guard let name = variable["name"]?.stringValue else { return nil }
                return RegistryEnvironmentVariable(
                    name: name,
                    description: variable["description"]?.stringValue ?? "",
                    isRequired: variable["isRequired"]?.boolValue ?? false,
                    isSecret: variable["isSecret"]?.boolValue ?? false,
                    defaultValue: variable["default"]?.stringValue
                )
            }
        )
    }

    private static func parse(argument body: JSONValue) -> RegistryArgument {
        RegistryArgument(
            type: body["type"]?.stringValue ?? "positional",
            name: body["name"]?.stringValue,
            value: body["value"]?.stringValue,
            defaultValue: body["default"]?.stringValue,
            description: body["description"]?.stringValue ?? "",
            isRequired: body["isRequired"]?.boolValue ?? false
        )
    }
}

// MARK: - Turning a registry entry into a server

extension MCPServer {
    /// Builds a ready-to-edit server from a registry entry.
    ///
    /// Secret values are never filled in — only their names, descriptions and
    /// required/secret markers, so the form can prompt for them properly.
    init(registry server: RegistryServer, package: RegistryPackage?) {
        self.init()
        name = server.shortName

        if let package, let runtime = package.runtime {
            kind = .local
            // Claude Desktop doesn't load your shell PATH, so resolve the launcher
            // to a full path up front rather than leaving a bare "uvx" to fail.
            command = CommandResolver.preferred(for: runtime)?.path ?? runtime

            var parts: [String] = []
            parts.append(contentsOf: package.runtimeArguments.flatMap(\.commandLineParts))
            if runtime == "npx", !parts.contains("-y"), !parts.contains("--yes") {
                parts.append("-y")
            }
            parts.append(package.identifier)
            parts.append(contentsOf: package.packageArguments.flatMap(\.commandLineParts))
            args = parts.map(ArgItem.init)

            env = package.environmentVariables.map { variable in
                PairItem(
                    key: variable.name,
                    value: variable.isSecret ? "" : (variable.defaultValue ?? ""),
                    hint: variable.description,
                    isRequired: variable.isRequired,
                    isSecret: variable.isSecret
                )
            }
        } else if let remote = server.remotes.first {
            kind = .remote
            url = remote.url
            // The app's editor speaks "http" and "sse".
            transport = remote.type == "sse" ? "sse" : "http"
        }
    }
}
