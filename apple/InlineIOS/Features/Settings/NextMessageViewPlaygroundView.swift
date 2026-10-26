#if DEBUG || DEBUG_BUILD
import Auth
import InlineKit
import InlineMessageLayout
import struct InlineProtocol.MessageEntities
import struct InlineProtocol.MessageEntity
import SwiftUI
import UIKit

/// Real next-view messages in a small manual list, with scripted updates. Rows below a changed
/// message move in the same animation, the way the chat list will.
struct NextMessageViewPlaygroundView: View {
  var body: some View {
    NextMessageViewPlaygroundRepresentable()
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle("Next Message View")
      .navigationBarTitleDisplayMode(.inline)
  }
}

private struct NextMessageViewPlaygroundRepresentable: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> NextMessageViewPlaygroundController {
    NextMessageViewPlaygroundController()
  }

  func updateUIViewController(_ controller: NextMessageViewPlaygroundController, context: Context) {}
}

final class NextMessageViewPlaygroundController: UIViewController {
  private struct Row {
    var message: FullMessage
    var isFirstInGroup = true
    var isLastInGroup = true
    var showsName = false
    var avatar: MessageLayoutInput.Avatar = .none
    var footer: MessageLayoutInput.Footer.Visibility = .visible
    let view = MessageView()
  }

  private enum Slot {
    static let reaction = 0
    static let edit = 1
    static let stream = 2
  }

  private let scrollView = UIScrollView()
  private let toolbar = UIToolbar()
  private var rows: [Row] = []
  private let cache = TextLayoutCache()
  private var laidOutWidth: CGFloat = 0
  private var streamTimer: Timer?
  private var streamedWords = 0
  private var isSlow = false
  private lazy var slowItem = UIBarButtonItem(title: "Slow", style: .plain, target: self, action: #selector(toggleSlow))

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)
    view.addSubview(toolbar)
    toolbar.items = [
      UIBarButtonItem(title: "Reaction", style: .plain, target: self, action: #selector(toggleReaction)),
      .flexibleSpace(),
      UIBarButtonItem(title: "Edit", style: .plain, target: self, action: #selector(toggleEdit)),
      .flexibleSpace(),
      UIBarButtonItem(title: "Stream", style: .plain, target: self, action: #selector(startStream)),
      .flexibleSpace(),
      UIBarButtonItem(title: "Status", style: .plain, target: self, action: #selector(cycleStatus)),
      .flexibleSpace(),
      slowItem,
    ]
    rows = Self.catalog()
    for row in rows {
      scrollView.addSubview(row.view)
    }
    registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
      (controller: NextMessageViewPlaygroundController, _: UITraitCollection) in
      controller.layoutRows(motion: .immediate)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let toolbarHeight = toolbar.sizeThatFits(view.bounds.size).height + view.safeAreaInsets.bottom
    toolbar.frame = CGRect(x: 0, y: view.bounds.height - toolbarHeight, width: view.bounds.width, height: toolbarHeight)
    scrollView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - toolbarHeight)
    if scrollView.bounds.width != laidOutWidth {
      laidOutWidth = scrollView.bounds.width
      layoutRows(motion: .immediate)
    }
  }


  /// Plans every row, applies them, and moves the rows in the same motion as their contents.
  private func layoutRows(motion: MessageMotion) {
    let width = scrollView.bounds.width
    guard width > 0 else { return }
    let theme = ThemeManager.shared.snapshot(variant: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    var frames: [CGRect] = []
    var y: CGFloat = 16
    for row in rows {
      let context = MessageRowContext(
        rowWidth: width,
        isFirstInGroup: row.isFirstInGroup,
        isLastInGroup: row.isLastInGroup,
        showsName: row.showsName,
        avatar: row.avatar,
        theme: theme,
        traits: traitCollection
      )
      guard let content = MessageViewContent.make(row.message, context: context, footer: row.footer) else {
        frames.append(CGRect(x: 0, y: y, width: width, height: 0))
        continue
      }
      let layout = MessageLayoutPlanner.layout(content.input, cache: cache)
      row.view.apply(content, layout: layout, motion: motion)
      frames.append(CGRect(x: 0, y: y, width: width, height: layout.size.height))
      y += layout.size.height
    }
    let contentHeight = y + 16
    motion.resolved(reduceMotion: UIAccessibility.isReduceMotionEnabled).animate { [self] in
      for (row, frame) in zip(rows, frames) {
        row.view.frame = frame
      }
      scrollView.contentSize = CGSize(width: width, height: contentHeight)
    }
  }

  // MARK: - Scripts

  @objc private func toggleReaction() {
    var message = rows[Slot.reaction].message
    let me = Auth.shared.getCurrentUserId() ?? Self.me.id
    if message.reactions.isEmpty {
      message.reactions = [Self.reaction("👍", by: me, on: message, info: nil)]
    } else {
      message.reactions = []
    }
    rows[Slot.reaction].message = message
    layoutRows(motion: .standard)
  }

  @objc private func toggleEdit() {
    var message = rows[Slot.edit].message
    message.message.text = message.message.text == Self.shortEdit ? Self.longEdit : Self.shortEdit
    rows[Slot.edit].message = message
    layoutRows(motion: .standard)
  }

  @objc private func startStream() {
    streamTimer?.invalidate()
    streamedWords = 1
    rows[Slot.stream].footer = .reserved
    applyStream()
    streamTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advanceStream() }
    }
  }

  private func advanceStream() {
    let total = Self.streamWords.count
    streamedWords += 1
    if streamedWords >= total {
      streamTimer?.invalidate()
      streamTimer = nil
      streamedWords = total
      rows[Slot.stream].footer = .visible
    }
    applyStream()
  }

  private func applyStream() {
    rows[Slot.stream].message.message.text = Self.streamWords.prefix(streamedWords).joined(separator: " ")
    layoutRows(motion: .streamingLine)
  }

  @objc private func cycleStatus() {
    var message = rows[Slot.edit].message
    message.message.status = switch message.message.status {
    case .sent: .sending
    case .sending: .failed
    default: .sent
    }
    rows[Slot.edit].message = message
    layoutRows(motion: .standard)
  }

  @objc private func toggleSlow() {
    isSlow.toggle()
    scrollView.layer.speed = isSlow ? 0.2 : 1
    slowItem.title = isSlow ? "Normal" : "Slow"
  }

  // MARK: - Catalog

  private static let date = Date(timeIntervalSince1970: 1_787_816_400)
  private static let chatID: Int64 = 9_101
  private static let ava = User(id: 7_101, email: "ava@example.com", firstName: "Ava", lastName: "Lin")
  private static let sam = User(id: 7_102, email: "sam@example.com", firstName: "Sam", lastName: "Rivera")
  private static let me = User(id: 7_103, email: "mo@example.com", firstName: "Mo")
  private static let shortEdit = "On my way"
  private static let longEdit = "On my way, but the train is running a little late. I'll message again when I'm close, probably twenty minutes."
  private static let streamWords = (
    "Here is a streamed answer. It arrives a few words at a time, the way an agent writes, "
      + "and the bubble grows one line at a time while the time stays hidden until the end."
  ).split(separator: " ").map(String.init)

  private static func catalog() -> [Row] {
    var rows = [
      Row(message: message(1, "Sounds good, see you tomorrow", from: ava)),
      Row(message: message(2, shortEdit, from: me, out: true)),
      Row(message: message(3, "Tap Stream to watch this message grow.", from: sam)),
      Row(message: message(4, "Thread messages show the sender above the first bubble.", from: ava),
          isLastInGroup: false, showsName: true, avatar: .reserved),
      Row(message: message(5, "The bubble below lines up with this one.", from: ava),
          isFirstInGroup: false, avatar: .visible),
      Row(message: message(6, "سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود، حتی وقتی چند خط می\u{200C}شود.", from: sam)),
      Row(message: message(7, "😀", from: me, out: true)),
      Row(message: styled(8)),
      Row(message: message(9, "This one failed to send.", from: me, out: true, status: .failed)),
    ]
    var party = message(10, "Many reactions wrap onto more rows inside the bubble.", from: me, out: true)
    party.reactions = ["🎉", "❤️", "😂", "👀", "🔥", "✅"].enumerated().map { index, emoji in
      reaction(emoji, by: index.isMultiple(of: 2) ? ava.id : sam.id, on: party, info: UserInfo(user: index.isMultiple(of: 2) ? ava : sam))
    }
    rows.append(Row(message: party))
    rows[6].message.reactions = [reaction("❤️", by: ava.id, on: rows[6].message, info: UserInfo(user: ava))]
    return rows
  }

  private static func message(
    _ id: Int64,
    _ text: String,
    from user: User,
    out: Bool = false,
    status: MessageSendingStatus = .sent,
    entities: MessageEntities? = nil
  ) -> FullMessage {
    var message = Message(
      messageId: id,
      fromId: user.id,
      date: date.addingTimeInterval(Double(id) * 60),
      text: text,
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID,
      out: out,
      status: out ? status : nil,
      entities: entities
    )
    message.globalId = 910_000 + id
    return FullMessage(
      senderInfo: UserInfo(user: user),
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  private static func styled(_ id: Int64) -> FullMessage {
    let text = "Bold, italic, underline, struck, highlighted, code and a link."
    func entity(_ word: String, _ type: MessageEntity.TypeEnum) -> MessageEntity {
      let range = (text as NSString).range(of: word)
      return .with {
        $0.type = type
        $0.offset = Int64(range.location)
        $0.length = Int64(range.length)
        if type == .textURL { $0.textURL.url = "https://inline.chat" }
      }
    }
    let entities = MessageEntities.with {
      $0.entities = [
        entity("Bold", .bold), entity("italic", .italic), entity("underline", .underline),
        entity("struck", .strikethrough), entity("highlighted", .highlight), entity("code", .code),
        entity("link", .textURL),
      ]
    }
    return message(id, text, from: sam, entities: entities)
  }

  private static func reaction(_ emoji: String, by userId: Int64, on message: FullMessage, info: UserInfo?) -> FullReaction {
    FullReaction(
      reaction: Reaction(
        messageId: message.message.messageId,
        userId: userId,
        emoji: emoji,
        date: date,
        chatId: chatID
      ),
      userInfo: info
    )
  }
}
#endif
