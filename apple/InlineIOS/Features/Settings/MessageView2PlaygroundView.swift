#if DEBUG || DEBUG_BUILD
import InlineIOSUI
import InlineKit
import InlineProtocol
import InlineTheme
import SwiftUI
import UIKit

struct MessageView2PlaygroundView: View {
  private static let scenarios = MessageView2PlaygroundFixtures.scenarios

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        MessageView2PlaygroundHeader()

        ForEach(Self.scenarios) { scenario in
          MessageView2PlaygroundCard(scenario: scenario)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 16)
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .navigationTitle("Message View 2")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MessageView2PlaygroundHeader: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Production renderer catalog")
        .font(.headline)
      Text("Synthetic, render-only fixtures for checking common combinations without sending messages.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MessageView2PlaygroundCard: View {
  let scenario: MessageView2PlaygroundScenario

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      VStack(alignment: .leading, spacing: 2) {
        Text(scenario.title)
          .font(.subheadline.weight(.semibold))
        Text(scenario.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      MessageView2PlaygroundRepresentable(scenario: scenario)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
    }
  }
}

private struct MessageView2PlaygroundRepresentable: UIViewRepresentable {
  let scenario: MessageView2PlaygroundScenario

  func makeUIView(context _: Context) -> MessageView2PlaygroundHostView {
    let view = MessageView2PlaygroundHostView()
    view.configure(scenario)
    return view
  }

  func updateUIView(_ view: MessageView2PlaygroundHostView, context _: Context) {
    view.configure(scenario)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: MessageView2PlaygroundHostView,
    context _: Context
  ) -> CGSize? {
    let width = proposal.width ?? 343
    return uiView.measuredSize(width: width)
  }
}

private final class MessageView2PlaygroundHostView: UIView {
  private var scenario: MessageView2PlaygroundScenario?
  private var messageView: UIMessageView2?
  private var renderedWidth: CGFloat = 0
  private var renderedStyle: UIUserInterfaceStyle = .unspecified

  func configure(_ scenario: MessageView2PlaygroundScenario) {
    guard self.scenario?.id != scenario.id else { return }
    self.scenario = scenario
    rebuild(width: bounds.width)
    invalidateIntrinsicContentSize()
  }

  func measuredSize(width: CGFloat) -> CGSize {
    rebuild(width: width)
    let height = messageView?.sizeThatFits(
      CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    ).height ?? 1
    return CGSize(width: width, height: ceil(height))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rebuild(width: bounds.width)
    messageView?.frame = bounds
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else {
      return
    }
    rebuild(width: bounds.width, force: true)
    invalidateIntrinsicContentSize()
  }

  private func rebuild(width: CGFloat, force: Bool = false) {
    guard let scenario, width > 0 else { return }
    let style = traitCollection.userInterfaceStyle
    guard force || messageView == nil || abs(renderedWidth - width) > 0.5 || renderedStyle != style else {
      return
    }

    messageView?.removeFromSuperview()
    let variant: ThemeAppearanceVariant = style == .dark ? .dark : .light
    let nextView = UIMessageView2(
      fullMessage: scenario.message,
      spaceId: 9_001,
      displayMode: .normal,
      bubbleTailSide: scenario.outgoing ? .trailing : .leading,
      maximumBubbleContentWidth: width * MessageBubbleWidthPolicy.maximumWidthFraction,
      theme: ThemeManager.shared.snapshot(variant: variant)
    )
    nextView.isUserInteractionEnabled = scenario.allowsInteraction
    addSubview(nextView)
    messageView = nextView
    renderedWidth = width
    renderedStyle = style
  }
}

private struct MessageView2PlaygroundScenario: Identifiable {
  let id: Int64
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let message: FullMessage
  let outgoing: Bool
  let allowsInteraction: Bool
}

private enum MessageView2PlaygroundFixtures {
  private static let date = Date(timeIntervalSince1970: 1_787_816_400)
  private static let chatID: Int64 = 9_001
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
  private static let replyUser = User(
    id: 7_003,
    email: "sam@example.com",
    firstName: "Sam",
    lastName: "Rivera"
  )

  static let scenarios: [MessageView2PlaygroundScenario] = [
    .init(
      id: 10_001,
      title: "Compact text",
      detail: "Incoming and outgoing width, tail, text, and inline timestamp.",
      message: fixture(id: 10_001, text: "A compact incoming message."),
      outgoing: false,
      allowsInteraction: false
    ),
    .init(
      id: 10_002,
      title: "Multiline + reactions",
      detail: "Maximum width, footer placement, and grouped reaction geometry.",
      message: fixture(
        id: 10_002,
        text: "A longer outgoing message makes line wrapping, bubble width, footer placement, and reaction alignment easy to inspect on a phone.",
        outgoing: true,
        reactions: true
      ),
      outgoing: true,
      allowsInteraction: false
    ),
    .init(
      id: 10_003,
      title: "Reply + forward",
      detail: "Retained reply preview and forward header in one bubble.",
      message: fixture(
        id: 10_003,
        text: "This combines two structural rows with ordinary message text.",
        reply: true,
        forwarded: true
      ),
      outgoing: false,
      allowsInteraction: false
    ),
    .init(
      id: 10_004,
      title: "Reply thread + actions",
      detail: "First-frame thread summary placement and multi-row button styling.",
      message: fixture(
        id: 10_004,
        text: "Choose a workspace and continue.",
        replyThread: true,
        actions: true
      ),
      outgoing: false,
      allowsInteraction: false
    ),
    .init(
      id: 10_005,
      title: "Rich hierarchy + code",
      detail: "Phone heading scale, list indentation, selectable code, line numbers, and horizontal scrolling.",
      message: richFixture(id: 10_005, rich: richHierarchyAndCode()),
      outgoing: false,
      allowsInteraction: true
    ),
    .init(
      id: 10_006,
      title: "Compact table",
      detail: "Dense body sizing, header styling, row rules, and wrapping.",
      message: richFixture(id: 10_006, rich: richTable()),
      outgoing: false,
      allowsInteraction: true
    ),
    .init(
      id: 10_007,
      title: "Wide 10-column table",
      detail: "Horizontal scrolling stress case; drag sideways inside the table.",
      message: richFixture(id: 10_007, rich: richWideTable()),
      outgoing: false,
      allowsInteraction: true
    ),
  ]

  private static func fixture(
    id: Int64,
    text: String,
    outgoing: Bool = false,
    reply: Bool = false,
    forwarded: Bool = false,
    reactions: Bool = false,
    replyThread: Bool = false,
    actions: Bool = false,
    rich: RichFixture? = nil
  ) -> FullMessage {
    let sender = outgoing ? outgoingUser : incomingUser
    var contentPayload: Client_MessageContentPayload?
    if replyThread {
      contentPayload = .with {
        $0.replies = .with {
          $0.chatID = 12_001
          $0.replyCount = 3
          $0.hasUnread_p = true
          $0.recentReplierUserIds = [replyUser.id, incomingUser.id]
        }
      }
    }
    var message = Message(
      messageId: id,
      fromId: sender.id,
      date: date,
      text: rich?.text ?? text,
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID,
      out: outgoing,
      status: outgoing ? .sent : nil,
      repliedToMessageId: reply ? 8_001 : nil,
      forwardFromPeerUserId: forwarded ? replyUser.id : nil,
      forwardFromMessageId: forwarded ? 7_001 : nil,
      forwardFromUserId: forwarded ? incomingUser.id : nil,
      contentPayload: contentPayload,
      actions: actions ? messageActions() : nil,
      entities: rich?.entities
    )
    message.globalId = id
    if let blockContent = rich?.blockContent {
      message.blockContentPayload = BlockContentPayload(blockContent)
    }

    return FullMessage(
      senderInfo: UserInfo(user: sender),
      forwardFromPeerUserInfo: forwarded ? UserInfo(user: replyUser) : nil,
      message: message,
      reactions: reactions ? makeReactions(messageID: id) : [],
      repliedToMessage: reply ? makeRepliedToMessage() : nil,
      attachments: []
    )
  }

  private static func richFixture(id: Int64, rich: RichFixture) -> FullMessage {
    fixture(id: id, text: rich.text, rich: rich)
  }

  private static func makeRepliedToMessage() -> EmbeddedMessage {
    var message = Message(
      messageId: 8_001,
      fromId: replyUser.id,
      date: date.addingTimeInterval(-120),
      text: "The launch checklist is ready for review.",
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID
    )
    message.globalId = 8_001
    return EmbeddedMessage(message: message, senderInfo: UserInfo(user: replyUser))
  }

  private static func makeReactions(messageID: Int64) -> [FullReaction] {
    [
      FullReaction(
        reaction: Reaction(
          id: 1,
          messageId: messageID,
          userId: incomingUser.id,
          emoji: "✅",
          date: date,
          chatId: chatID
        ),
        userInfo: UserInfo(user: incomingUser)
      ),
      FullReaction(
        reaction: Reaction(
          id: 2,
          messageId: messageID,
          userId: replyUser.id,
          emoji: "❤️",
          date: date.addingTimeInterval(1),
          chatId: chatID
        ),
        userInfo: UserInfo(user: replyUser)
      ),
    ]
  }

  private static func messageActions() -> MessageActions {
    .with {
      $0.rows = [
        .with {
          $0.actions = [
            copyAction(id: "dev", title: "dev"),
            copyAction(id: "inline-public", title: "inline-public"),
          ]
        },
        .with {
          $0.actions = [copyAction(id: "cancel", title: "Cancel")]
        },
      ]
    }
  }

  private static func copyAction(id: String, title: String) -> MessageAction {
    .with {
      $0.actionID = id
      $0.text = title
      $0.copyText = .with { $0.text = title }
    }
  }

  private static func richHierarchyAndCode() -> RichFixture {
    var builder = RichTextBuilder()
    let heading = builder.segment("Compact markdown demo")
    let subheading = builder.segment("Text styles")
    let paragraph = builder.segment("A dense sample with common shapes and restrained hierarchy.")
    let firstItem = builder.segment("The bullet begins close to the content edge.")
    let secondItem = builder.segment("Nested content keeps a compact indentation.")
    let code = builder.segment(
      "const greeting = `hello ${name}`;\nfunction sayHello(name: string) {\n  return greeting;\n}\nconsole.log(sayHello(\"Mo\"));"
    )
    return builder.finish(blocks: [
      headingBlock(heading, level: 1),
      headingBlock(subheading, level: 2),
      paragraphBlock(paragraph),
      listBlock(items: [
        [paragraphBlock(firstItem)],
        [paragraphBlock(secondItem)],
      ]),
      codeBlock(code, language: "typescript"),
    ])
  }

  private static func richTable() -> RichFixture {
    var builder = RichTextBuilder()
    let heading = builder.segment("Release checks")
    let headerOne = builder.segment("Area")
    let headerTwo = builder.segment("Status")
    let rowOne = builder.segment("Message layout")
    let rowOneValue = builder.segment("Ready for device review")
    let rowTwo = builder.segment("Reaction animation")
    let rowTwoValue = builder.segment("Investigation in progress")
    return builder.finish(blocks: [
      headingBlock(heading, level: 2),
      tableBlock(rows: [
        [headerOne, headerTwo],
        [rowOne, rowOneValue],
        [rowTwo, rowTwoValue],
      ]),
    ])
  }

  private static func richWideTable() -> RichFixture {
    var builder = RichTextBuilder()
    let heading = builder.segment("Ten-column scroll check")
    let headers = (1 ... 10).map { builder.segment("Column \($0)") }
    let firstRow = (1 ... 10).map { builder.segment("Value \($0)") }
    let secondRow = (1 ... 10)
      .map { builder.segment($0 == 6 ? "A longer value that must remain readable" : "R2.\($0)") }
    return builder.finish(blocks: [
      headingBlock(heading, level: 2),
      tableBlock(rows: [headers, firstRow, secondRow]),
    ])
  }

  private static func paragraphBlock(_ text: BlockText) -> InlineProtocol.Block {
    .with { $0.paragraph = text }
  }

  private static func headingBlock(_ text: BlockText, level: UInt32) -> InlineProtocol.Block {
    .with {
      $0.heading = .with {
        $0.text = text
        $0.level = level
      }
    }
  }

  private static func codeBlock(_ text: BlockText, language: String) -> InlineProtocol.Block {
    .with {
      $0.code = .with {
        $0.text = text
        $0.language = language
      }
    }
  }

  private static func listBlock(items: [[InlineProtocol.Block]]) -> InlineProtocol.Block {
    .with {
      $0.list = .with {
        $0.kind = .unordered
        $0.items = items.map { children in
          .with { $0.children = children }
        }
      }
    }
  }

  private static func tableBlock(rows: [[BlockText]]) -> InlineProtocol.Block {
    .with {
      $0.table = .with {
        $0.rows = rows.map { cells in
          .with { $0.cells = cells }
        }
        $0.alignments = Array(repeating: .left, count: rows.first?.count ?? 0)
      }
    }
  }

  private struct RichFixture {
    let text: String
    let entities: MessageEntities?
    let blockContent: InlineProtocol.BlockContent
  }

  private struct RichTextBuilder {
    private(set) var text = ""

    mutating func segment(_ value: String) -> BlockText {
      if !text.isEmpty { text.append("\n") }
      let offset = (text as NSString).length
      text.append(value)
      return .with {
        $0.offset = Int64(offset)
        $0.length = Int64((value as NSString).length)
      }
    }

    func finish(blocks: [InlineProtocol.Block]) -> RichFixture {
      RichFixture(
        text: text,
        entities: nil,
        blockContent: .with { $0.blocks = blocks }
      )
    }
  }
}
#endif
