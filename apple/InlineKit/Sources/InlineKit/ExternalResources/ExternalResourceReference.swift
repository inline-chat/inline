import Foundation
import InlineProtocol
import Logger

public enum ExternalResourceProvider: String, Hashable, Sendable {
  case notion
  case linear
  case github

  fileprivate init?(_ value: InlineProtocol.ExternalResourceProvider) {
    switch value {
    case .notion: self = .notion
    case .linear: self = .linear
    case .github: self = .github
    case .unspecified, .UNRECOGNIZED: return nil
    }
  }
}

public enum ExternalResourceKind: String, Hashable, Sendable {
  case page
  case database
  case issue
  case pullRequest
  case repository
  case other

  fileprivate init?(_ value: InlineProtocol.ExternalResourceKind) {
    switch value {
    case .page: self = .page
    case .database: self = .database
    case .issue: self = .issue
    case .pullRequest: self = .pullRequest
    case .repository: self = .repository
    case .other: self = .other
    case .unspecified, .UNRECOGNIZED: return nil
    }
  }
}

public struct ExternalResourceReference: Identifiable, Hashable, Sendable {
  public let id: String
  public let provider: ExternalResourceProvider
  public let kind: ExternalResourceKind
  public let title: String
  public let url: URL
  public let subtitle: String?
  public let emoji: String?

  public init(
    id: String,
    provider: ExternalResourceProvider,
    kind: ExternalResourceKind,
    title: String,
    url: URL,
    subtitle: String? = nil,
    emoji: String? = nil
  ) {
    self.id = id
    self.provider = provider
    self.kind = kind
    self.title = title
    self.url = url
    self.subtitle = subtitle
    self.emoji = emoji
  }

  public var referenceText: String {
    ExternalResourceLinkEditing.label(title: title, emoji: emoji)
  }

  fileprivate init?(_ value: InlineProtocol.ExternalResource) {
    let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.id.isEmpty,
          !title.isEmpty,
          let provider = ExternalResourceProvider(value.provider),
          let kind = ExternalResourceKind(value.kind),
          let url = URL(string: value.url),
          url.scheme?.lowercased() == "https",
          url.host != nil
    else {
      return nil
    }

    self.init(
      id: value.id,
      provider: provider,
      kind: kind,
      title: title,
      url: url,
      subtitle: value.hasSubtitle ? value.subtitle : nil,
      emoji: value.hasEmoji ? value.emoji : nil
    )
  }
}

public enum ExternalResourceSearchClient {
  private static let log = Log.scoped("ExternalResourceSearchClient", enableTracing: true)

  /// A nil peer uses only the current user's personal Notion connection.
  public static func resolveLinkLabel(peer: Peer?, url: String) async throws -> String? {
    let response = try await Api.realtime.callRpcDirect(
      method: .resolveURLPreview,
      input: .resolveURLPreview(.with {
        if let peer { $0.peerID = peer.toInputPeer() }
        $0.url = url
      }),
      timeout: .seconds(4)
    )
    guard case let .resolveURLPreview(result)? = response, result.canSubstitute else { return nil }
    return ExternalResourceLinkEditing.label(title: result.urlPreview.title, emoji: result.urlPreview.iconEmoji)
  }

  public static func search(
    peer: Peer?,
    query: String,
    limit: Int
  ) async throws -> [ExternalResourceReference] {
    log.debug(
      "event=external_resource_rpc_start query_length=\(query.utf16.count) " +
        "recent=\(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) " +
        "limit=\(limit)"
    )

    do {
      let response = try await Api.realtime.callRpcDirect(
        method: .searchExternalResources,
        input: .searchExternalResources(.with {
          if let peer { $0.peerID = peer.toInputPeer() }
          $0.query = query
          $0.limit = Int32(limit)
        }),
        timeout: .seconds(4)
      )

      guard case let .searchExternalResources(result)? = response else {
        throw ExternalResourceSearchClientError.unexpectedResponse
      }
      let resources = result.resources.compactMap(ExternalResourceReference.init)
      log.debug(
        "event=external_resource_rpc_success raw_count=\(result.resources.count) " +
          "accepted_count=\(resources.count)"
      )
      return resources
    } catch {
      log.debug(
        "event=external_resource_rpc_failure error_type=\(String(reflecting: type(of: error)))"
      )
      throw error
    }
  }
}

public enum ExternalResourceLinkEditing {
  public static func label(title: String, emoji: String?) -> String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return "" }
    let emoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return emoji.isEmpty ? title : "\(emoji) \(title)"
  }

  public static func replaceReference(
    in attributedText: NSAttributedString,
    range: NSRange,
    with resource: ExternalResourceReference,
    trailingText: String = " ",
    linkAttributes: [NSAttributedString.Key: Any]? = nil,
    trailingAttributes: [NSAttributedString.Key: Any]? = nil
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    var attributes = linkAttributes ?? [:]
    attributes[.link] = resource.url.absoluteString

    let linkedText = NSMutableAttributedString(
      string: resource.referenceText,
      attributes: attributes
    )
    linkedText.append(NSAttributedString(string: trailingText, attributes: trailingAttributes))

    let mutable = NSMutableAttributedString(attributedString: attributedText)
    let replacementRange = rangeIncludingImmediateClosingBrackets(
      in: attributedText.string,
      range: range
    )
    mutable.replaceCharacters(in: replacementRange, with: linkedText)

    return (
      NSAttributedString(attributedString: mutable),
      replacementRange.location + linkedText.length
    )
  }

  private static func rangeIncludingImmediateClosingBrackets(
    in text: String,
    range: NSRange
  ) -> NSRange {
    let nsText = text as NSString
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          NSMaxRange(range) <= nsText.length
    else {
      return range
    }

    let closingRange = NSRange(location: NSMaxRange(range), length: 2)
    guard NSMaxRange(closingRange) <= nsText.length,
          nsText.substring(with: closingRange) == "]]"
    else {
      return range
    }
    return NSRange(location: range.location, length: range.length + closingRange.length)
  }
}

private enum ExternalResourceSearchClientError: Error {
  case unexpectedResponse
}
