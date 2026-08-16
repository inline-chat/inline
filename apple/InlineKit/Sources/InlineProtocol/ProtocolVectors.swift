import Foundation

/// Frozen, language-neutral conformance vectors for Inline Protocol v1.
public enum InlineProtocolVectors {
  /// Exact JSON bytes shared with the TypeScript and Rust packages.
  public static func v1JSON() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "inline-protocol-v1",
      withExtension: "json"
    ) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
  }
}
