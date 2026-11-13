import Auth
import InlineKit
import InlineUI
import SwiftUI

/// The first screen of a bot's chat info: how it is doing, who can use it,
/// how it replies here, and for its owner, the way into its settings.
/// Everything renders from local caches first; loads only refresh it.
struct BotChatInfoOverview: View {
  let bot: UserInfo
  @Binding var notificationSelection: DialogNotificationSettingSelection

  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var settingsModel = IOSBotsSettingsModel()
  /// Bumped when people this screen names finish loading, to re-read the cache.
  @State private var loadedUsersGeneration = 0

  private var botUserID: Int64 { bot.user.id }
  private var owned: OwnedAgentGrants? { grants.ownedGrants(botUserID: botUserID) }
  private var isOwner: Bool { owned != nil }
  private var runtime: AgentRuntimeInfo? { store.runtimeInfo(botUserID: botUserID) }
  private var status: BotStatusSummary? { BotStatusSummary.make(user: bot.user, runtime: runtime) }

  var body: some View {
    VStack(spacing: 22) {
      statusSection
      accessSection
      chatSection
      manageSection
    }
    .padding(.horizontal, 16)
    .animation(.easeInOut(duration: 0.2), value: isOwner)
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
      BotOnlineStatus.refreshIfBot(bot.user)
      await store.loadDirectChatOutputModes(botUserID: botUserID)
    }
    .task(id: peopleToLoad) {
      let missing = peopleToLoad.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
  }

  // MARK: Status

  @ViewBuilder
  private var statusSection: some View {
    if status != nil || runtime?.machineLabel != nil || runtime?.runtimeTitle != nil {
      BotInfoSection("Status") {
        if let status {
          BotInfoRow(systemImage: "dot.radiowaves.left.and.right", tint: status.tone.tint, title: "Status") {
            HStack(spacing: 6) {
              Circle()
                .fill(status.tone.tint)
                .frame(width: 8, height: 8)
              Text(status.title)
            }
            .foregroundStyle(.secondary)
          } detail: {
            if let detail = status.detail {
              Text(detail)
                .foregroundStyle(status.tone == .attention ? Color.orange : Color.secondary)
            }
          }
        }
        if let machine = runtime?.machineLabel {
          BotInfoDivider()
          BotInfoValueRow(systemImage: "desktopcomputer", tint: .indigo, title: "Machine", value: machine)
        }
        if let runtimeTitle = runtime?.runtimeTitle {
          BotInfoDivider()
          BotInfoValueRow(systemImage: "terminal.fill", tint: .gray, title: "Runtime", value: runtimeTitle)
        }
        if let bridgeVersion = runtime?.bridgeVersion {
          BotInfoDivider()
          BotInfoValueRow(systemImage: "shippingbox.fill", tint: .brown, title: "Inline CLI", value: bridgeVersion)
        }
      }
    }
  }

  // MARK: Access

  @ViewBuilder
  private var accessSection: some View {
    if let owned {
      BotInfoSection(
        "Access",
        footer: "People with access can start and steer \(bot.user.shortDisplayName) in chats they share with it. You always have access."
      ) {
        NavigationLink {
          BotAccessView(bot: bot)
        } label: {
          BotInfoRow(systemImage: "person.2.fill", tint: .blue, title: "Shared With", showsChevron: true) {
            HStack(spacing: 8) {
              BotAccessAvatarStack(userIDs: sharedUserIDs(owned), cachedUser: cachedUser)
              Text(sharedSummary(owned.userIDs.count))
                .foregroundStyle(.secondary)
            }
          }
        }
        .buttonStyle(.plain)
      }
    } else if let access = grants.access(botUserID: botUserID), !access.isOwner {
      BotInfoSection("Access") {
        BotInfoRow(systemImage: "person.crop.circle.fill", tint: .blue, title: "Owner") {
          HStack(spacing: 8) {
            if let owner = cachedUser(access.ownerUserID) {
              UserAvatar(userInfo: owner, size: 22)
            }
            Text(cachedUser(access.ownerUserID)?.user.shortDisplayName ?? "Someone else")
              .foregroundStyle(.secondary)
          }
        }
        BotInfoDivider()
        BotInfoValueRow(systemImage: "key.fill", tint: .green, title: "Your Access", value: access.viewerAccessSummary)
      }
    }
  }

  // MARK: This chat

  private var chatSection: some View {
    BotInfoSection("This Chat") {
      if store.offersOutputMode(botUserID: botUserID) {
        AgentOutputModeSection(peer: .user(id: botUserID), botUserID: botUserID, style: .tile)
        BotInfoDivider()
      }
      BotInfoNotificationsRow(selection: $notificationSelection)
    }
  }

  // MARK: Manage

  @ViewBuilder
  private var manageSection: some View {
    if isOwner {
      BotInfoSection("Manage") {
        NavigationLink {
          OwnedBotSettingsDestination(botUserID: botUserID, model: settingsModel)
        } label: {
          BotInfoRow(systemImage: "gearshape.fill", tint: .gray, title: "Bot Settings", showsChevron: true) {
            EmptyView()
          } detail: {
            Text("Photo, name, username, token, and skills")
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: Helpers

  private var peopleToLoad: [Int64] {
    var ids: [Int64] = []
    if let owned { ids.append(contentsOf: sharedUserIDs(owned)) }
    if let access = grants.access(botUserID: botUserID), !access.isOwner, access.ownerUserID > 0 {
      ids.append(access.ownerUserID)
    }
    return ids
  }

  /// The first few people with access, for the avatar stack.
  private func sharedUserIDs(_ owned: OwnedAgentGrants) -> [Int64] {
    Array(owned.userIDs.sorted().prefix(3))
  }

  private func sharedSummary(_ count: Int) -> String {
    switch count {
    case 0: String(localized: "Only you")
    case 1: String(localized: "1 person")
    default: String(localized: "\(count) people")
    }
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }
}

/// The owner's bot settings, opened from chat info. The settings page needs the
/// owner's bot record, which only the bot list returns.
private struct OwnedBotSettingsDestination: View {
  let botUserID: Int64
  let model: IOSBotsSettingsModel

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.dismiss) private var dismiss
  @State private var didLoad = false

  var body: some View {
    Group {
      if model.bot(botUserID) != nil || didLoad {
        IOSManagedBotSettingsView(
          botID: botUserID,
          model: model,
          showsOpenChat: false,
          onDeleted: { dismiss() },
          copyToken: { BotsSettingsView.copyToken($0) }
        )
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: botUserID) {
      await model.load(realtimeV2, failure: "Couldn’t load this bot. Go back and try again.")
      didLoad = true
    }
  }
}

// MARK: - Building blocks

/// "● Online" under a bot's name in its chat info header.
struct BotInfoStatusLine: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared

  var body: some View {
    if let status = BotStatusSummary.make(user: user, runtime: store.runtimeInfo(botUserID: user.id)) {
      HStack(spacing: 5) {
        Circle()
          .fill(status.tone.tint)
          .frame(width: 7, height: 7)
        Text(status.title)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    }
  }
}

extension BotStatusSummary.Tone {
  var tint: Color {
    switch self {
    case .online: Color(uiColor: .systemGreen)
    case .offline: Color(uiColor: .systemGray)
    case .attention: Color(uiColor: .systemOrange)
    }
  }
}

/// A titled card, like a grouped list section.
struct BotInfoSection<Content: View>: View {
  let title: LocalizedStringKey
  let footer: String?
  let content: Content

  init(_ title: LocalizedStringKey, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 16)

      VStack(spacing: 0) {
        content
      }
      .background(Color(uiColor: .secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      if let footer {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A Settings-style row: a tinted symbol tile, a title, an optional value on
/// the trailing edge and an optional line under the title.
struct BotInfoRow<Value: View, Detail: View>: View {
  let systemImage: String
  let tint: Color
  let title: LocalizedStringKey
  var showsChevron = false
  let value: Value
  let detail: Detail

  init(
    systemImage: String,
    tint: Color,
    title: LocalizedStringKey,
    showsChevron: Bool = false,
    @ViewBuilder value: () -> Value,
    @ViewBuilder detail: () -> Detail = { EmptyView() }
  ) {
    self.systemImage = systemImage
    self.tint = tint
    self.title = title
    self.showsChevron = showsChevron
    self.value = value()
    self.detail = detail()
  }

  var body: some View {
    HStack(spacing: 12) {
      BotInfoIconTile(systemImage: systemImage, tint: tint)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        detail
          .font(.footnote)
          .lineLimit(3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      value
        .lineLimit(1)

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 48)
    .contentShape(Rectangle())
  }
}

struct BotInfoValueRow: View {
  let systemImage: String
  let tint: Color
  let title: LocalizedStringKey
  let value: String

  var body: some View {
    BotInfoRow(systemImage: systemImage, tint: tint, title: title) {
      Text(value)
        .foregroundStyle(.secondary)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
  }
}

struct BotInfoIconTile: View {
  let systemImage: String
  let tint: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 29, height: 29)
      .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .accessibilityHidden(true)
  }
}

/// Inset to line up with row titles, past the icon tile.
struct BotInfoDivider: View {
  var body: some View {
    Divider()
      .padding(.leading, 57)
  }
}

/// Overlapping avatars of people with access.
struct BotAccessAvatarStack: View {
  let userIDs: [Int64]
  let cachedUser: (Int64) -> UserInfo?

  var body: some View {
    HStack(spacing: -7) {
      ForEach(userIDs, id: \.self) { userID in
        Group {
          if let userInfo = cachedUser(userID) {
            UserAvatar(userInfo: userInfo, size: 24)
          } else {
            Circle().fill(Color(uiColor: .systemGray4))
          }
        }
        .frame(width: 24, height: 24)
        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
      }
    }
    .accessibilityHidden(true)
  }
}

private struct BotInfoNotificationsRow: View {
  @Binding var selection: DialogNotificationSettingSelection
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  var body: some View {
    Menu {
      DialogNotificationSettingsMenuContent(selection: $selection, globalMode: notificationSettings.mode)
    } label: {
      BotInfoRow(systemImage: "bell.fill", tint: .red, title: "Notifications") {
        HStack(spacing: 6) {
          Text(DialogNotificationSettingsPresentation.title(for: selection, globalMode: notificationSettings.mode))
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Notifications")
  }
}
