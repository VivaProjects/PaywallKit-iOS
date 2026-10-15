import Foundation
import CryptoKit

struct PaywallSignatureVerifier {
    let publicKeys: [String: Data]

    /// 校验固定算法和内置 keyId，对原始 payload 字节验签避免跨端规范化差异。
    func payload(_ data: Data) throws -> Data {
        guard data.count <= 400000 else { throw failure("envelope_size") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.algorithm == "Ed25519", let key = publicKeys[envelope.keyId],
              let payload = Data(base64Encoded: envelope.payload), payload.count <= 262144,
              let signature = Data(base64Encoded: envelope.signature),
              try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: payload) else {
            throw failure("signature_invalid")
        }
        return payload
    }

    /// 摘要校验使用签名信封原始字节，Manifest 绑定不可变对象。
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func failure(_ reason: String) -> PaywallValidationError {
        PaywallValidationError(path: "$.integrity", reason: reason)
    }

    private struct Envelope: Decodable {
        let algorithm: String
        let keyId: String
        let payload: String
        let signature: String
    }
}
