#if DEBUG || DEBUG_BUILD
import AppKit
import InlineKit
import InlineProtocol
import SwiftUI

struct DeveloperMessagePlaygroundConfiguration: Equatable {
  var mode = DeveloperMessagePlaygroundMode.catalog
  var renderer = DeveloperMessagePlaygroundRenderer.bubble
  var content = DeveloperMessagePlaygroundContent.shortText
  var ownership = DeveloperMessagePlaygroundOwnership.incoming
  var conversation = DeveloperMessagePlaygroundConversation.space
  var groupPosition = DeveloperMessagePlaygroundGroupPosition.isolated
  var delivery = DeveloperMessagePlaygroundDelivery.sent
  var canvasWidth = DeveloperMessagePlaygroundCanvasWidth.regular
}

struct DeveloperPlaygroundMessageView: View {
  @Binding var configuration: DeveloperMessagePlaygroundConfiguration
  @State private var richInteractionRevisions: [Int64: UInt64] = [:]
  @State private var localRichMediaReady = false

  var body: some View {
    Group {
      switch configuration.mode {
      case .catalog:
        DeveloperMessageCatalogView(
          configuration: configuration,
          interactionRevisions: richInteractionRevisions,
          localRichMediaReady: localRichMediaReady
        )
      case .lab:
        ScrollView([.horizontal, .vertical]) {
          VStack(alignment: .leading, spacing: 24) {
            DeveloperMessagePlaygroundHeader(
              title: "Message view lab",
              detail: "Change one deterministic FullMessage fixture and compare production renderers."
            )

            VStack(alignment: .leading, spacing: 16) {
              ForEach(configuration.renderer.styles, id: \.self) { style in
                DeveloperMessagePlaygroundPreview(
                  configuration: configuration,
                  style: style,
                  interactionRevisions: richInteractionRevisions
                )
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(24)
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onReceive(NotificationCenter.default.publisher(for: .richBlockDisclosureStateDidChange)) { notification in
      guard let messageStableID = notification.userInfo?["messageStableID"] as? Int64 else { return }
      richInteractionRevisions[messageStableID, default: 0] &+= 1
    }
    .task {
      localRichMediaReady = await DeveloperRichMediaFixtureCache.prepare()
    }
  }
}

struct DeveloperMessagePlaygroundInspector: View {
  @Binding var configuration: DeveloperMessagePlaygroundConfiguration

  var body: some View {
    Section("Message view") {
      Picker("View", selection: $configuration.mode) {
        ForEach(DeveloperMessagePlaygroundMode.allCases) { mode in
          Text(mode.title)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)

      Picker("Renderer", selection: $configuration.renderer) {
        ForEach(DeveloperMessagePlaygroundRenderer.allCases) { renderer in
          Text(renderer.title)
            .tag(renderer)
        }
      }
      .pickerStyle(.segmented)

      if configuration.mode == .lab {
        Picker("Content", selection: $configuration.content) {
          ForEach(DeveloperMessagePlaygroundContent.allCases) { content in
            Text(content.title)
              .tag(content)
          }
        }

        Picker("Sender", selection: $configuration.ownership) {
          ForEach(DeveloperMessagePlaygroundOwnership.allCases) { ownership in
            Text(ownership.title)
              .tag(ownership)
          }
        }
        .pickerStyle(.segmented)

        Picker("Conversation", selection: $configuration.conversation) {
          ForEach(DeveloperMessagePlaygroundConversation.allCases) { conversation in
            Text(conversation.title)
              .tag(conversation)
          }
        }
        .pickerStyle(.segmented)

        Picker("Group position", selection: $configuration.groupPosition) {
          ForEach(DeveloperMessagePlaygroundGroupPosition.allCases) { position in
            Text(position.title)
              .tag(position)
          }
        }

        Picker("Delivery", selection: $configuration.delivery) {
          ForEach(DeveloperMessagePlaygroundDelivery.allCases) { delivery in
            Text(delivery.title)
              .tag(delivery)
          }
        }
        .disabled(configuration.ownership == .incoming)
      }

      Picker("Canvas", selection: $configuration.canvasWidth) {
        ForEach(DeveloperMessagePlaygroundCanvasWidth.allCases) { width in
          Text(width.title)
            .tag(width)
        }
      }

      Button("Reset message fixture") {
        configuration = DeveloperMessagePlaygroundConfiguration()
      }
    }
  }
}

struct DeveloperMessagePlaygroundHeader: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.title2.weight(.semibold))
      Text(detail)
        .foregroundStyle(.secondary)
      Label(
        "Synthetic fixtures are render-only; local rich-content interactions remain enabled.",
        systemImage: "lock"
      )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct DeveloperMessagePlaygroundPreview: View {
  let configuration: DeveloperMessagePlaygroundConfiguration
  let style: MessageRenderStyle
  let interactionRevisions: [Int64: UInt64]

  var body: some View {
    let fixture = DeveloperMessageFixtureFactory.make(configuration: configuration)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(style.title)
          .font(.headline)
        Text(configuration.content.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      DeveloperProductionMessageRow(
        fixture: fixture,
        width: configuration.canvasWidth.points,
        style: style,
        interactionRevision: interactionRevisions[fixture.message.message.stableId] ?? 0
      )
      .frame(width: configuration.canvasWidth.points)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
      }
    }
  }
}

struct DeveloperProductionMessageRow: NSViewRepresentable {
  let fixture: DeveloperMessageFixture
  let width: CGFloat
  let style: MessageRenderStyle
  var codePresentation: RichBlockCodePresentation = .syntaxHighlighted
  var interactionRevision: UInt64 = 0
  var animateUpdates = false

  func makeNSView(context _: Context) -> MessageTableCell {
    let cell = DeveloperMessageTableCell(frame: .zero)
    configure(cell, width: width, animated: false)
    return cell
  }

  func updateNSView(_ cell: MessageTableCell, context _: Context) {
    configure(cell, width: width, animated: animateUpdates)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView _: MessageTableCell,
    context _: Context
  ) -> CGSize? {
    let width = proposal.width ?? self.width
    let props = makeProps(width: width)
    return CGSize(width: width, height: props.layout.totalHeight)
  }

  @discardableResult
  private func configure(
    _ cell: MessageTableCell,
    width: CGFloat,
    animated: Bool
  ) -> MessageViewProps {
    let props = makeProps(width: width)
    cell.setScrollState(.idle)
    cell.configure(with: fixture.message, props: props, animate: animated)
    return props
  }

  private func makeProps(width: CGFloat) -> MessageViewProps {
    _ = interactionRevision
    let inputProps = fixture.inputProps(style: style)
    let layout = MessageSizeCalculator.shared.calculateSize(
      for: fixture.message,
      with: inputProps,
      tableWidth: width,
      richContentRendererOverride: fixture.message.message.blockContent == nil ? nil : true
    ).3
    let props = MessageViewProps(
      firstInGroup: inputProps.firstInGroup,
      lastInGroup: inputProps.lastInGroup,
      startsAfterDaySeparator: inputProps.startsAfterDaySeparator,
      isLastMessage: inputProps.isLastMessage,
      isFirstMessage: inputProps.isFirstMessage,
      isRtl: inputProps.isRtl,
      isDM: inputProps.isDM,
      renderStyle: style,
      index: nil,
      translated: false,
      usesAvatarOverlay: false,
      richBlockCodePresentation: codePresentation,
      layout: layout
    )

    return props
  }
}

private final class DeveloperMessageTableCell: MessageTableCell {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    var ancestor: NSView? = hit
    while let view = ancestor {
      if view is RichBlockContentView {
        return hit
      }
      ancestor = view.superview
    }
    return nil
  }
}

struct DeveloperMessageFixture {
  let message: FullMessage
  let conversation: DeveloperMessagePlaygroundConversation
  let groupPosition: DeveloperMessagePlaygroundGroupPosition
  let isRtl: Bool

  func inputProps(style: MessageRenderStyle) -> MessageViewInputProps {
    MessageViewInputProps(
      firstInGroup: groupPosition.isFirst,
      lastInGroup: groupPosition.isLast,
      startsAfterDaySeparator: false,
      isLastMessage: false,
      isFirstMessage: false,
      isDM: conversation == .directMessage,
      isRtl: isRtl,
      translated: false,
      renderStyle: style
    )
  }
}

enum DeveloperMessageFixtureFactory {
  private static let fixtureDate = Date(timeIntervalSince1970: 1_755_000_000)

  static func make(configuration: DeveloperMessagePlaygroundConfiguration) -> DeveloperMessageFixture {
    let sender = configuration.ownership == .outgoing ? outgoingUser : incomingUser
    let messageID = stableMessageID(for: configuration)
    var message = Message(
      messageId: messageID,
      fromId: sender.id,
      date: fixtureDate,
      text: configuration.content.text,
      peerUserId: configuration.conversation == .directMessage ? incomingUser.id : nil,
      peerThreadId: configuration.conversation == .space ? 9_001 : nil,
      chatId: 9_001,
      out: configuration.ownership == .outgoing,
      status: configuration.ownership == .outgoing ? configuration.delivery.status : nil,
      repliedToMessageId: configuration.content == .reply ? 8_001 : nil,
      forwardFromPeerUserId: configuration.content == .forwarded ? forwardedUser.id : nil,
      forwardFromMessageId: configuration.content == .forwarded ? 7_001 : nil,
      entities: configuration.content.entities
    )
    message.globalId = messageID

    let reactions = configuration.content == .reactions
      ? makeReactions(messageID: messageID)
      : []

    return DeveloperMessageFixture(
      message: FullMessage(
        senderInfo: UserInfo(user: sender),
        forwardFromPeerUserInfo: configuration.content == .forwarded
          ? UserInfo(user: forwardedUser)
          : nil,
        message: message,
        reactions: reactions,
        repliedToMessage: configuration.content == .reply ? makeRepliedToMessage() : nil,
        attachments: []
      ),
      conversation: configuration.conversation,
      groupPosition: configuration.groupPosition,
      isRtl: configuration.content == .rightToLeft
    )
  }

  private static func stableMessageID(for configuration: DeveloperMessagePlaygroundConfiguration) -> Int64 {
    Int64(
      10_000
        + configuration.content.fixtureIndex * 1_000
        + configuration.ownership.fixtureIndex * 100
        + configuration.conversation.fixtureIndex * 10
        + configuration.groupPosition.fixtureIndex
    )
  }

  private static func makeRepliedToMessage() -> EmbeddedMessage {
    var message = Message(
      messageId: 8_001,
      fromId: repliedToUser.id,
      date: fixtureDate.addingTimeInterval(-120),
      text: "The launch checklist is ready for review.",
      peerUserId: nil,
      peerThreadId: 9_001,
      chatId: 9_001
    )
    message.globalId = 8_001
    return EmbeddedMessage(
      message: message,
      senderInfo: UserInfo(user: repliedToUser)
    )
  }

  private static func makeReactions(messageID: Int64) -> [FullReaction] {
    [
      FullReaction(
        reaction: Reaction(
          id: 1,
          messageId: messageID,
          userId: incomingUser.id,
          emoji: "👍",
          date: fixtureDate,
          chatId: 9_001
        ),
        userInfo: UserInfo(user: incomingUser)
      ),
      FullReaction(
        reaction: Reaction(
          id: 2,
          messageId: messageID,
          userId: repliedToUser.id,
          emoji: "👍",
          date: fixtureDate.addingTimeInterval(1),
          chatId: 9_001
        ),
        userInfo: UserInfo(user: repliedToUser)
      ),
      FullReaction(
        reaction: Reaction(
          id: 3,
          messageId: messageID,
          userId: forwardedUser.id,
          emoji: "🎉",
          date: fixtureDate.addingTimeInterval(2),
          chatId: 9_001
        ),
        userInfo: UserInfo(user: forwardedUser)
      ),
    ]
  }

  private static let incomingUser = User(
    id: 7_001,
    email: "ava@example.com",
    firstName: "Ava",
    lastName: "Lin"
  )

  private static let outgoingUser = User(
    id: 7_002,
    email: "mo@example.com",
    firstName: "Mo"
  )

  private static let repliedToUser = User(
    id: 7_003,
    email: "sam@example.com",
    firstName: "Sam",
    lastName: "Rivera"
  )

  private static let forwardedUser = User(
    id: 7_004,
    email: "noor@example.com",
    firstName: "Noor",
    lastName: "Azadi"
  )
}

enum DeveloperMessagePlaygroundRenderer: String, CaseIterable, Identifiable {
  case compare
  case bubble
  case minimal

  var id: Self { self }

  var title: String {
    switch self {
    case .compare: "Compare"
    case .bubble: "Bubble"
    case .minimal: "Minimal"
    }
  }

  var styles: [MessageRenderStyle] {
    switch self {
    case .compare: [.bubble, .minimal]
    case .bubble: [.bubble]
    case .minimal: [.minimal]
    }
  }
}

enum DeveloperMessagePlaygroundMode: String, CaseIterable, Identifiable {
  case catalog
  case lab

  var id: Self { self }
  var title: String { self == .catalog ? "Catalog" : "Lab" }
}

enum DeveloperMessagePlaygroundContent: String, CaseIterable, Identifiable {
  case shortText
  case multiline
  case emoji
  case link
  case rightToLeft
  case reply
  case forwarded
  case reactions
  case delivery

  var id: Self { self }

  var title: String {
    switch self {
    case .shortText: "Short text"
    case .multiline: "Multiline"
    case .emoji: "Emoji only"
    case .link: "Link"
    case .rightToLeft: "Right to left"
    case .reply: "Reply"
    case .forwarded: "Forwarded"
    case .reactions: "Reactions"
    case .delivery: "Delivery state"
    }
  }

  var detail: String {
    switch self {
    case .shortText: "Compact text and timestamp"
    case .multiline: "Wrapping at the selected canvas width"
    case .emoji: "Large emoji treatment without a normal bubble"
    case .link: "Production URL entity styling"
    case .rightToLeft: "RTL layout and Persian content"
    case .reply: "Embedded replied-to message"
    case .forwarded: "Forward header with a resolved sender"
    case .reactions: "Grouped reaction chips"
    case .delivery: "Outgoing sending, sent, and failed indicators"
    }
  }

  var text: String {
    switch self {
    case .shortText:
      "This is the real message renderer."
    case .multiline:
      "A longer message makes it easy to inspect wrapping, bubble width, line height, timestamp placement, and how the layout responds when the same content moves between narrow and wide canvases."
    case .emoji:
      "🎉✨"
    case .link:
      "Open https://inline.chat to see the production link treatment."
    case .rightToLeft:
      "این یک پیام نمونه برای بررسی چیدمان راست به چپ است."
    case .reply:
      "Looks good — I’ll take the final pass."
    case .forwarded:
      "Sharing this here so the whole team has the same context."
    case .reactions:
      "Should we ship this version today?"
    case .delivery:
      "Sending the updated build now."
    }
  }

  var entities: MessageEntities? {
    guard self == .link else { return nil }
    let url = "https://inline.chat"
    let range = (text as NSString).range(of: url)
    var entity = MessageEntity()
    entity.type = .url
    entity.offset = Int64(range.location)
    entity.length = Int64(range.length)
    var entities = MessageEntities()
    entities.entities = [entity]
    return entities
  }

  var fixtureIndex: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }
}

enum DeveloperMessagePlaygroundOwnership: String, CaseIterable, Identifiable {
  case incoming
  case outgoing

  var id: Self { self }
  var title: String { self == .incoming ? "Incoming" : "Outgoing" }
  var fixtureIndex: Int { self == .incoming ? 0 : 1 }
}

enum DeveloperMessagePlaygroundConversation: String, CaseIterable, Identifiable {
  case space
  case directMessage

  var id: Self { self }
  var title: String { self == .space ? "Space" : "DM" }
  var fixtureIndex: Int { self == .space ? 0 : 1 }
}

enum DeveloperMessagePlaygroundGroupPosition: String, CaseIterable, Identifiable {
  case isolated
  case start
  case middle
  case end

  var id: Self { self }

  var title: String {
    switch self {
    case .isolated: "Isolated"
    case .start: "Start"
    case .middle: "Middle"
    case .end: "End"
    }
  }

  var isFirst: Bool { self == .isolated || self == .start }
  var isLast: Bool { self == .isolated || self == .end }
  var fixtureIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum DeveloperMessagePlaygroundDelivery: String, CaseIterable, Identifiable {
  case sending
  case sent
  case failed

  var id: Self { self }

  var title: String {
    switch self {
    case .sending: "Sending"
    case .sent: "Sent"
    case .failed: "Failed"
    }
  }

  var status: MessageSendingStatus {
    switch self {
    case .sending: .sending
    case .sent: .sent
    case .failed: .failed
    }
  }
}

enum DeveloperMessagePlaygroundCanvasWidth: String, CaseIterable, Identifiable {
  case compact
  case regular
  case wide

  var id: Self { self }

  var title: String {
    switch self {
    case .compact: "360 pt"
    case .regular: "520 pt"
    case .wide: "720 pt"
    }
  }

  var points: CGFloat {
    switch self {
    case .compact: 360
    case .regular: 520
    case .wide: 720
    }
  }
}
#endif
