// AICL-33 spike: minimal `aicleaner-core` sidecar used only to measure binary size, runtime
// footprint and idle memory on each platform. It is NOT the AICL-36 sidecar and has no cleanup
// capability: it answers `hello`, a read-only `scan` of a given home directory, and `shutdown`.
//
// Protocol: newline-delimited JSON-RPC 2.0 over stdio.
//   {"jsonrpc":"2.0","id":1,"method":"hello"}
//   {"jsonrpc":"2.0","id":2,"method":"scan","params":{"home":"/path/to/sandbox/home"}}
//   {"jsonrpc":"2.0","id":3,"method":"shutdown"}
// `aicleaner-core-probe --once <method> [home]` answers one request without reading stdin.
import AICleanerCore
import Foundation

let protocolVersion = 1

#if os(macOS)
let platformName = "macos"
#elseif os(Windows)
let platformName = "windows"
#elseif os(Linux)
let platformName = "linux"
#else
let platformName = "unknown"
#endif

func handle(method: String, params: [String: Any]) -> [String: Any] {
    switch method {
    case "hello":
        return [
            "protocol": protocolVersion,
            "platform": platformName,
            "profiles": BuiltInClientRules.allProfiles.count,
        ]
    case "scan":
        guard let home = params["home"] as? String else {
            return ["error": ["code": -32602, "message": "params.home is required"]]
        }
        // A non-real home keeps the engine away from the host /tmp (see ScanEngine.init).
        let engine = ScanEngine(homeDirectory: URL(fileURLWithPath: home, isDirectory: true))
        let report = engine.scan()
        return [
            "items": report.totalItemCount,
            "bytes": report.totalSizeBytes,
            "clients": report.detectedBuiltInClientsCount,
            "skippedProtected": report.skippedProtectedCount,
        ]
    default:
        return ["error": ["code": -32601, "message": "unknown method \(method)"]]
    }
}

func reply(id: Any, body: [String: Any]) {
    var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
    if let error = body["error"] {
        message["error"] = error
    } else {
        message["result"] = body
    }
    if var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) {
        // Unbuffered write: `fflush(stdout)` trips Swift 6 strict concurrency on glibc.
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--once" {
    let params: [String: Any] = arguments.count >= 4 ? ["home": arguments[3]] : [:]
    reply(id: 0, body: handle(method: arguments[2], params: params))
    exit(0)
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = object["method"] as? String
    else {
        reply(id: NSNull(), body: ["error": ["code": -32700, "message": "parse error"]])
        continue
    }
    let id = object["id"] ?? NSNull()
    if method == "shutdown" {
        reply(id: id, body: ["ok": true])
        break
    }
    reply(id: id, body: handle(method: method, params: object["params"] as? [String: Any] ?? [:]))
}
