import Foundation

public enum InlineProtocolTrustRoots {
  private struct Ring: Decodable {
    let rsaPublicKeyRing: [Entry]
  }

  private struct Entry: Decodable {
    let modulus: String
    let exponent: String
    let fingerprint: String
  }

  /// Production's overlapping pinned RSA ring. The key operation tool rewrites only these public
  /// values during publish-client-first rotation; private server keys never enter client source.
  private static let productionRingJSON = #"{"rsaPublicKeyRing":[]}"#

  public static let production: [InlineProtocolRSAPublicKey] = {
    (try? decodeRing(Data(productionRingJSON.utf8))) ?? []
  }()

  public static func decodeRing(_ data: Data) throws -> [InlineProtocolRSAPublicKey] {
    let ring = try JSONDecoder().decode(Ring.self, from: data)
    return try ring.rsaPublicKeyRing.map { entry in
      guard let fingerprint = Int64(entry.fingerprint) else { throw InlineProtocolError.invalidInput }
      return try InlineProtocolRSAPublicKey(
        modulus: decodeBase64URL(entry.modulus),
        exponent: decodeBase64URL(entry.exponent),
        fingerprint: fingerprint
      )
    }
  }

  private static func decodeBase64URL(_ value: String) throws -> [UInt8] {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { throw InlineProtocolError.invalidInput }
    return Array(data)
  }
}
