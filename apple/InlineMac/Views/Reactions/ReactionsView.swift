import Auth
import InlineKit
import SwiftUI

// MARK: - View Model

class ReactionsViewModel: ObservableObject {
  @Published public var reactions: [GroupedReaction] = []
  @Published public var offsets: [String: MessageSizeCalculator.LayoutPlan] = [:]
  @Published public var width: CGFloat
  @Published public var height: CGFloat

  @Published public var fullMessage: FullMessage?
  var currentUserId: Int64?

  public init(
    reactions: [GroupedReaction],
    offsets: [String: MessageSizeCalculator.LayoutPlan],
    fullMessage: FullMessage?,
    width: CGFloat,
    height: CGFloat
  ) {
    self.reactions = reactions
    self.offsets = offsets
    self.fullMessage = fullMessage
    self.width = width
    self.height = height

    currentUserId = Auth.shared.currentUserId
  }
}

struct ReactionsView: View {
  // MARK: - Props

  @ObservedObject var viewModel: ReactionsViewModel

  init(viewModel: ReactionsViewModel) {
    self.viewModel = viewModel
  }

  // MARK: - State

  @Environment(\.colorScheme) var colorScheme
  @State private var showReactions = false

  // MARK: - Computed

  var width: CGFloat {
    viewModel.width
  }

  var height: CGFloat {
    viewModel.height
  }

  // MARK: - Views

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(viewModel.reactions, id: \.self) { group in

        ReactionItem(group: group, fullMessage: viewModel.fullMessage, currentUserId: viewModel.currentUserId)
          .transition(.scale(scale: 0).combined(with: .opacity))
          .offset(
            x: viewModel.offsets[group.emoji]?.spacing.left ?? 0,
            y: viewModel.offsets[group.emoji]?.spacing.top ?? 0
          )
      }
      Color.clear.frame(width: width, height: height, alignment: .topLeading)
    }
    .frame(width: viewModel.width, height: viewModel.height, alignment: .topLeading)
    .fixedSize(horizontal: true, vertical: true)
    .ignoresSafeArea(.all)
    .animation(.smoothSnappy, value: viewModel.reactions)
    .animation(.smoothSnappy, value: viewModel.offsets)
    .animation(.smoothSnappy, value: viewModel.width)
    .animation(.smoothSnappy, value: viewModel.height)
    // debug
    // .background(Color.white.opacity(0.8).cornerRadius(6))
    // .fixedSize(horizontal: true, vertical: true)
//    .onAppear {
//      // TODO: Animate
//    }
  }
}

// MARK: - Reaction Item

struct ReactionItem: View {
  var group: GroupedReaction
  var fullMessage: FullMessage?
  var currentUserId: Int64?

  @Environment(\.colorScheme) var colorScheme

  var emoji: String {
    group.emoji
  }

  var weReacted: Bool {
    // TODO: move to group
    group.reactions.contains { reaction in
      reaction.userId == currentUserId
    }
  }

  static let padding: CGFloat = 8
  static let spacing: CGFloat = 4
  static let height: CGFloat = 28
  static let emojiFontSize: CGFloat = 14
  static let textFontSize: CGFloat = 12

  var body: some View {
    HStack(spacing: Self.spacing) {
      Text(emoji)
        .font(.system(size: Self.emojiFontSize))

      Text("\(group.reactions.count)")
        .font(.system(size: Self.textFontSize))
        .foregroundColor(foregroundColor)
    }
    .padding(.horizontal, Self.padding)
    .frame(height: Self.height)
    .background(backgroundColor)
    .cornerRadius(Self.height / 2)
    .ignoresSafeArea(.all)
    .onTapGesture {
      toggleReaction()
    }
  }

  var backgroundColor: Color {
    let isOutgoing = fullMessage?.message.out ?? false
    let baseColor = if colorScheme == .dark {
      isOutgoing ? Color.white : Color.white
    } else {
      isOutgoing ? Color.white : Color.accent
    }

    if weReacted {
      return baseColor.opacity(0.9)
    } else {
      return baseColor.opacity(0.2)
    }
  }

  var foregroundColor: Color {
    let isOutgoing = fullMessage?.message.out ?? false
    let baseColor = if colorScheme == .dark {
      // isOutgoing ? Color.white :
      weReacted ? Color.accent : Color.white
    } else {
      isOutgoing ? (weReacted ? Color.accent : Color.white) : (weReacted ? Color.white : Color.accent)
    }

    return baseColor
  }

  public static func size(group: GroupedReaction) -> CGSize {
    let textWidth = group.emoji.size(withAttributes: [.font: NSFont.systemFont(ofSize: emojiFontSize)]).width
    let countWidth = "\(group.reactions.count)".size(withAttributes: [.font: NSFont.systemFont(ofSize: textFontSize)])
      .width

    return CGSize(
      width: ceil(textWidth + countWidth + spacing + padding * 2),
      height: Self.height
    )
  }

  private func toggleReaction() {
    guard let fullMessage,
          let currentUserId
    else {
      return
    }

    if weReacted {
      // Remove reaction
      Transactions.shared.mutate(transaction: .deleteReaction(.init(
        message: fullMessage.message,
        emoji: emoji,
        peerId: fullMessage.message.peerId,
        chatId: fullMessage.message.chatId
      )))
    } else {
      // Add reaction
      Transactions.shared.mutate(transaction: .addReaction(.init(
        message: fullMessage.message,
        emoji: emoji,
        userId: currentUserId,
        peerId: fullMessage.message.peerId
      )))
    }
  }
}
