import InlineKit
import InlineUI
import SwiftUI
import UIKit

// Cards between the chat info header and its tabs. Rows that navigate end in
// a chevron; rows that act (copy, write an email) say so in VoiceOver and
// keep their other actions in the long-press menu.

/// An inset grouped card, with an optional caption above and footnote below.
@available(iOS 18.0, *)
struct PeerInfoIOSCard<Content: View>: View {
  private let title: String?
  private let footer: String?
  private let content: Content

  init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if let title {
        Text(title)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .padding(.horizontal, 16)
          .accessibilityAddTraits(.isHeader)
      }
      Group(subviews: content) { rows in
        VStack(spacing: 0) {
          ForEach(rows.indices, id: \.self) { index in
            rows[index]
            if index < rows.count - 1 {
              Divider().padding(.leading, 16)
            }
          }
        }
      }
      .background(
        Color(uiColor: .secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      if let footer {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// "username" above "@sam", like Contacts. Tapping does the row's one action;
/// long-press offers Copy.
struct PeerInfoIOSFieldRow: View {
  let label: String
  let value: String
  var lineLimit: Int? = nil
  var action: (() -> Void)? = nil
  var accessibilityHint: String? = nil
  var copyTitle: String? = nil

  var body: some View {
    let content = VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(value)
        .foregroundStyle(action == nil ? Color.primary : Color.accentColor)
        .lineLimit(lineLimit)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .contentShape(Rectangle())

    Group {
      if let action {
        Button(action: action) { content }
          .buttonStyle(PeerInfoIOSRowButtonStyle())
          .accessibilityHint(accessibilityHint ?? "")
      } else {
        content
      }
    }
    .contextMenu {
      Button(copyTitle ?? "Copy", systemImage: "doc.on.doc") {
        PeerInfoIOSPasteboard.copy(value, toast: "Copied")
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// A row that opens something, ending in a chevron.
struct PeerInfoIOSNavigationRow<Leading: View, Trailing: View>: View {
  let title: String
  var detail: String? = nil
  var showsChevron = true
  let action: () -> Void
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        leading()
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let detail {
            Text(detail)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
        if showsChevron {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(PeerInfoIOSRowButtonStyle())
    .accessibilityElement(children: .combine)
  }
}

/// Highlights a card row while it is pressed, like a list cell.
struct PeerInfoIOSRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color(uiColor: .systemFill) : .clear)
  }
}

/// A small rounded symbol at the start of a card row.
struct PeerInfoIOSRowIcon: View {
  let systemImage: String
  var color: Color = .accentColor

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 30, height: 30)
      .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .accessibilityHidden(true)
  }
}

enum PeerInfoIOSPasteboard {
  static func copy(_ string: String, toast: String) {
    UIPasteboard.general.string = string
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    ToastManager.shared.showToast(toast, type: .success, systemImage: "doc.on.doc")
  }
}

// MARK: - Person

/// Bio, username, email and phone, each only when shared with you. Local time
/// is in the subtitle.
@available(iOS 18.0, *)
struct PeerInfoIOSPersonCard: View {
  let user: User
  @Environment(\.openURL) private var openURL

  var body: some View {
    let fields = PeerInfoPersonFields(user: user)
    // Local time is in the subtitle, as in the chat header.
    if fields.bio != nil || fields.username != nil || fields.email != nil || fields.phone != nil {
      PeerInfoIOSCard {
        if let bio = fields.bio {
          PeerInfoIOSFieldRow(label: "bio", value: bio, copyTitle: "Copy Bio")
        }
        if let username = fields.username {
          PeerInfoIOSFieldRow(
            label: "username",
            value: "@\(username)",
            action: { PeerInfoIOSPasteboard.copy("@\(username)", toast: "Copied username") },
            accessibilityHint: "Copies the username",
            copyTitle: "Copy Username"
          )
        }
        if let email = fields.email {
          PeerInfoIOSFieldRow(
            label: "email",
            value: email,
            action: { if let url = URL(string: "mailto:\(email)") { openURL(url) } },
            accessibilityHint: "Writes an email",
            copyTitle: "Copy Email Address"
          )
        }
        if let phone = fields.phone {
          PeerInfoIOSFieldRow(
            label: "phone",
            value: phone,
            action: {
              let digits = phone.filter { $0.isNumber || $0 == "+" }
              if let url = URL(string: "tel:\(digits)") { openURL(url) }
            },
            accessibilityHint: "Calls this number",
            copyTitle: "Copy Phone Number"
          )
        }
      }
    }
  }
}

// MARK: - Bot

/// The bot's bio, what it runs on, and who can message it. Owners open the
/// access list from here; everyone else sees the owner.
@available(iOS 18.0, *)
struct PeerInfoIOSBotCard: View {
  let bot: UserInfo
  let onOpenOwner: (Int64) -> Void

  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var showsRuntime = false
  @State private var loadedUsersGeneration = 0

  private var botUserID: Int64 { bot.user.id }
  private var runtime: AgentRuntimeInfo? { store.runtimeInfo(botUserID: botUserID) }
  private var isOpen: Bool { grants.openToEveryoneByBotUserID[botUserID] == true }

  var body: some View {
    PeerInfoIOSCard {
      if let bio = bot.user.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
        PeerInfoIOSFieldRow(label: "about", value: bio, copyTitle: "Copy About")
      }
      runtimeRow
      accessRow
    }
    .task(id: botUserID) { grants.ensureLoaded(botUserID: botUserID) }
    .task(id: peopleToLoad) {
      let missing = peopleToLoad.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
    .sheet(isPresented: $showsRuntime) {
      PeerInfoIOSRuntimeSheet(user: bot.user)
        .presentationDetents([.medium])
    }
  }

  @ViewBuilder
  private var runtimeRow: some View {
    let status = BotStatusSummary.make(user: bot.user, runtime: runtime)
    if let runtime, runtime.runtimeTitle != nil || runtime.machineLabel != nil {
      PeerInfoIOSNavigationRow(
        title: runtime.runtimeTitle ?? "Agent",
        detail: runtime.machineLabel.map { "on \($0)" },
        action: { showsRuntime = true },
        leading: {
          PeerInfoIOSRowIcon(
            systemImage: "terminal.fill",
            color: status?.tone == .attention ? .orange : (status?.tone == .offline ? .gray : Color(uiColor: .darkGray))
          )
        },
        // The status is under the name already; the icon's color repeats only its tone.
        trailing: { EmptyView() }
      )
    }
  }

  @ViewBuilder
  private var accessRow: some View {
    if let owned = grants.ownedGrants(botUserID: botUserID) {
      NavigationLink {
        BotAccessView(bot: bot)
      } label: {
        HStack(spacing: 12) {
          PeerInfoIOSRowIcon(systemImage: "person.2.fill")
          VStack(alignment: .leading, spacing: 2) {
            Text("Shared with \(owned.sharedWithSummary(openToEveryone: isOpen))")
              .foregroundStyle(.primary)
            Text(isOpen ? "Anyone on Inline can message it" : "Only people you share with can message it")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          avatarStack(Array(owned.userIDs.sorted().prefix(3)))
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(PeerInfoIOSRowButtonStyle())
    } else if let access = grants.access(botUserID: botUserID), !access.isOwner, access.ownerUserID > 0 {
      let owner = cachedUser(access.ownerUserID)
      PeerInfoIOSNavigationRow(
        title: "Owned by \(owner?.user.displayName ?? "someone else")",
        detail: access.viewerAccessSummary,
        action: { onOpenOwner(access.ownerUserID) },
        leading: {
          if let owner {
            UserAvatar(userInfo: owner, size: 30)
          } else {
            PeerInfoIOSRowIcon(systemImage: "person.fill", color: .gray)
          }
        },
        trailing: { EmptyView() }
      )
    } else if grants.failedBotUserIDs.contains(botUserID) {
      PeerInfoIOSNavigationRow(
        title: "Couldn’t load who can message it",
        detail: "Tap to try again",
        showsChevron: false,
        action: { grants.refresh(botUserID: botUserID) },
        leading: { PeerInfoIOSRowIcon(systemImage: "exclamationmark.triangle.fill", color: .orange) },
        trailing: { EmptyView() }
      )
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
    HStack(spacing: -7) {
      ForEach(userIDs, id: \.self) { userID in
        Group {
          if let userInfo = cachedUser(userID) {
            UserAvatar(userInfo: userInfo, size: 22)
          } else {
            Circle().fill(Color.secondary.opacity(0.3))
          }
        }
        .frame(width: 22, height: 22)
        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 1.5))
      }
    }
    .accessibilityHidden(true)
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }
}

/// Every runtime detail, behind the one-line runtime row.
@available(iOS 18.0, *)
private struct PeerInfoIOSRuntimeSheet: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let runtime = store.runtimeInfo(botUserID: user.id)
    let status = BotStatusSummary.make(user: user, runtime: runtime)
    NavigationStack {
      List {
        if let status {
          Section {
            LabeledContent("Status") {
              HStack(spacing: 6) {
                Circle().fill(status.tone.tint).frame(width: 8, height: 8)
                Text(status.title)
              }
            }
          } footer: {
            if let detail = status.detail { Text(detail) }
          }
        }
        Section {
          if let machine = runtime?.machineLabel { LabeledContent("Machine", value: machine) }
          if let title = runtime?.runtimeTitle { LabeledContent("Runtime", value: title) }
          if let cli = runtime?.bridgeVersion { LabeledContent("Inline CLI", value: cli) }
        }
      }
      .navigationTitle("Runtime")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Thread

/// Where a thread lives: its space, and for a subthread where it came from.
@available(iOS 18.0, *)
struct PeerInfoIOSPlaceCard: View {
  let subject: PeerInfoSubject
  let space: Space?
  let parent: Chat?
  let onOpenParent: () -> Void

  var body: some View {
    if space != nil || subject.parentChatId != nil {
      PeerInfoIOSCard {
        if let space {
          HStack(spacing: 12) {
            SpaceAvatar(space: space, size: 30, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 2) {
              Text(space.displayName)
              Text("Space")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .accessibilityElement(children: .combine)
        }
        if subject.parentChatId != nil {
          PeerInfoIOSNavigationRow(
            title: parent?.humanReadableTitle ?? "Parent thread",
            detail: subject.parentMessageId != nil ? "Started from a message here" : "Parent thread",
            action: onOpenParent,
            leading: { PeerInfoIOSRowIcon(systemImage: "arrow.turn.up.left", color: .gray) },
            trailing: { EmptyView() }
          )
        }
      }
    }
  }
}
