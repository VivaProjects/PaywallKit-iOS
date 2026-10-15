import Foundation
import CryptoKit

struct PaywallManifest: Decodable {
    let app: String
    let environment: String
    let issuedAt: Int
    let expiresAt: Int
    let placements: [String: Placement]

    struct Placement: Decodable {
        let stable: Reference
        let candidate: Reference?
        let basisPoints: Int
        let experimentId: String?
        let paused: Bool
        let serial: Int

        /// 跨端固定 SHA256 前四字节大端取模；同安装同实验始终分配同桶。
        func choose(installationID: String) -> (Reference, [String: String]) {
            guard let candidate, let experimentId else { return (stable, ["source": "stable"]) }
            let hash = SHA256.hash(data: Data("\(installationID)|\(experimentId)".utf8))
            let bucket = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 10000
            let useCandidate = bucket < basisPoints
            return (useCandidate ? candidate : stable,
                    ["experimentId": experimentId, "bucket": String(bucket), "source": useCandidate ? "candidate" : "stable"])
        }
    }
    struct Reference: Codable {
        let documentId: String
        let revision: Int
        let sha256: String
        let path: String
    }
}
