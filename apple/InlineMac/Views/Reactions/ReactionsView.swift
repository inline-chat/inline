import AppKit
import Auth
import InlineKit
import InlineUI
import RealtimeV2
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

    currentUserId = Auth.shared.getCurrentUserId()
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
    group.reactions.contains { fullReaction in
      fullReaction.reaction.userId == currentUserId
    }
  }

  @State private var tooltip: String? = nil

  private var usersToShow: [User] {
    let reactions = group.reactions.prefix(Self.maxAvatars)
    return reactions.compactMap { fullReaction in
      if let user = fullReaction.userInfo?.user {
        user
      } else {
        // FIXME: could be sync, need to check if it's needed
        ObjectCache.shared.getUser(id: fullReaction.reaction.userId)?.user
      }
    }
  }

  static let padding: CGFloat = ReactionChipMetrics.padding
  static let spacing: CGFloat = ReactionChipMetrics.spacing
  static let countSpacing: CGFloat = ReactionChipMetrics.countSpacing
  static let countTrailingPadding: CGFloat = ReactionChipMetrics.countTrailingPadding
  static let height: CGFloat = ReactionChipMetrics.height
  static let emojiFontSize: CGFloat = ReactionChipMetrics.emojiFontSize
  static let textFontSize: CGFloat = ReactionChipMetrics.textFontSize
  static let avatarSize: CGFloat = ReactionChipMetrics.avatarSize
  static let avatarOverlap: CGFloat = ReactionChipMetrics.avatarOverlap
  static let maxAvatars: Int = ReactionChipMetrics.maxAvatars

  private static func shouldShowAvatars(_ group: GroupedReaction) -> Bool {
    ReactionChipMetrics.showsAvatars(for: group.reactions.count)
  }

  var body: some View {
    item
      .help(tooltip ?? "")
      .onHover { _ in
        tooltip = group.reactions.compactMap { reaction in
          reaction.reaction.userId == currentUserId ? "You" : ObjectCache.shared
            .getUser(id: reaction.reaction.userId)?.user.displayName
        }.joined(separator: ", ")
      }
  }

  @ViewBuilder
  private var item: some View {
    let showAvatars = Self.shouldShowAvatars(group)

    HStack(spacing: showAvatars ? Self.spacing : Self.countSpacing) {
      Text(emoji)
        .font(.system(size: Self.emojiFontSize))

      if showAvatars {
        HStack(spacing: -Self.avatarOverlap) {
          ForEach(usersToShow, id: \.id) { user in
            UserAvatar(user: user, size: Self.avatarSize)
          }
        }
      } else {
        Text("\(group.reactions.count)")
          .font(.system(size: Self.textFontSize))
          .foregroundColor(foregroundColor)
      }
    }
    .padding(.leading, Self.padding)
    .padding(.trailing, showAvatars ? Self.padding : Self.countTrailingPadding)
    .frame(width: Self.size(group: group).width, height: Self.height)
    .background(backgroundColor)
    .cornerRadius(Self.height / 2)
    .ignoresSafeArea(.all)
    .onTapGesture {
      toggleReaction()
    }
    .animation(.smoothSnappy, value: group.reactions.count)
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
    ReactionChipMetrics.size(group: group)
  }

  private func toggleReaction() {
    guard let fullMessage
    else {
      return
    }

    if weReacted {
      // Remove reaction
      Task(priority: .userInitiated) { @MainActor in
        try await Api.realtime.send(.deleteReaction(
          emoji: emoji,
          message: fullMessage.message
        ))
      }
    } else {
      // Add reaction
      Task(priority: .userInitiated) { @MainActor in
        try await Api.realtime.send(.addReaction(
          emoji: emoji,
          message: fullMessage.message
        ))
      }
    }
  }
}
