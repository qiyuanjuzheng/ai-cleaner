import CryptoKit
import Foundation

guard let input = readLine(),
      let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32 else {
    FileHandle.standardError.write(Data("Sparkle 签名密钥应为 32 字节的 Base64 私钥种子。\n".utf8))
    exit(2)
}

let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
