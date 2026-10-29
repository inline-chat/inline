import InlineKit
import InlineMessageLayout
import InlineTheme
import InlineUI
import SwiftUI
import UIKit

/// Content the next view stacks with the text: the forward header, a quoted reply, media, a
/// file or a voice note. The planner places it; the content views the current message view
/// already uses draw it, inside that frame.
struct MessageBlock {
  enum Kind: Hashable {
    case forward
    case reply
    case photo
    case video
    case document
    case voice
    /// A link preview under the text.
    case preview
    /// An external task card under the text.
    case task
    /// The reply thread's summary row, under the text.
    case threadSummary
    /// Bot buttons, under the bubble.
    case actions
  }

  let kind: Kind
  let input: MessageLayoutInput.Block
  /// The forward header's typeset text.
  var text: TextLayout?
  /// The preview or task this block shows.
  var attachment: FullAttachment?

  var id: String { input.id }
}

extension MessageBlock {
  /// Blocks for `message`, measured for its row. `maximumContentWidth` is the widest a block
  /// inside the bubble's padding can be.
  @MainActor
  static func blocks(
    for message: FullMessage,
    context: MessageRowContext,
    maximumContentWidth: CGFloat
  ) -> [MessageBlock] {
    let model = message.message
    let traits = context.traits
    let outgoing = model.out == true
    let hasCaption = model.text?.isEmpty == false
    var blocks: [MessageBlock] = []

    if message.showsForwardHeader {
      let color: UIColor = outgoing ? .white : context.theme.primary.uiColor
      let text = MessageText(NSAttributedString(
        string: message.forwardHeaderText,
        attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits), .foregroundColor: color]
      ).coreTextReady(for: traits))
      let layout = TextLayouter.layout(
        text,
        style: TextLayoutStyle(fallbackDirection: context.isRightToLeft ? .rightToLeft : .leftToRight),
        maximumWidth: maximumContentWidth,
        grid: PixelGrid(scale: context.displayScale)
      )
      blocks.append(MessageBlock(
        kind: .forward,
        input: .init(id: "forward", position: .aboveText, width: .fixed(layout.size.width), height: layout.size.height),
        text: layout
      ))
    }

    if model.repliedToMessageId != nil {
      blocks.append(MessageBlock(kind: .reply, input: .init(
        id: "reply",
        position: .aboveText,
        width: .flexible(
          preferred: EmbedMessageView.preferredReplyWidth(for: message.repliedToMessage, traits: traits),
          minimum: 120
        ),
        height: EmbedMessageView.height(compatibleWith: traits)
      )))
    }

    if let photo = message.photoInfo {
      let best = photo.bestPhotoSize()
      let size = NewPhotoView.displaySize(width: best?.width, height: best?.height, hasCaption: hasCaption)
      blocks.append(MessageBlock(kind: .photo, input: .init(
        id: "media", position: .aboveText, width: .fixed(size.width), height: size.height, isEdgeToEdge: true
      )))
    } else if let video = message.videoInfo {
      let size = NewVideoView.displaySize(width: video.video.width, height: video.video.height)
      blocks.append(MessageBlock(kind: .video, input: .init(
        id: "media", position: .aboveText, width: .fixed(size.width), height: size.height, isEdgeToEdge: true
      )))
    }

    if let document = message.documentInfo?.document {
      blocks.append(MessageBlock(kind: .document, input: .init(
        id: "document",
        position: .aboveText,
        width: .fixed(DocumentView.preferredWidth(fileName: document.fileName, size: document.size)),
        height: DocumentView.preferredHeight
      )))
    } else if model.hasVoice {
      blocks.append(MessageBlock(kind: .voice, input: .init(
        id: "voice",
        position: .aboveText,
        width: .flexible(
          preferred: VoiceMessageBubble.preferredBubbleWidth(duration: model.voiceContent?.duration ?? 0),
          minimum: 120
        ),
        height: VoiceMessageBubble.bubbleHeight
      )))
    }

    // Previews and task cards span the bubble's full width, measured once at that width.
    for (index, attachment) in message.attachments.enumerated() {
      let kind: Kind
      if attachment.externalTask != nil, attachment.userInfo != nil {
        kind = .task
      } else if attachment.urlPreview != nil {
        kind = .preview
      } else {
        continue
      }
      let height = MessageBlockMeasure.height(
        of: kind,
        attachment: attachment,
        width: maximumContentWidth,
        outgoing: outgoing,
        traits: traits
      )
      blocks.append(MessageBlock(
        kind: kind,
        input: .init(
          id: "attachment-\(index)",
          position: .belowText,
          width: .flexible(preferred: maximumContentWidth, minimum: 160),
          height: height
        ),
        attachment: attachment
      ))
    }
    if model.hasReplyThreadSummary, model.threadCard != nil, !context.isThreadAnchor {
      blocks.append(MessageBlock(kind: .threadSummary, input: .init(
        id: "thread",
        position: .belowText,
        width: .flexible(preferred: ReplyThreadSummaryView.minimumWidth, minimum: ReplyThreadSummaryView.minimumWidth),
        height: ReplyThreadSummaryView.preferredHeight(title: message.threadCardTitle)
      )))
    }

    let actionRows = MessageActionsView.rows(for: model)
    if !actionRows.isEmpty {
      blocks.append(MessageBlock(kind: .actions, input: .init(
        id: "actions",
        position: .belowBubble,
        width: .flexible(preferred: 0, minimum: 0),
        height: MessageActionsView.height(rowCount: actionRows.count, traits: traits)
      )))
    }
    return blocks
  }

  /// Attachments the next view can draw: link previews and task cards.
  static func supports(_ attachment: FullAttachment) -> Bool {
    attachment.urlPreview != nil || attachment.externalTask != nil && attachment.userInfo != nil
  }

  /// Read before the text, for VoiceOver.
  static func accessibilityDescription(of blocks: [MessageBlock], message: FullMessage) -> [String] {
    blocks.compactMap { block in
      switch block.kind {
      case .forward: message.forwardHeaderText
      case .reply: "Reply to \(message.repliedToMessage?.from?.shortDisplayName ?? "message")"
      case .photo: "Photo"
      case .video: "Video"
      case .document: message.documentInfo?.document.fileName ?? "File"
      case .voice: "Voice message"
      case .preview: block.attachment?.urlPreview?.title ?? "Link preview"
      case .task: block.attachment?.externalTask?.title ?? "Task"
      case .threadSummary: "Thread"
      case .actions: nil
      }
    }
  }
}

/// Holds one block's content view in the frame the planner chose. Content views that size
/// themselves (media) are pinned at their top-leading corner; the rest fill the frame.
final class MessageBlockHostView: UIView {
  let kind: MessageBlock.Kind
  private(set) var contentView: UIView?
  private var textView: MessageTextView?
  private var voiceController: UIHostingController<VoiceMessageBubble>?
  private var message: FullMessage?

  var onPhotoTap: ((FullMessage, UIView, UIImage?, URL) -> Void)?

  init(kind: MessageBlock.Kind) {
    self.kind = kind
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// `size` is the planned frame's size.
  func configure(_ block: MessageBlock, message: FullMessage, size: CGSize) {
    let previous = self.message
    self.message = message
    let outgoing = message.message.out == true
    switch kind {
    case .forward:
      let view = textView ?? makeForwardView()
      view.setLayout(block.text ?? .empty)
      view.textFrame = bounds

    case .reply:
      let embed = contentView as? EmbedMessageView ?? install(EmbedMessageView(), fills: true) {
        $0.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleReplyTap)))
      }
      if let replied = message.repliedToMessage {
        embed.configure(
          embeddedMessage: replied,
          kind: .replyInMessage,
          outgoing: outgoing,
          isOnlyEmoji: false,
          thumbnailReloadMessage: message.message
        )
      } else {
        embed.showNotLoaded(kind: .replyInMessage, outgoing: outgoing, isOnlyEmoji: false)
        if previous?.message.repliedToMessageId != message.message.repliedToMessageId {
          MessageViewActions.fetchRepliedMessageIfNeeded(for: message.message)
        }
      }

    case .photo:
      let photo = contentView as? NewPhotoView ?? install(NewPhotoView(message), fills: false)
      photo.plannedSize = size
      photo.update(with: message)
      photo.onTap = { [weak self] message, sourceView, image, url in
        self?.onPhotoTap?(message, sourceView, image, url)
      }

    case .video:
      let video = contentView as? NewVideoView ?? install(NewVideoView(message), fills: false)
      video.plannedSize = size
      video.update(with: message)

    case .document:
      if let document = contentView as? DocumentView {
        document.update(with: message, outgoing: outgoing)
      } else {
        install(DocumentView(fullMessage: message, outgoing: outgoing), fills: true)
      }

    case .preview:
      guard let attachment = block.attachment, let preview = attachment.urlPreview else { break }
      let view = contentView as? URLPreviewView ?? install(URLPreviewView(), fills: true)
      let model = message.message
      view.configure(
        with: preview,
        photoInfo: attachment.photoInfo,
        authorPhotoInfo: attachment.authorPhotoInfo,
        parentViewController: nil,
        outgoing: outgoing,
        mode: URLPreviewView.preferredMode(for: preview, photoInfo: attachment.photoInfo),
        reloadMessageOnFinish: model,
        canRemove: outgoing && attachment.attachment.attachmentId != nil,
        onRemove: { MessageViewActions.removeURLPreview(attachment, from: model) },
        neverShowPreviewActionProvider: { MessageViewActions.neverShowPreviewAction(for: attachment, in: model) }
      )

    case .task:
      guard let attachment = block.attachment, let task = attachment.externalTask, let user = attachment.userInfo else { break }
      let view = contentView as? MessageAttachmentEmbed ?? install(MessageAttachmentEmbed(), fills: true)
      view.configure(
        userInfo: user,
        outgoing: outgoing,
        url: URL(string: task.url ?? ""),
        issueIdentifier: nil,
        title: task.title,
        externalTask: task,
        messageId: message.message.messageId,
        chatId: message.message.chatId
      )

    case .threadSummary:
      guard let summary = message.message.threadCard else { break }
      let view = contentView as? ReplyThreadSummaryView ?? install(ReplyThreadSummaryView(), fills: true)
      let model = message.message
      view.configure(
        kind: summary.kind,
        messageCount: summary.messageCount,
        recentAuthors: Self.recentRepliers(of: model),
        hasUnread: summary.hasUnread,
        outgoing: outgoing,
        title: message.threadCardTitle
      )
      view.onTap = { [weak view] in
        ReplyThreadNavigator.open(message: model, source: .summary) { loading in
          view?.setLoading(loading)
        }
      }
      view.contextMenuProvider = { [weak view] in
        MessageViewActions.threadSummaryMenu(for: model) {
          var responder: UIResponder? = view
          while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
          }
          return nil
        }
      }

    case .actions:
      let view = contentView as? MessageActionsView ?? install(MessageActionsView(), fills: true)
      view.configure(message: message.message)

    case .voice:
      let root = VoiceMessageBubble(message: message.message, outgoing: outgoing)
      if let voiceController {
        voiceController.rootView = root
      } else {
        let controller = UIHostingController(rootView: root)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        voiceController = controller
        install(controller.view, fills: true)
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    textView?.textFrame = bounds
  }

  /// Adds `view` pinned to this host. A filling view gives up its own size preferences so the
  /// planned frame always wins; a self-sizing one keeps its size from its top-leading corner.
  @discardableResult
  private func install<View: UIView>(_ view: View, fills: Bool, setup: (View) -> Void = { _ in }) -> View {
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    var constraints = [
      view.topAnchor.constraint(equalTo: topAnchor),
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
    ]
    if fills {
      for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
        view.setContentHuggingPriority(.defaultLow, for: axis)
        view.setContentCompressionResistancePriority(.defaultLow, for: axis)
      }
      constraints += [
        view.trailingAnchor.constraint(equalTo: trailingAnchor),
        view.bottomAnchor.constraint(equalTo: bottomAnchor),
      ]
    }
    NSLayoutConstraint.activate(constraints)
    setup(view)
    contentView = view
    return view
  }

  private func makeForwardView() -> MessageTextView {
    let view = MessageTextView()
    view.isUserInteractionEnabled = true
    view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleForwardTap)))
    addSubview(view)
    textView = view
    contentView = view
    return view
  }

  private static func recentRepliers(of message: Message) -> [UserInfo] {
    let userIds = message.replyThreadRecentReplierUserIds
    let users = ObjectCache.shared.get(userIds.map(ObjectID.user))
    return userIds.map { users.user($0) ?? UserInfo(user: User(id: $0, email: nil, firstName: nil)) }
  }

  @objc private func handleReplyTap() {
    guard let message else { return }
    MessageViewActions.openRepliedMessage(of: message.message)
  }

  @objc private func handleForwardTap() {
    guard let message else { return }
    MessageViewActions.openForwardSource(of: message)
  }
}

/// Measures previews and task cards, which size their text to the width they get, once per
/// content and width.
@MainActor
enum MessageBlockMeasure {
  private static var heights: [Int: CGFloat] = [:]

  static func height(
    of kind: MessageBlock.Kind,
    attachment: FullAttachment,
    width: CGFloat,
    outgoing: Bool,
    traits: UITraitCollection
  ) -> CGFloat {
    var hasher = Hasher()
    hasher.combine(kind)
    hasher.combine(attachment)
    hasher.combine(width)
    hasher.combine(outgoing)
    hasher.combine(traits.preferredContentSizeCategory)
    let key = hasher.finalize()
    if let height = heights[key] { return height }

    let view: UIView
    switch kind {
    case .preview:
      guard let model = attachment.urlPreview else { return 0 }
      // A fresh view per measurement: a reconfigured one can report a collapsed height.
      let preview = URLPreviewView()
      preview.configure(
        with: model,
        photoInfo: attachment.photoInfo,
        authorPhotoInfo: attachment.authorPhotoInfo,
        parentViewController: nil,
        outgoing: outgoing,
        mode: URLPreviewView.preferredMode(for: model, photoInfo: attachment.photoInfo)
      )
      view = preview
    case .task:
      guard let model = attachment.externalTask, let user = attachment.userInfo else { return 0 }
      let task = MessageAttachmentEmbed()
      task.configure(userInfo: user, outgoing: outgoing, url: URL(string: model.url ?? ""), title: model.title, externalTask: model)
      view = task
    default:
      return 0
    }
    view.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
    let size = view.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let height = ceil(size.height)
    if heights.count > 512 { heights.removeAll() }
    heights[key] = height
    return height
  }
}
