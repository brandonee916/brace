#!/bin/bash
# Runs the test suite. Exercises the JSON parser, the paste-import cleanup, the
# model round-trip, and the save path — the last against a scratch copy of your
# real config, never the live one.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$(mktemp -d)/tests"
swiftc -O Sources/JSONValue.swift Sources/ProcessTeardown.swift Sources/JSONLenient.swift Sources/MCPServer.swift Sources/CommandResolver.swift Sources/RegistryClient.swift \
       Sources/Validation.swift Sources/ServerTester.swift Sources/EndpointProbe.swift Sources/ConfigStore.swift Sources/HelpDocument.swift Sources/UpdateChecker.swift Tests/main.swift -o "$BIN"
"$BIN"
