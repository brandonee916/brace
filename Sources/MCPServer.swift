import Foundation

/// One row in a server's args list. Wrapped in a type with a stable identity so
/// SwiftUI's editable list doesn't lose focus while you're typing.
struct ArgItem: Identifiable, Equatable {
    let id = UUID()
    var value: String

    init(_ value: String = "") { self.value = value }

    static func == (lhs: ArgItem, rhs: ArgItem) -> Bool { lhs.value == rhs.value }
}

/// One environment variable or HTTP header row.
struct PairItem: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String

    /// What this variable is for, when a registry entry told us. Shown as the
    /// field's placeholder. None of these three are written to the config file —
    /// they only make the form easier to fill in.
    var hint: String?
    var isRequired: Bool
    var isSecret: Bool

    init(
        key: String = "",
        value: String = "",
        hint: String? = nil,
        isRequired: Bool = false,
        isSecret: Bool = false
    ) {
        self.key = key
        self.value = value
        self.hint = hint
        self.isRequired = isRequired
        self.isSecret = isSecret
    }

    /// Only the parts that get saved, so guidance never counts as an edit.
    static func == (lhs: PairItem, rhs: PairItem) -> Bool {
        lhs.key == rhs.key && lhs.value == rhs.value
    }
}

enum ServerKind: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local command"
        case .remote: return "Remote URL"
        }
    }

    var explanation: String {
        switch self {
        case .local: return "Claude launches a program on this Mac and talks to it over stdio."
        case .remote: return "Claude connects to a server over the network."
        }
    }
}

struct MCPServer: Identifiable, Equatable {
    let id = UUID()
    var name: String = ""
    var kind: ServerKind = .local
    var enabled: Bool = true

    // Local
    var command: String = ""
    var args: [ArgItem] = []
    var env: [PairItem] = []

    // Remote
    var url: String = ""
    var transport: String = "http"
    var headers: [PairItem] = []

    /// Any keys we don't have a dedicated editor for, kept verbatim so saving
    /// never silently drops a field a future Claude Desktop version adds.
    var extras: [(key: String, value: JSONValue)] = []

    static func == (lhs: MCPServer, rhs: MCPServer) -> Bool {
        lhs.name == rhs.name
            && lhs.kind == rhs.kind
            && lhs.enabled == rhs.enabled
            && lhs.command == rhs.command
            && lhs.args == rhs.args
            && lhs.env == rhs.env
            && lhs.url == rhs.url
            && lhs.transport == rhs.transport
            && lhs.headers == rhs.headers
            && lhs.extrasJSON == rhs.extrasJSON
    }

    var extrasJSON: String {
        JSONValue.object(extras).serialized(pretty: false)
    }

    /// Keys this app renders with a real editor. Everything else lands in `extras`.
    private static let knownKeys: Set<String> = [
        "command", "args", "env", "url", "type", "transport", "headers",
    ]

    init() {}

    init(name: String, json: JSONValue) {
        self.name = name
        let pairs = json.objectPairs ?? []

        command = json["command"]?.stringValue ?? ""
        args = (json["args"]?.stringArray ?? []).map(ArgItem.init)
        env = (json["env"]?.stringMap ?? []).map { PairItem(key: $0.0, value: $0.1) }
        url = json["url"]?.stringValue ?? ""
        headers = (json["headers"]?.stringMap ?? []).map { PairItem(key: $0.0, value: $0.1) }

        let declaredType = json["type"]?.stringValue ?? json["transport"]?.stringValue
        if !url.isEmpty || declaredType == "http" || declaredType == "sse" {
            kind = .remote
            transport = declaredType ?? "http"
        } else {
            kind = .local
        }

        extras = pairs.filter { !MCPServer.knownKeys.contains($0.key) }
    }

    var jsonValue: JSONValue {
        var pairs: [(key: String, value: JSONValue)] = []
        switch kind {
        case .local:
            pairs.append((key: "command", value: .string(command)))
            let cleanArgs = args.map(\.value).filter { !$0.isEmpty }
            if !cleanArgs.isEmpty {
                pairs.append((key: "args", value: .from(cleanArgs)))
            }
            let cleanEnv = env.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }
            if !cleanEnv.isEmpty {
                pairs.append((key: "env", value: .from(cleanEnv)))
            }
        case .remote:
            pairs.append((key: "type", value: .string(transport)))
            pairs.append((key: "url", value: .string(url)))
            let cleanHeaders = headers.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }
            if !cleanHeaders.isEmpty {
                pairs.append((key: "headers", value: .from(cleanHeaders)))
            }
        }
        pairs.append(contentsOf: extras)
        return .object(pairs)
    }

    /// Short one-line description for the sidebar.
    var summary: String {
        switch kind {
        case .local:
            let name = (command as NSString).lastPathComponent
            let firstArgs = args.map(\.value).filter { !$0.isEmpty }.prefix(2).joined(separator: " ")
            return firstArgs.isEmpty ? name : "\(name) \(firstArgs)"
        case .remote:
            return url.isEmpty ? "no URL set" : url
        }
    }
}
