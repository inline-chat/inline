import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI
import UIKit

/// The Links tab: month cards with one row per message: the preview's image or a site
/// monogram, the page title and description, and each link in the message.
///
/// Finding links runs `NSDataDetector` and a regex over the message text. It used to
/// run for every message on every render; now it runs once per message and is reused
/// across pages until that message changes.
@available(iOS 17.0, *)
struct LinksTabView: View {
  @ObservedObject var linksViewModel: ChatLinksViewModel
  let onShowInChat: (InlineKit.Message) -> Void

  @State private var model = ChatInfoResourceLinksModel()

  var body: some View {
    let sections = model.sections(for: linksViewModel.linkMessages)

    LazyVStack(spacing: 0) {
      ForEach(sections) { section in
        Section {
          ForEach(section.items) { item in
            ChatInfoResourceLinkRow(item: item, onShowInChat: onShowInChat)
              .equatable()
              .chatInfoResourceRow(item.placement.position)
              .onAppear { model.list.itemAppeared(item.placement.index, window: linksViewModel) }
          }
        } header: {
          ChatInfoResourceSectionHeader(title: section.title)
        }
      }

      ChatInfoResourceFooter(
        state: linksViewModel.loadState,
        rowCount: linksViewModel.linkMessages.count,
        empty: .init(systemImage: "link", message: "No links yet"),
        onReachEnd: { model.list.pager.requestMore(linksViewModel) },
        retry: { model.list.pager.retry(linksViewModel) }
      )
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .task {
      #if DEBUG
      await ChatInfoResourceHarness.seedIfRequested()
      #endif
      await linksViewModel.loadInitial()
    }
    .onDisappear { linksViewModel.deactivate() }
  }
}

/// A message's links prepared for display.
struct ChatInfoResourceLinkItem: Identifiable, Equatable {
  let id: Int64
  let placement: ChatInfoResourcePlacement
  let message: InlineKit.Message
  let title: String
  let subtitle: String?
  let links: [LinkRowItem]
  let thumbnail: ChatInfoResourceThumbnailContent?
  let monogram: String
  let detail: String

  var primaryURL: URL? {
    links.lazy.compactMap(\.url).first
  }
}

/// Sections plus a per-message memo of parsed links.
@available(iOS 16.0, *)
@MainActor
final class ChatInfoResourceLinksModel {
  let list = ChatInfoResourceListModel<LinkMessage, ChatInfoResourceLinkItem>()

  private struct Parsed {
    let source: LinkMessage
    let content: Content
  }

  private struct Content {
    let title: String
    let subtitle: String?
    let links: [LinkRowItem]
    let thumbnail: ChatInfoResourceThumbnailContent?
    let monogram: String
  }

  private var parsed: [Int64: Parsed] = [:]

  func sections(for rows: [LinkMessage]) -> [ChatInfoResourceSection<ChatInfoResourceLinkItem>] {
    var next: [Int64: Parsed] = [:]
    next.reserveCapacity(rows.count)
    var didBuild = false
    let sections = list.cache.sections(for: rows, date: \.message.date, id: \.message.messageId) { row, placement in
      didBuild = true
      let content: Content
      if let cached = parsed[row.id], cached.source == row {
        content = cached.content
      } else {
        content = Self.content(for: row)
      }
      next[row.id] = Parsed(source: row, content: content)
      return ChatInfoResourceLinkItem(
        id: row.id,
        placement: placement,
        message: row.message,
        title: content.title,
        subtitle: content.subtitle,
        links: content.links,
        thumbnail: content.thumbnail,
        monogram: content.monogram,
        detail: ChatInfoResourceFormat.rowDate(row.message.date)
      )
    }
    if didBuild { parsed = next }
    return sections
  }

  private static func content(for row: LinkMessage) -> Content {
    let message = row.message
    var links = ChatInfoResourceLinkParser.linkItems(for: message, linkMessages: [row])
    let trimmedText = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if links.isEmpty {
      links = [LinkRowItem(
        id: "\(message.messageId)-fallback",
        messageId: message.messageId,
        text: trimmedText.isEmpty ? String(localized: "Link") : trimmedText,
        url: nil
      )]
    }

    let preview = row.urlPreview
    let host = links.lazy.compactMap { $0.url?.host() }.first.map(Self.displayHost)
    // Link detection fills in a preview whose title is just the URL; that's no title.
    let hasRealTitle = preview.map { $0.title?.isEmpty == false && $0.title != $0.url } ?? false
    let display = preview?.displayContent(maxDescriptionLength: 180)
    let title = (hasRealTitle ? display?.title : nil) ?? preview?.displaySource ?? host ?? links[0].text

    var subtitle = hasRealTitle ? display?.subtitle : nil
    if subtitle == nil, !trimmedText.isEmpty, !links.contains(where: { $0.text == trimmedText }) {
      subtitle = trimmedText
    }

    let photo = row.photoInfo
    let thumbnail: ChatInfoResourceThumbnailContent? =
      photo?.hasDisplayablePreview == true || InlineTinyThumbnailDecoder.strippedBytes(from: photo) != nil
        ? ChatInfoResourceThumbnailContent(photo: photo)
        : nil
    let monogram = (preview?.displaySource ?? host ?? title).first.map { String($0).uppercased() } ?? "#"

    return Content(title: title, subtitle: subtitle, links: links, thumbnail: thumbnail, monogram: monogram)
  }

  private static func displayHost(_ host: String) -> String {
    host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

struct LinkRowItem: Identifiable, Equatable {
  let id: String
  let messageId: Int64
  let text: String
  let url: URL?
}

@available(iOS 16.0, *)
private struct ChatInfoResourceLinkRow: View, Equatable {
  let item: ChatInfoResourceLinkItem
  let onShowInChat: (InlineKit.Message) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item
  }

  var body: some View {
    HStack(alignment: .top, spacing: ChatInfoResourceMetrics.tileSpacing) {
      tile
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(item.detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let subtitle = item.subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        ForEach(item.links) { link in
          Button {
            openLink(link.url)
          } label: {
            Text(link.text)
              .font(.subheadline)
              .foregroundStyle(.tint)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .disabled(link.url == nil)
          .accessibilityAddTraits(.isLink)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, ChatInfoResourceMetrics.rowHorizontalPadding)
    .padding(.vertical, ChatInfoResourceMetrics.rowVerticalPadding + 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    // The row opens its first link; each link line opens its own.
    .onTapGesture { openLink(item.primaryURL) }
    .accessibilityElement(children: .contain)
    .contextMenu {
      if let url = item.primaryURL {
        Button {
          openLink(url)
        } label: {
          Label("Open Link", systemImage: "safari")
        }
        Button {
          UIPasteboard.general.url = url
        } label: {
          Label("Copy Link", systemImage: "doc.on.doc")
        }
      }
      Button {
        onShowInChat(item.message)
      } label: {
        Label("Show in Chat", systemImage: "text.bubble")
      }
    }
  }

  @ViewBuilder
  private var tile: some View {
    let shape = RoundedRectangle(cornerRadius: ChatInfoResourceMetrics.tileCornerRadius, style: .continuous)
    Group {
      if let thumbnail = item.thumbnail {
        ChatInfoResourceThumbnail(
          id: item.id,
          content: thumbnail,
          cornerRadius: ChatInfoResourceMetrics.tileCornerRadius
        )
      } else {
        Text(item.monogram)
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Self.tint(for: item.monogram).gradient, in: shape)
      }
    }
    .frame(width: ChatInfoResourceMetrics.tileSize, height: ChatInfoResourceMetrics.tileSize)
    .accessibilityHidden(true)
  }

  private func openLink(_ url: URL?) {
    guard let url else { return }
    InAppBrowser.shared.open(url)
  }

  private static let tints: [UIColor] = [
    .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemRed,
    .systemOrange, .systemGreen, .systemTeal, .systemCyan,
  ]

  /// A stable color per letter, as Telegram tints link monograms.
  private static func tint(for monogram: String) -> Color {
    let scalar = monogram.unicodeScalars.first.map { Int($0.value) } ?? 0
    return Color(uiColor: tints[scalar % tints.count])
  }
}

/// Finds a message's links from entities, data detection, a fallback pattern and its
/// previews, in text order and without duplicates.
enum ChatInfoResourceLinkParser {
  private static let allowedLinkSchemes: Set<String> = ["http", "https"]
  private static let linkDetector: NSDataDetector? = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )

  private static let fallbackLinkRegex: NSRegularExpression? = {
    let pattern = "(?i)\\b((?:https?://)?(?:[a-z0-9-]+\\.)+[a-z]{2,}(?:/[^\\s]*)?)"
    return try? NSRegularExpression(pattern: pattern, options: [])
  }()

  private static let linkTrimCharacters = CharacterSet(charactersIn: ".,;:!?)]}\"'")

  private struct LinkCandidate {
    let order: Int
    let range: NSRange?
    let item: LinkRowItem
  }

  static func linkItems(
    for message: InlineKit.Message,
    linkMessages: [LinkMessage]
  ) -> [LinkRowItem] {
    let text = message.text ?? ""
    var candidates: [LinkCandidate] = []
    var order = 0

    appendEntityCandidates(from: message, text: text, candidates: &candidates, order: &order)
    appendFallbackCandidates(from: text, messageId: message.messageId, candidates: &candidates, order: &order)
    appendPreviewCandidates(from: linkMessages, messageId: message.messageId, candidates: &candidates, order: &order)

    let sorted = candidates.sorted { lhs, rhs in
      let lhsLocation = lhs.range?.location ?? Int.max
      let rhsLocation = rhs.range?.location ?? Int.max
      if lhsLocation == rhsLocation {
        if let lhsRange = lhs.range, let rhsRange = rhs.range, lhsRange.length != rhsRange.length {
          return lhsRange.length < rhsRange.length
        }
        return lhs.order < rhs.order
      }
      return lhsLocation < rhsLocation
    }

    return sorted.map(\.item)
  }

  private static func appendEntityCandidates(
    from message: InlineKit.Message,
    text: String,
    candidates: inout [LinkCandidate],
    order: inout Int
  ) {
    guard let entities = message.entities?.entities, !entities.isEmpty else { return }
    let sortedEntities = entities.sorted { $0.offset < $1.offset }

    for (index, entity) in sortedEntities.enumerated() {
      guard let candidate = linkCandidate(
        from: entity,
        index: index,
        text: text,
        messageId: message.messageId
      ) else { continue }
      appendCandidate(
        candidate.item,
        range: candidate.range,
        candidates: &candidates,
        order: &order,
        preferIfOverlap: true
      )
    }
  }

  private static func appendFallbackCandidates(
    from text: String,
    messageId: Int64,
    candidates: inout [LinkCandidate],
    order: inout Int
  ) {
    guard !text.isEmpty else { return }
    appendDetectorCandidates(from: text, messageId: messageId, candidates: &candidates, order: &order)
    appendRegexCandidates(from: text, messageId: messageId, candidates: &candidates, order: &order)
  }

  private static func appendPreviewCandidates(
    from linkMessages: [LinkMessage],
    messageId: Int64,
    candidates: inout [LinkCandidate],
    order: inout Int
  ) {
    var seen = Set<String>()
    for candidate in candidates {
      if let key = normalizedKey(for: candidate.item) {
        seen.insert(key)
      }
    }

    var index = 0
    for previewURL in linkMessages.compactMap({ $0.urlPreview?.url }).compactMap({ urlFromString($0) }) {
      let key = normalizedKey(for: previewURL)
      guard seen.insert(key).inserted else { continue }
      let item = LinkRowItem(
        id: "\(messageId)-preview-\(index)",
        messageId: messageId,
        text: previewURL.absoluteString,
        url: previewURL
      )
      appendCandidate(item, range: nil, candidates: &candidates, order: &order)
      index += 1
    }
  }

  private static func appendDetectorCandidates(
    from text: String,
    messageId: Int64,
    candidates: inout [LinkCandidate],
    order: inout Int
  ) {
    guard let detector = Self.linkDetector else { return }
    let range = NSRange(text.startIndex..., in: text)

    detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
      guard let match else { return }
      let matchRange = match.range
      let substring = (text as NSString).substring(with: matchRange)
      let display = sanitizeLinkText(substring)
      let resolvedURL: URL? = if let url = match.url,
                                 let scheme = url.scheme?.lowercased(),
                                 Self.allowedLinkSchemes.contains(scheme)
      {
        url
      } else {
        urlFromString(display)
      }

      guard let resolvedURL else { return }
      let item = LinkRowItem(
        id: "\(messageId)-detector-\(matchRange.location)-\(matchRange.length)",
        messageId: messageId,
        text: display.isEmpty ? resolvedURL.absoluteString : display,
        url: resolvedURL
      )
      appendCandidate(
        item,
        range: matchRange,
        candidates: &candidates,
        order: &order,
        preferIfOverlap: true
      )
    }
  }

  private static func appendRegexCandidates(
    from text: String,
    messageId: Int64,
    candidates: inout [LinkCandidate],
    order: inout Int
  ) {
    guard let regex = Self.fallbackLinkRegex else { return }
    let range = NSRange(text.startIndex..., in: text)

    regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
      guard let match else { return }
      let matchRange = match.range
      let substring = (text as NSString).substring(with: matchRange)
      let display = sanitizeLinkText(substring)
      guard let resolvedURL = urlFromString(display) else { return }
      let item = LinkRowItem(
        id: "\(messageId)-regex-\(matchRange.location)-\(matchRange.length)",
        messageId: messageId,
        text: display.isEmpty ? resolvedURL.absoluteString : display,
        url: resolvedURL
      )
      appendCandidate(
        item,
        range: matchRange,
        candidates: &candidates,
        order: &order,
        preferIfOverlap: true
      )
    }
  }

  private static func linkCandidate(
    from entity: InlineProtocol.MessageEntity,
    index: Int,
    text: String,
    messageId: Int64
  ) -> (item: LinkRowItem, range: NSRange?)? {
    let range = entityRange(for: entity, in: text)

    switch entity.type {
      case .url:
        guard let range else { return nil }
        let substring = (text as NSString).substring(with: range)
        let trimmed = sanitizeLinkText(substring)
        let display = trimmed.isEmpty ? "Link" : trimmed
        let resolvedURL = urlFromString(substring) ?? urlFromString(trimmed)
        return (
          item: LinkRowItem(
            id: "\(messageId)-entity-\(index)",
            messageId: messageId,
            text: display,
            url: resolvedURL
          ),
          range: range
        )

      case .textURL:
        let rawURLString = entity.textURL.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURLString = sanitizeLinkText(rawURLString)
        let display: String
        if !rawURLString.isEmpty {
          display = rawURLString
        } else if let range {
          let substring = (text as NSString).substring(with: range)
          let trimmed = sanitizeLinkText(substring)
          display = trimmed.isEmpty ? "Link" : trimmed
        } else {
          display = "Link"
        }
        let resolvedURL = rawURLString.isEmpty
          ? urlFromString(display)
          : (urlFromString(rawURLString) ?? urlFromString(trimmedURLString))
        return (
          item: LinkRowItem(
            id: "\(messageId)-entity-\(index)",
            messageId: messageId,
            text: display,
            url: resolvedURL
          ),
          range: range
        )

      default:
        return nil
    }
  }

  private static func entityRange(for entity: InlineProtocol.MessageEntity, in text: String) -> NSRange? {
    let offset = Int(entity.offset)
    let length = Int(entity.length)
    guard offset >= 0, length > 0 else { return nil }
    let range = NSRange(location: offset, length: length)
    guard range.location + range.length <= text.utf16.count else { return nil }
    return range
  }

  private static func appendCandidate(
    _ item: LinkRowItem,
    range: NSRange?,
    candidates: inout [LinkCandidate],
    order: inout Int,
    preferIfOverlap: Bool = false
  ) {
    if let range {
      if let existingIndex = candidates.firstIndex(where: { existing in
        guard let existingRange = existing.range else { return false }
        return NSIntersectionRange(existingRange, range).length > 0
      }) {
        if preferIfOverlap,
           candidates[existingIndex].item.url == nil,
           item.url != nil
        {
          candidates[existingIndex] = LinkCandidate(
            order: candidates[existingIndex].order,
            range: range,
            item: item
          )
        }
        return
      }
    } else if let key = normalizedKey(for: item) {
      if candidates.contains(where: { normalizedKey(for: $0.item) == key }) {
        return
      }
    }

    candidates.append(LinkCandidate(order: order, range: range, item: item))
    order += 1
  }

  private static func sanitizeLinkText(_ value: String) -> String {
    value.trimmingCharacters(in: Self.linkTrimCharacters.union(.whitespacesAndNewlines))
  }

  private static func normalizedKey(for item: LinkRowItem) -> String? {
    if let url = item.url {
      return normalizedKey(for: url)
    }
    let trimmed = sanitizeLinkText(item.text)
    if let url = urlFromString(trimmed) {
      return normalizedKey(for: url)
    }
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedKey(for url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    return components.string ?? url.absoluteString
  }

  private static func urlFromString(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed),
       let scheme = url.scheme?.lowercased(),
       Self.allowedLinkSchemes.contains(scheme)
    {
      return url
    }

    if let url = URL(string: "https://\(trimmed)"),
       let scheme = url.scheme?.lowercased(),
       Self.allowedLinkSchemes.contains(scheme)
    {
      return url
    }

    return nil
  }
}
