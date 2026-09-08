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
    nextView.onGeometryChange = { [weak self, weak nextView] _, layout in
      guard let self, let nextView else { return }
      let generation = nextView.geometryTransitionGeneration
      nextView.applyGeometryTransition(to: layout, generation: generation)
      nextView.finishGeometryTransition(generation: generation)
      self.invalidateIntrinsicContentSize()
      self.setNeedsLayout()
    }
    nextView.isUserInteractionEnabled = scenario.allowsInteraction
    addSubview(nextView)
    messageView = nextView
    renderedWidth = width
    renderedStyle = style
  }
}

struct MessageView2PlaygroundScenario: Identifiable {
  let id: Int64
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let message: FullMessage
  let outgoing: Bool
  let allowsInteraction: Bool
}

enum MessageView2PlaygroundFixtures {
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
    .init(
      id: 10_008,
      title: "Native display math",
      detail: "Fractions, matrices, horizontal overflow, and unsupported-source fallback. Copy LaTeX is available to accessibility.",
      message: richFixture(id: 10_008, rich: richMath()),
      outgoing: false,
      allowsInteraction: true
    ),
    .init(
      id: 10_009,
      title: "Disclosures + activity icons",
      detail: "Expand each activity; the first title shows progress and respects Reduce Motion.",
      message: richFixture(id: 10_009, rich: richDisclosures()),
      outgoing: false,
      allowsInteraction: true
    ),
    .init(
      id: 10_010,
      title: "Quotes + checklists",
      detail: "Compact nested decorations, checked states, and a separator within the measured bubble.",
      message: richFixture(id: 10_010, rich: richQuotesAndChecklist(rtl: false)),
      outgoing: false,
      allowsInteraction: true
    ),
    .init(
      id: 10_011,
      title: "RTL hierarchy",
      detail: "Persian paragraphs, nested quotes, and trailing checklist markers.",
      message: richFixture(id: 10_011, rich: richQuotesAndChecklist(rtl: true)),
      outgoing: false,
      allowsInteraction: true
    ),
    .init(
      id: 10_012,
      title: "Image placeholders + album",
      detail: "Pending and unavailable media keep their dimensions. The album scrolls horizontally without network requests.",
      message: richFixture(id: 10_012, rich: richImagePlaceholders()),
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

  private static func richDisclosures() -> RichFixture {
    var builder = RichTextBuilder()
    let activities: [(BlockDisclosure.ActivityKind, String)] = [
      (.reasoning, "Thinking through the next step"),
      (.explore, "Exploring the workspace"),
      (.read, "Reading files"),
      (.search, "Searching the source"),
      (.edit, "Editing a file"),
      (.delete, "Removing obsolete content"),
      (.move, "Moving a file"),
      (.command, "Running a command"),
      (.web, "Reading a web page"),
      (.tool, "Using a tool"),
    ]
    let blocks = activities.enumerated().map { index, activity in
      let summary = builder.segment(activity.1)
      let detail = builder.segment("Expanded detail for this activity. Toggle the row to inspect its title and content layout.")
      return InlineProtocol.Block.with {
        $0.disclosure.summary = summary
        $0.disclosure.activityKind = activity.0
        if index == 0 { $0.disclosure.kind = .progress }
        $0.disclosure.children = [paragraphBlock(detail)]
      }
    }
    return builder.finish(blocks: blocks)
  }

  private static func richQuotesAndChecklist(rtl: Bool) -> RichFixture {
    var builder = RichTextBuilder()
    var paragraph = builder.segment(rtl ? "سلام دنیا" : "A compact message")
    paragraph.isRtl = rtl
    let quote = builder.segment(rtl ? "یک نقل قول کوتاه" : "A short quote")
    let nested = builder.segment(rtl ? "نقل قول تو در تو" : "Nested quote")
    let unchecked = builder.segment(rtl ? "بررسی چیدمان" : "Review layout")
    let checked = builder.segment(rtl ? "حفظ متن اصلی" : "Preserve source text")
    return builder.finish(blocks: [
      paragraphBlock(paragraph),
      .with {
        $0.quote.isRtl = rtl
        $0.quote.children = [
          paragraphBlock(quote),
          .with { $0.quote.children = [paragraphBlock(nested)] },
        ]
      },
      .with { $0.separator = .init() },
      .with {
        $0.list.kind = .unordered
        $0.list.isRtl = rtl
        $0.list.items = [
          .with { $0.checked = false; $0.children = [paragraphBlock(unchecked)] },
          .with { $0.checked = true; $0.children = [paragraphBlock(checked)] },
        ]
      },
    ])
  }

  private static func richImagePlaceholders() -> RichFixture {
    var builder = RichTextBuilder()
    let imageAlt = builder.segment("Pending image")
    let albumAlts = (1 ... 5).map { builder.segment("Album image \($0)") }
    return builder.finish(blocks: [
      .with {
        $0.image.alt = imageAlt
        $0.image.pending.dimensions = .with { $0.width = 320; $0.height = 180 }
      },
      .with {
        $0.album.images = albumAlts.enumerated().map { index, alt in
          .with {
            $0.alt = alt
            let dimensions = BlockImageDimensions.with {
              $0.width = index.isMultiple(of: 2) ? 240 : 120
              $0.height = 180
            }
            if index.isMultiple(of: 2) { $0.pending.dimensions = dimensions }
            else { $0.unavailable.dimensions = dimensions }
          }
        }
      },
    ])
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

  private static func richMath() -> RichFixture {
    var builder = RichTextBuilder()
    let heading = builder.segment("Native math: source is preserved")
    let formulas = [
      #"\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#,
      #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#,
      (1...12).map { "\\frac{a_{\($0)}}{b_{\($0)}}" }.joined(separator: "+"),
      #"\notAnInlineMathCommand{x}"#,
    ]
    let inlineFormula = #"\frac{x_1}{y}+\sqrt{z}"#
    let inlineText = "Before " + inlineFormula + " after 😀."
    let inlineSpan = builder.segment(inlineText)
    let local = (inlineText as NSString).range(of: inlineFormula)
    let inlineRange = BlockText.with { $0.offset = inlineSpan.offset + Int64(local.location); $0.length = Int64(local.length) }
    let tableHeader = builder.segment("Formula in a table cell")
    let tableFormula = builder.segment(#"e^{i\pi}+1=0"#)
    let ranges = formulas.map { builder.segment($0) }
    let base = builder.finish(blocks: [
      .with { $0.paragraph = heading },
      .with { $0.paragraph = inlineSpan },
      .with { $0.table = .with {
        $0.rows = [.with { $0.cells = [tableHeader] }, .with { $0.cells = [tableFormula] }]
        $0.alignments = [.left]
      } },
    ] + ranges.map { range in
      .with { $0.math = range }
    })
    return RichFixture(text: base.text, entities: .with {
      $0.entities = ([inlineRange, tableFormula] + ranges).map { range in
        .with { $0.type = .math; $0.offset = range.offset; $0.length = range.length }
      }
    }, blockContent: base.blockContent)
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
