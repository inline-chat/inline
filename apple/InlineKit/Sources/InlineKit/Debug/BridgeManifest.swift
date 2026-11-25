#if DEBUG
import Foundation
import InlineProtocol

/// Debug harnesses only: an agent's messages exactly as the CLI bridge rendered them (text,
/// entities and blocks), from the manifest its live render lab writes
/// (`cli/src/bridge/v2/live_render.rs`, `<mode>.messages.json`). The iOS chat harness and the macOS
/// perf harness draw them so bridge output can be checked on both apps without a server.
public struct BridgeManifest: Sendable {
  public struct Message: Sendable {
    public let text: String
    public let entities: MessageEntities?
    public let blocks: BlockContentPayload?
  }

  public let agent: String
  public let messages: [Message]

  /// The manifest whose path follows `flag` on the command line, when there is one.
  public static func fromArguments(flag: String) -> BridgeManifest? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return load(path: arguments[index + 1])
  }

  public static func load(path: String) -> BridgeManifest? {
    guard let data = FileManager.default.contents(atPath: path),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = manifest["messages"] as? [[String: Any]]
    else { return nil }
    let messages = items.map { item in
      let bytes = { (key: String) in (item[key] as? String).flatMap { Data(base64Encoded: $0) } }
      return Message(
        text: item["text"] as? String ?? "",
        entities: bytes("entities").flatMap { try? MessageEntities(serializedBytes: $0) },
        blocks: bytes("blocks")
          .flatMap { try? InlineProtocol.BlockContent(serializedBytes: $0) }
          .flatMap { BlockContentPayload($0) }
      )
    }
    return BridgeManifest(agent: manifest["agent"] as? String ?? "Agent", messages: messages)
  }
}
#endif
