// AICL-33 spike: the same JSON-RPC hello world as hello-essentials, but importing full Foundation
// (FoundationInternationalization + ICU). The size delta is what dropping ICU would save.
import Foundation

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
let response = Response(id: request.id, result: ["method": request.method, "foundation": "full"])
// Use an ICU-backed API so the linker keeps FoundationInternationalization.
let stamp = DateFormatter.localizedString(from: Date(timeIntervalSince1970: 0), dateStyle: .medium, timeStyle: .none)
print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stamp)
