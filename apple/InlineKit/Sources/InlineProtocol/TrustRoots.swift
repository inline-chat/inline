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

  /// Production's overlapping pinned RSA ring. Release clients intentionally keep this empty
  /// until the independent cryptography review is complete. The isolated Inline-Dev build opts
  /// into the canary ring without exposing private server keys to client source.
  #if INLINE_PROTOCOL_PRODUCTION_CANARY
  private static let productionRingJSON = #"{"rsaPublicKeyRing":[{"modulus":"y4mCEOAFrQU02g6WBGLvsy6hBh9jOfV6Hg6lvKvnRKj2vybdLTISXilcYbN2ItUfXhFf7Tk660OLhD7lBv2Pme9YVmWswHJ9j7PyyIa6klTiBLSADPPCuknvID1X7bX-Ut5IwmJDciSITHy0Qxf5yGnhRWPWOgxWDt4EdwHiOd9uHwCxLn9k8LfIXN2DOT8aPH306IB0IWMsTlnXBZ7om8nZniJG0NWG1u-BJDEk4Hz8eko1cF4wc-naVY4qcDh9zD9iXrbMJ5b8aw2JG11dvJGEBmWqjPcPJy1VqFNAZOxGUf-LXWRTnNuwECRpgvqm5oO_CFfwXUvM5W1Tw7lIVQ","exponent":"AQAB","fingerprint":"-8339382514522710386"},{"modulus":"mHcArJ0brV69p-pgk5aHpEGWMw1sp-fB7CIxqNTQU9_cTBTUzsBykiEEkZfSj1bCYuTkyhPmlsrf4yA9vP8I5rQqf7UGD1Za_W2qbbv3Wv4C3w4yV-bNJUlxG4qokDHszKgDcNumLJq8uIItXnzeg64UzKW2Bm9KikLtJTB-tq18rrNZ43xS5sZK9HHjvO3i--PdpqB0JVSD4VmjIbXHgq7v9czsYbuqlDn4mCj0rCKylQPxCKVrxbtcuP_brwW-foIkjjX8T7Q5Mi_0Zqx-VZZY7AkT8L7LJH5Lgje_IxYQp2zcLjCQf_ZNioCR0xCPMySvJnBTmVwa65wH0alkPQ","exponent":"AQAB","fingerprint":"-3957383261870667958"}]}"#
  #else
  private static let productionRingJSON = #"{"rsaPublicKeyRing":[]}"#
  #endif

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
