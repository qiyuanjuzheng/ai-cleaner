// AICL-33 spike: JSON-RPC stdio loop with full Foundation but WITHOUT AICleanerCore.
// Used as the Tauri sidecar where AICleanerCore does not compile yet (Windows), so installer /
// runtime / idle memory can still be measured. Compare with aicleaner-core-probe on Linux and
// macOS for the cost of the Core code itself.
import Foundation

func reply(_ message: [String: Any]) {
    if var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) {
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

#if os(Windows)
let platformName = "windows"
#elseif os(Linux)
let platformName = "linux"
#else
let platformName = "macos"
#endif

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--once" {
    reply(["jsonrpc": "2.0", "id": 0, "result": ["protocol": 1, "platform": platformName, "standin": true]])
    exit(0)
}

while let line = readLine(strippingNewline: true) {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = object["method"] as? String
    else {
        reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        continue
    }
    let id = object["id"] ?? NSNull()
    switch method {
    case "hello":
        reply(["jsonrpc": "2.0", "id": id, "result": ["protocol": 1, "platform": platformName, "standin": true]])
    case "shutdown":
        reply(["jsonrpc": "2.0", "id": id, "result": ["ok": true]])
        exit(0)
    default:
        reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
    }
}
