import CryptoKit
import Foundation

enum CLIReleaseVerification {
  private struct Envelope: Decodable {
    struct Signature: Decodable { let keyId: String; let signature: String }
    let payload: String
    let signatures: [Signature]
  }
  private struct Header: Decodable {
    let formatVersion: Int
    let channel: String
    let generation: UInt64
  }

  static func payload(
    in data: Data,
    channel: CLIUpdateChannel,
    keys: [String: String]? = nil
  ) throws -> Data {
    guard data.count <= 256 * 1_024 else { throw invalid() }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard let payload = Data(base64Encoded: envelope.payload) else { throw invalid() }
    let pinned: [String: String]
    if let keys { pinned = keys } else {
      guard let url = Bundle.module.url(forResource: "CLIReleaseKeys", withExtension: "json") else {
        throw invalid()
      }
      pinned = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    var signed = Data("inline-cli-channel-v1\0".utf8)
    signed.append(payload)
    guard envelope.signatures.prefix(4).contains(where: { entry in
      guard let encoded = pinned[entry.keyId], let raw = Data(base64Encoded: encoded),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
            let signature = Data(base64Encoded: entry.signature) else { return false }
      return key.isValidSignature(signature, for: signed)
    }) else { throw invalid() }
    let header = try JSONDecoder().decode(Header.self, from: payload)
    guard header.formatVersion == 1, header.channel == channel.rawValue, header.generation > 0 else {
      throw invalid()
    }
    return payload
  }

  private static func invalid() -> CLIInstallerFailure {
    CLIInstallerFailure(
      kind: .invalidSignature,
      title: "CLI Release Couldn’t Be Verified",
      message: "The working CLI was kept. Retry the update or check the installation instructions.",
      recoveryURL: CLIInstallerConfiguration.production.documentationURL
    )
  }
}
