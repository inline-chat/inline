import Foundation

public enum InlineDeepLink: Equatable, Sendable {
  public static let defaultScheme = "in"
  public static let productionSchemes: Set<String> = ["in", "inline"]
  public static let debugSchemes: Set<String> = ["inline-dev", "inline-debug"]
  public static let supportedSchemes: Set<String> = {
    #if DEBUG || DEBUG_BUILD
      productionSchemes.union(debugSchemes)
    #else
      productionSchemes
    #endif
  }()

  case user(id: Int64)
  case chat(id: Int64)
  case message(chatId: Int64, messageId: Int64)

  public init?(url: URL, supportedSchemes: Set<String> = Self.supportedSchemes) {
    guard let scheme = url.scheme, supportedSchemes.contains(scheme.lowercased()) else {
      return nil
    }

    guard let host = url.host?.lowercased() else {
      return nil
    }

    let query = Self.queryItems(from: url)
    let pathComponents = Self.pathComponents(from: url)

    switch host {
    case "user":
      guard pathComponents.count <= 1 else {
        return nil
      }

      guard let userId = Self.id(from: pathComponents, at: 0) ?? Self.id(from: query, names: ["id", "user_id", "userId"]) else {
        return nil
      }

      self = .user(id: userId)

    case "chat", "thread":
      guard let chatId = Self.id(from: pathComponents, at: 0) ?? Self.id(from: query, names: ["id", "chat_id", "chatId", "thread_id", "threadId"]) else {
        return nil
      }

      if let messageId = Self.messageId(from: pathComponents) {
        self = .message(chatId: chatId, messageId: messageId)
      } else if pathComponents.count <= 1 {
        if let messageId = Self.id(from: query, names: ["message_id", "messageId"]) {
          self = .message(chatId: chatId, messageId: messageId)
        } else {
          self = .chat(id: chatId)
        }
      } else {
        return nil
      }

    default:
      return nil
    }
  }

  public func url(scheme: String = Self.defaultScheme) -> URL? {
    let normalizedScheme = scheme.lowercased()
    guard Self.isSupportedScheme(normalizedScheme), isValid else {
      return nil
    }

    var components = URLComponents()
    components.scheme = normalizedScheme

    switch self {
    case let .user(id):
      components.host = "user"
      components.path = "/\(id)"

    case let .chat(id):
      components.host = "chat"
      components.path = "/\(id)"

    case let .message(chatId, messageId):
      components.host = "chat"
      components.path = "/\(chatId)/message/\(messageId)"
    }

    return components.url
  }

  public var url: URL? {
    url()
  }

  public static func isSupportedScheme(_ scheme: String?) -> Bool {
    guard let scheme else { return false }
    return supportedSchemes.contains(scheme.lowercased())
  }
}

private extension InlineDeepLink {
  var isValid: Bool {
    switch self {
    case let .user(id), let .chat(id):
      id > 0
    case let .message(chatId, messageId):
      chatId > 0 && messageId > 0
    }
  }

  static func queryItems(from url: URL) -> [String: String] {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
      return [:]
    }

    return items.reduce(into: [:]) { result, item in
      result[item.name.lowercased()] = item.value
    }
  }

  static func pathComponents(from url: URL) -> [String] {
    url.pathComponents.filter { component in
      component != "/"
    }
  }

  static func messageId(from pathComponents: [String]) -> Int64? {
    guard pathComponents.count == 3, pathComponents[1].lowercased() == "message" else {
      return nil
    }
    return id(from: pathComponents, at: 2)
  }

  static func id(from query: [String: String], names: [String]) -> Int64? {
    for name in names {
      if let id = positiveId(query[name.lowercased()]) {
        return id
      }
    }
    return nil
  }

  static func id(from pathComponents: [String], at index: Int) -> Int64? {
    guard pathComponents.indices.contains(index) else {
      return nil
    }
    return positiveId(pathComponents[index])
  }

  static func positiveId(_ value: String?) -> Int64? {
    guard let value, !value.isEmpty, value.allSatisfy(\.isNumber), let id = Int64(value), id > 0 else {
      return nil
    }
    return id
  }
}
