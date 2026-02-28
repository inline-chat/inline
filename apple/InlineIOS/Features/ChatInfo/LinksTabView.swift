import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI
import UIKit

struct LinksTabView: View {
  @ObservedObject var linksViewModel: ChatLinksViewModel

  private static let allowedLinkSchemes: Set<String> = ["http", "https"]
  private static let linkDetector: NSDataDetector? = {
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  }()
  private static let fallbackLinkRegex: NSRegularExpression? = {
    let pattern = "(?i)\\b((?:https?://)?(?:[a-z0-9-]+\\.)+[a-z]{2,}(?:/[^\\s]*)?)"
    return try? NSRegularExpression(pattern: pattern, options: [])
  }()
  private static let linkTrimCharacters = CharacterSet(charactersIn: ".,;:!?)]}\"'")

  var body: some View {
    VStack(spacing: 16) {
      if linksViewModel.linkMessages.isEmpty {
        VStack(spacing: 8) {
          Text("No links found in this chat.")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(linksViewModel.groupedLinkMessages, id: \.date) { group in
            let items = linkGroups(for: group)
            Section {
              ForEach(items) { item in
                LinkRow(group: item)
                  .padding(.bottom, 4)
                  .onAppear {
                    Task {
                      await linksViewModel.loadMoreIfNeeded(currentMessageId: item.messageId)
                    }
                  }
              }
            } header: {
              HStack {
                Text(formatDate(group.date))
                  .font(.subheadline)
                  .fontWeight(.medium)
                  .foregroundColor(.secondary)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color(.systemBackground).opacity(0.95))
                  )
                  .padding(.leading, 16)
                Spacer()
              }
              .padding(.top, 16)
              .padding(.bottom, 8)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      await linksViewModel.loadInitial()
    }
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }

  private func linkGroups(for group: LinkMessageGroup) -> [LinkRowGroup] {
    let groupedByMessageId = Dictionary(grouping: group.messages) { $0.message.messageId }
    var orderedMessageIds: [Int64] = []
    var seenMessageIds = Set<Int64>()

    for linkMessage in group.messages {
      let messageId = linkMessage.message.messageId
      if seenMessageIds.insert(messageId).inserted {
        orderedMessageIds.append(messageId)
      }
    }

    var items: [LinkRowGroup] = []

    for messageId in orderedMessageIds {
      guard let messageEntries = groupedByMessageId[messageId],
            let message = messageEntries.first?.message
      else { continue }

      var messageItems = linkItems(for: message, linkMessages: messageEntries)
      if messageItems.isEmpty {
        let trimmedText = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedText?.isEmpty == false ? trimmedText ?? "Link" : "Link"
        messageItems = [LinkRowItem(
          id: "\(messageId)-fallback",
          messageId: messageId,
          text: text,
          url: nil
        )]
      }

      items.append(LinkRowGroup(
        id: messageId,
        messageId: messageId,
        links: messageItems
      ))
    }

    return items
  }

  private struct LinkCandidate {
    let order: Int
    let range: NSRange?
    let item: LinkRowItem
  }

  private func linkItems(
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

  private func appendEntityCandidates(
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

  private func appendFallbackCandidates(
    from text: String,
    messageId: Int64,
    candidates: inout [LinkCandidate],
    order: inout Int
  ) {
    guard !text.isEmpty else { return }
    appendDetectorCandidates(from: text, messageId: messageId, candidates: &candidates, order: &order)
    appendRegexCandidates(from: text, messageId: messageId, candidates: &candidates, order: &order)
  }

  private func appendPreviewCandidates(
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

  private func appendDetectorCandidates(
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
      let resolvedURL: URL?

      if let url = match.url,
         let scheme = url.scheme?.lowercased(),
         Self.allowedLinkSchemes.contains(scheme)
      {
        resolvedURL = url
      } else {
        resolvedURL = urlFromString(display)
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

  private func appendRegexCandidates(
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

  private func linkCandidate(
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

  private func entityRange(for entity: InlineProtocol.MessageEntity, in text: String) -> NSRange? {
    let offset = Int(entity.offset)
    let length = Int(entity.length)
    guard offset >= 0, length > 0 else { return nil }
    let range = NSRange(location: offset, length: length)
    guard range.location + range.length <= text.utf16.count else { return nil }
    return range
  }

  private func appendCandidate(
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

  private func sanitizeLinkText(_ value: String) -> String {
    value.trimmingCharacters(in: Self.linkTrimCharacters.union(.whitespacesAndNewlines))
  }

  private func normalizedKey(for item: LinkRowItem) -> String? {
    if let url = item.url {
      return normalizedKey(for: url)
    }
    let trimmed = sanitizeLinkText(item.text)
    if let url = urlFromString(trimmed) {
      return normalizedKey(for: url)
    }
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizedKey(for url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    return components.string ?? url.absoluteString
  }

  private func urlFromString(_ value: String) -> URL? {
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

private struct LinkRowItem: Identifiable {
  let id: String
  let messageId: Int64
  let text: String
  let url: URL?
}

private struct LinkRowGroup: Identifiable {
  let id: Int64
  let messageId: Int64
  let links: [LinkRowItem]
}

private struct LinkRow: View {
  let group: LinkRowGroup

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      linkIconCircle
      linkData
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, contentVPadding)
    .padding(.horizontal, contentHPadding)
    .background {
      fileBackgroundRect
    }
    .padding(.horizontal, contentHMargin)
    .contentShape(RoundedRectangle(cornerRadius: fileWrapperCornerRadius))
  }

  private func openLink(_ url: URL?) {
    guard let url else { return }
    InAppBrowser.shared.open(url)
  }

  private var linkIconCircle: some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: linkIconCornerRadius)
        .fill(fileCircleFill)
        .frame(width: fileCircleSize, height: fileCircleSize)

      Image(systemName: "link")
        .foregroundColor(linkIconColor)
        .font(.system(size: 11))
        .padding(.top, linkIconTopPadding)
    }
  }

  private var linkData: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(group.links) { item in
        Button {
          openLink(item.url)
        } label: {
          Text(item.text)
            .font(.body)
            .foregroundColor(.blue)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(item.url == nil)
      }
    }
  }

  private var fileCircleSize: CGFloat {
    25
  }

  private var linkIconCornerRadius: CGFloat {
    6
  }

  private var linkIconTopPadding: CGFloat {
    5
  }

  private var fileCircleFill: Color {
    .primary.opacity(0.04)
  }

  private var contentVPadding: CGFloat {
    14
  }

  private var contentHPadding: CGFloat {
    14
  }

  private var contentHMargin: CGFloat {
    16
  }

  private var fileWrapperCornerRadius: CGFloat {
    18
  }

  private var linkIconColor: Color {
    .secondary
  }

  private var fileBackgroundRect: some View {
    RoundedRectangle(cornerRadius: fileWrapperCornerRadius)
      .fill(fileBackgroundColor)
  }

  private var fileBackgroundColor: Color {
    Color(UIColor { traitCollection in
      if traitCollection.userInterfaceStyle == .dark {
        UIColor(hex: "#141414") ?? UIColor.systemGray6
      } else {
        UIColor(hex: "#F8F8F8") ?? UIColor.systemGray6
      }
    })
  }
}
