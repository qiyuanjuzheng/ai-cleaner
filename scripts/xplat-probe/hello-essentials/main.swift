// AICL-33 spike: JSON-RPC hello world that links only FoundationEssentials (no ICU).
// Compare its size with hello-foundation to isolate the cost of full Foundation + ICU data.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct Request: Decodable {
    let id: Int
    let method: String
}

struct Response: Encodable {
    var jsonrpc = "2.0"
    let id: Int
    let result: [String: String]
}

let input = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : #"{"jsonrpc":"2.0","id":1,"method":"hello"}"#
let request = try JSONDecoder().decode(Request.self, from: Data(input.utf8))
let response = Response(id: request.id, result: ["method": request.method, "foundation": "essentials"])
print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
