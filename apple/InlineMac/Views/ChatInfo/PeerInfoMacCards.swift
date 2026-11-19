import AppKit
import InlineKit
import InlineUI
import SwiftUI

// Cards between the chat info header and its tabs. Every row that does
// something is a full-width button with a visible affordance (a chevron for
// navigation, a symbol for an action), and its secondary actions live in its
// context menu.

/// A rounded group of rows, with an optional caption above and footnote below.
struct PeerInfoCard<Content: View>: View {
  private let title: String?
  private let footer: String?
  private let content: Content

  init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title {
        ChatInfoSectionTitle(title)
      }
      Group(subviews: content) { rows in
        VStack(spacing: 0) {
          ForEach(rows.indices, id: \.self) { index in
            rows[index]
            if index < rows.count - 1 {
              Divider().padding(.leading, 12)
            }
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
      )
      if let footer {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A caption over a value, like Contacts. The value can be selected.
struct PeerInfoFieldRow: View {
  let label: String
  let value: String
  var valueStyle: Color = .primary
  var lineLimit: Int? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .foregroundStyle(valueStyle)
        .lineLimit(lineLimit)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }
}

/// A row that does one thing when clicked. Navigation rows end in a chevron;
/// action rows show the action's symbol on hover.
struct PeerInfoActionRowButton<Leading: View, Trailing: View>: View {
  enum Kind {
    case navigation
    case action(systemImage: String)
  }

  /// Small label above the title, like "username" in Contacts.
  var caption: String? = nil
  let title: String
  var detail: String? = nil
  var kind: Kind = .navigation
  var help: String? = nil
  let action: () -> Void
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        leading()
        VStack(alignment: .leading, spacing: 1) {
          if let caption {
            Text(caption)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(title)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
        switch kind {
        case .navigation:
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
        case let .action(systemImage):
          Image(systemName: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .background(isHovered ? Color.primary.opacity(0.04) : .clear)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(help ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}

extension PeerInfoActionRowButton where Leading == EmptyView, Trailing == EmptyView {
  /// A Contacts-style field you can act on: "username" above "@sam".
  init(
    caption: String,
    value: String,
    actionSymbol: String,
    help: String,
    action: @escaping () -> Void
  ) {
    self.init(
      caption: caption,
      title: value,
      kind: .action(systemImage: actionSymbol),
      help: help,
      action: action,
      leading: { EmptyView() },
      trailing: { EmptyView() }
    )
  }
}

/// A small rounded symbol at the start of a card row.
struct PeerInfoRowIcon: View {
  let systemImage: String
  var color: Color = .accentColor

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 24, height: 24)
      .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .accessibilityHidden(true)
  }
}

@MainActor
enum PeerInfoPasteboard {
  static func copy(_ string: String, toast: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    ToastCenter.shared.showSuccess(toast)
  }
}

// MARK: - Person

/// What Inline knows about a person: bio, username, email and phone, each
/// only when the server shared it with you. Local time is in the subtitle.
struct PeerInfoPersonCard: View {
  let user: User

  var body: some View {
    let rows = PeerInfoPersonFields(user: user)
    // Local time is in the subtitle, as in the chat header.
    if rows.bio != nil || rows.username != nil || rows.email != nil || rows.phone != nil {
      PeerInfoCard {
        if let bio = rows.bio {
          PeerInfoFieldRow(label: String(localized: "bio"), value: bio)
        }
        if let username = rows.username {
          PeerInfoActionRowButton(
            caption: String(localized: "username"),
            value: "@\(username)",
            actionSymbol: "doc.on.doc",
            help: String(localized: "Copy username"),
            action: { PeerInfoPasteboard.copy("@\(username)", toast: String(localized: "Copied username")) }
          )
          .contextMenu {
            Button("Copy Username", systemImage: "doc.on.doc") {
              PeerInfoPasteboard.copy("@\(username)", toast: String(localized: "Copied username"))
            }
          }
        }
        if let email = rows.email {
          PeerInfoActionRowButton(
            caption: String(localized: "email"),
            value: email,
            actionSymbol: "envelope",
            help: String(localized: "Write an email"),
            action: { if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) } }
          )
          .contextMenu {
            Button("Copy Email Address", systemImage: "doc.on.doc") {
              PeerInfoPasteboard.copy(email, toast: String(localized: "Copied email address"))
            }
          }
        }
        if let phone = rows.phone {
          PeerInfoActionRowButton(
            caption: String(localized: "phone"),
            value: phone,
            actionSymbol: "doc.on.doc",
            help: String(localized: "Copy phone number"),
            action: { PeerInfoPasteboard.copy(phone, toast: String(localized: "Copied phone number")) }
          )
        }
      }
    }
  }
}

// MARK: - Bot

/// One row for what a bridge agent runs on. Click it for every detail.
struct PeerInfoBotRuntimeRow: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared
  @State private var showsDetails = false

  private var runtime: AgentRuntimeInfo? { store.runtimeInfo(botUserID: user.id) }

  var body: some View {
    let status = BotStatusSummary.make(user: user, runtime: runtime)
    if let runtime, runtime.runtimeTitle != nil || runtime.machineLabel != nil {
      PeerInfoActionRowButton(
        title: runtime.runtimeTitle ?? String(localized: "Agent"),
        detail: detail(runtime),
        kind: .navigation,
        help: String(localized: "Show runtime details"),
        action: { showsDetails = true },
        leading: {
          PeerInfoRowIcon(
            systemImage: "terminal",
            color: status?.tone == .attention ? .orange : (status?.tone == .offline ? .gray : Color(nsColor: .darkGray))
          )
        },
        // The status is under the name already; the icon's color repeats only its tone.
        trailing: { EmptyView() }
      )
      .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
        PeerInfoBotRuntimeDetails(user: user)
      }
    }
  }

  private func detail(_ runtime: AgentRuntimeInfo) -> String? {
    var parts: [String] = []
    if let machine = runtime.machineLabel { parts.append(String(localized: "on \(machine)")) }
    if let cli = runtime.bridgeVersion { parts.append(String(localized: "Inline CLI \(cli)")) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

private struct PeerInfoBotRuntimeDetails: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared

  var body: some View {
    let runtime = store.runtimeInfo(botUserID: user.id)
    let status = BotStatusSummary.make(user: user, runtime: runtime)
    VStack(alignment: .leading, spacing: 10) {
      if let status {
        HStack(spacing: 6) {
          Circle().fill(status.tone.color).frame(width: 8, height: 8)
          Text(status.title).font(.headline)
        }
        if let detail = status.detail {
          Text(detail)
            .foregroundStyle(status.tone == .attention ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
        detailRow("Machine", runtime?.machineLabel)
        detailRow("Runtime", runtime?.runtimeTitle)
        detailRow("Inline CLI", runtime?.bridgeVersion)
      }
    }
    .padding(16)
    .frame(width: 300, alignment: .leading)
  }

  @ViewBuilder
  private func detailRow(_ title: LocalizedStringKey, _ value: String?) -> some View {
    if let value {
      GridRow {
        Text(title).foregroundStyle(.secondary)
        Text(value).textSelection(.enabled).lineLimit(2)
      }
    }
  }
}

/// Who can message a bot. Owners open the access sheet; everyone else sees
/// the owner and can open their profile.
struct PeerInfoBotAccessRow: View {
  let bot: UserInfo
  let onOpenOwner: (Int64) -> Void
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var showsAccessSheet = false
  @State private var loadedUsersGeneration = 0

  private var botUserID: Int64 { bot.user.id }
  private var isOpen: Bool { grants.openToEveryoneByBotUserID[botUserID] == true }

  var body: some View {
    Group {
      if let owned = grants.ownedGrants(botUserID: botUserID) {
        PeerInfoActionRowButton(
          title: String(localized: "Shared with \(owned.sharedWithSummary(openToEveryone: isOpen))"),
          detail: isOpen
            ? String(localized: "Anyone on Inline can message it")
            : String(localized: "Only people you share with can message it"),
          kind: .navigation,
          help: String(localized: "Choose who can message \(bot.user.shortDisplayName)"),
          action: { showsAccessSheet = true },
          leading: { PeerInfoRowIcon(systemImage: "person.2.fill") },
          trailing: { avatarStack(Array(owned.userIDs.sorted().prefix(3))) }
        )
      } else if let access = grants.access(botUserID: botUserID), !access.isOwner, access.ownerUserID > 0 {
        let owner = cachedUser(access.ownerUserID)
        PeerInfoActionRowButton(
          title: String(localized: "Owned by \(owner?.user.displayName ?? String(localized: "someone else"))"),
          detail: access.viewerAccessSummary,
          kind: .navigation,
          help: String(localized: "Open the owner’s profile"),
          action: { onOpenOwner(access.ownerUserID) },
          leading: {
            if let owner {
              UserAvatar(user: owner.user, size: 24)
            } else {
              PeerInfoRowIcon(systemImage: "person.fill", color: .gray)
            }
          },
          trailing: { EmptyView() }
        )
      } else if grants.failedBotUserIDs.contains(botUserID) {
        PeerInfoActionRowButton(
          title: String(localized: "Couldn’t load who can message it"),
          kind: .action(systemImage: "arrow.clockwise"),
          action: { grants.refresh(botUserID: botUserID) },
          leading: { PeerInfoRowIcon(systemImage: "exclamationmark.triangle.fill", color: .orange) },
          trailing: { Text("Try Again").font(.caption).foregroundStyle(.tint) }
        )
      }
    }
    .task(id: botUserID) { grants.ensureLoaded(botUserID: botUserID) }
    .task(id: peopleToLoad) {
      let missing = peopleToLoad.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
    .sheet(isPresented: $showsAccessSheet) {
      BotAccessSheet(bot: bot)
    }
  }

  private var peopleToLoad: [Int64] {
    if let owned = grants.ownedGrants(botUserID: botUserID) {
      return Array(owned.userIDs.sorted().prefix(3))
    }
    if let access = grants.access(botUserID: botUserID), !access.isOwner, access.ownerUserID > 0 {
      return [access.ownerUserID]
    }
    return []
  }

  private func avatarStack(_ userIDs: [Int64]) -> some View {
    HStack(spacing: -6) {
      ForEach(userIDs, id: \.self) { userID in
        Group {
          if let userInfo = cachedUser(userID) {
            UserAvatar(user: userInfo.user, size: 20)
          } else {
            Circle().fill(Color.secondary.opacity(0.3))
          }
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
      }
    }
    .accessibilityHidden(true)
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }
}

/// The bot's bio, when it has one.
struct PeerInfoBotAboutRow: View {
  let user: User

  var body: some View {
    if let bio = user.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
      PeerInfoFieldRow(label: String(localized: "about"), value: bio)
    }
  }
}

/// The chat and user IDs, only while Developer Mode is on. Clicking one copies it.
struct PeerInfoMacDeveloperIDs: View {
  let entries: [(label: String, id: Int64)]
  @AppStorage(DeveloperMode.key) private var developerMode = false

  var body: some View {
    if developerMode, !entries.isEmpty {
      PeerInfoCard("Developer") {
        ForEach(entries, id: \.label) { entry in
          PeerInfoActionRowButton(
            caption: entry.label,
            value: String(entry.id),
            actionSymbol: "doc.on.doc",
            help: "Copy the \(entry.label.lowercased())",
            action: { DeveloperIDs.copy(entry.id, label: entry.label) }
          )
        }
      }
    }
  }
}

