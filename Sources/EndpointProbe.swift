import Foundation
import Network

/// An address worth trying to open a socket to, taken from something you
/// actually typed into this server's settings.
struct ProbeTarget: Equatable, Sendable {
    var host: String
    /// Usually one port. Two when the settings name a host and nothing names a
    /// port, and we fall back to the ordinary web ones.
    var ports: [UInt16]
    /// Which setting it came from, so a result can name it instead of leaving
    /// you to work out which of your variables was probed.
    var source: String
    /// False when no port was written down anywhere and these are our guess.
    var portFromConfig: Bool
}

/// What happened when we tried.
struct Reachability: Hashable, Sendable {
    var host: String
    var source: String
    var reachedPort: UInt16?
    var triedPorts: [UInt16]
    var portFromConfig: Bool
    /// Whatever the system said when it wouldn't connect.
    var failure: String?

    var isReachable: Bool { reachedPort != nil }

    /// The line the test sheet shows.
    var summary: String {
        let ports = triedPorts.map(String.init).joined(separator: " or ")
        if let reachedPort {
            return portFromConfig
                ? "\(source) — \(host):\(reachedPort) answered"
                : "\(source) — \(host) answered on \(reachedPort)"
        }
        let reason = failure.map { " (\($0))" } ?? ""
        return portFromConfig
            ? "\(source) — no answer from \(host):\(ports)\(reason)"
            : "\(source) — no answer from \(host) on \(ports)\(reason)"
    }
}

/// Tries to reach the addresses a local server's own settings name.
///
/// A stdio server that proxies to something on your network — a Home Assistant,
/// a controller, an internal API — starts and completes an MCP handshake
/// perfectly well from a coffee shop, because none of that touches the network.
/// The handshake is therefore silent about the one thing you most want to know
/// when a server misbehaves away from home.
///
/// This closes that gap without guessing: it reads the addresses already written
/// into the config, opens a TCP connection to each and closes it again, and
/// reports what happened as information. It never decides a config is wrong —
/// being off a network is not a configuration error, and a check that says it is
/// would train you to ignore it.
enum EndpointProbe {
    /// Tried when a setting names a host and nothing anywhere names a port.
    /// A gateway or controller you can reach at all almost always answers one of
    /// these, and the result says which were tried so the answer is never a
    /// claim we can't back up.
    static let assumedPorts: [UInt16] = [443, 80]

    private static let schemePorts: [String: UInt16] = [
        "http": 80, "https": 443, "ws": 80, "wss": 443,
    ]

    /// Variable names that mean "the machine this server talks to".
    private static let hostKeys = [
        "host", "hostname", "server", "address", "addr", "ip", "gateway", "controller",
    ]

    // MARK: - Reading addresses out of the config

    /// Every address this server's settings name, in the order they were found.
    ///
    /// Capped, because a config with a dozen URLs in it shouldn't turn a test
    /// into a port scan.
    static func targets(in server: MCPServer, limit: Int = 4) -> [ProbeTarget] {
        guard server.kind == .local else { return [] }
        var found: [ProbeTarget] = []
        var seen = Set<String>()

        func add(_ target: ProbeTarget?) {
            guard found.count < limit, let target, !isLoopback(target.host) else { return }
            guard seen.insert("\(target.host):\(target.ports.first ?? 0)").inserted else { return }
            found.append(target)
        }

        let variables = server.env.filter { !$0.key.isEmpty }
        for pair in variables {
            if let target = target(in: pair.value, source: pair.key) {
                add(target)
                continue
            }
            // A bare hostname in something like UNIFI_HOST, with the port — if
            // one was written down at all — living in its own variable.
            guard isHostKey(pair.key), let host = hostname(in: pair.value) else { continue }
            if let port = siblingPort(for: pair.key, in: variables) {
                add(ProbeTarget(host: host, ports: [port], source: pair.key, portFromConfig: true))
            } else {
                add(ProbeTarget(host: host, ports: assumedPorts, source: pair.key, portFromConfig: false))
            }
        }
        for argument in server.args.map(\.value) where !argument.isEmpty {
            add(target(in: argument, source: "the arguments"))
        }
        return found
    }

    /// A full URL, or a bare `host:port`. Anything else isn't an address.
    private static func target(in text: String, source: String) -> ProbeTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           let host = components.host, !host.isEmpty {
            let explicit = components.port.flatMap { UInt16(exactly: $0) }
            guard let port = explicit ?? schemePorts[scheme] else { return nil }
            return ProbeTarget(host: host, ports: [port], source: source, portFromConfig: true)
        }

        // `10.0.1.5:8123` has no scheme, and URLComponents reads the host as one,
        // so this has to be taken apart by hand. Two parts only, which also means
        // a bracketed IPv6 literal falls out here rather than being mangled.
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0,
              let host = hostname(in: String(parts[0]))
        else { return nil }
        return ProbeTarget(host: host, ports: [port], source: source, portFromConfig: true)
    }

    /// The value of a setting like `UNIFI_HOST`, when it looks like a machine
    /// rather than a word.
    ///
    /// A dot is required: it's what separates `192.168.1.1` and `ha.local` from
    /// a single-label name or a setting that merely holds a string. Single-label
    /// hosts are missed by that rule, which is the safe direction to be wrong —
    /// a missing line costs nothing, a confidently wrong one costs trust.
    private static func hostname(in text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespaces)
        if let colon = candidate.firstIndex(of: ":") { candidate = String(candidate[..<colon]) }
        guard candidate.contains("."), !candidate.hasPrefix("."), !candidate.hasSuffix("."),
              !candidate.contains(".."), candidate.count <= 253,
              let first = candidate.first, first.isLetter || first.isNumber,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return candidate
    }

    private static func isHostKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return hostKeys.contains { lowered == $0 || lowered.hasSuffix("_" + $0) }
    }

    /// `UNIFI_HOST` and `UNIFI_PORT` are the usual pair, so look for the port
    /// under the same prefix before falling back to a guess.
    private static func siblingPort(for key: String, in variables: [PairItem]) -> UInt16? {
        let prefix = key.lowercased().split(separator: "_").dropLast().joined(separator: "_")
        for pair in variables {
            let lowered = pair.key.lowercased()
            guard lowered == "port" || lowered.hasSuffix("_port"),
                  lowered.split(separator: "_").dropLast().joined(separator: "_") == prefix,
                  let port = UInt16(pair.value.trimmingCharacters(in: .whitespaces)), port > 0
            else { continue }
            return port
        }
        return nil
    }

    /// The question this asks is whether you're on the same network as the
    /// service. Something on this Mac always is, so probing it can't answer that
    /// — and it would cry wolf for the many servers that start their own backend
    /// on demand, after this test has already finished.
    private static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered.hasSuffix(".localhost")
            || lowered == "::1" || lowered == "0.0.0.0" || lowered.hasPrefix("127.")
    }

    // MARK: - Trying them

    /// Probes every address at once, so the whole check costs one timeout rather
    /// than one per port.
    static func check(_ server: MCPServer, timeout: TimeInterval = 2) async -> [Reachability] {
        let targets = targets(in: server)
        guard !targets.isEmpty else { return [] }

        let attempts = await withTaskGroup(
            of: (index: Int, port: UInt16, failure: String?).self
        ) { group -> [(index: Int, port: UInt16, failure: String?)] in
            for (index, target) in targets.enumerated() {
                for port in target.ports {
                    group.addTask {
                        (index, port, await connect(host: target.host, port: port, timeout: timeout))
                    }
                }
            }
            var collected: [(index: Int, port: UInt16, failure: String?)] = []
            for await attempt in group { collected.append(attempt) }
            return collected
        }

        return targets.enumerated().map { index, target in
            let mine = attempts.filter { $0.index == index }
            // Lowest answering port, so two runs in a row say the same thing.
            let reached = mine.filter { $0.failure == nil }.map(\.port).min()
            return Reachability(
                host: target.host,
                source: target.source,
                reachedPort: reached,
                triedPorts: target.ports,
                portFromConfig: target.portFromConfig,
                failure: reached == nil ? mine.compactMap(\.failure).first : nil
            )
        }
    }

    /// Opens a TCP connection and closes it again. Nothing is sent, and nothing
    /// is read. Returns nil when it connected, or the system's reason when it
    /// didn't.
    private static func connect(host: String, port: UInt16, timeout: TimeInterval) async -> String? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return "not a valid port" }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: nil, tcp: options)
        )

        return await withCheckedContinuation { continuation in
            // The state handler fires more than once, and the deadline can land
            // on top of it. Resuming a continuation twice is a crash, so exactly
            // one of these calls is allowed through.
            let settled = Locked(false)
            let queue = DispatchQueue(label: "brace.endpoint-probe")

            @Sendable func settle(_ reason: String?) {
                var first = false
                settled.mutate { if !$0 { $0 = true; first = true } }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: reason)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settle(nil)
                case .failed(let error):
                    settle(describe(error))
                case .waiting(let error):
                    // Where an off-network attempt stops: the OS holds the
                    // connection open waiting for a route that isn't coming.
                    // Inside a two-second budget, that is a no.
                    settle(describe(error))
                case .cancelled:
                    settle("stopped")
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout + 0.5) { settle("timed out") }
            connection.start(queue: queue)
        }
    }

    /// "No route to host" rather than an error code nobody can read.
    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error {
            return String(cString: strerror(code.rawValue))
        }
        return error.localizedDescription
    }
}
