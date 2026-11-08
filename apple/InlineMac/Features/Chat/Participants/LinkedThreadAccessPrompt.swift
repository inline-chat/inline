import InlineKit
import InlineUI
import Logger
import SwiftUI

/// "Add Dena to Launch plan?" shown after sending a link to a private thread
/// the recipient can't open.
struct LinkedThreadAccessPromptView: View {
  let gap: LinkedThreadAccessGap
  let isAdding: Bool
  let onAdd: () -> Void

  private var who: String {
    switch gap.users.count {
      case 1: gap.users[0].user.firstName ?? gap.users[0].user.displayName
      default: "\(gap.users.count) people"
    }
  }

  private var names: String {
    let names = gap.users.map { $0.user.firstName ?? $0.user.displayName }
    return names.count == 1 ? names[0] : ListFormatter.localizedString(byJoining: names)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      avatars

      VStack(alignment: .leading, spacing: 1) {
        Text("Add \(who) to \(gap.chatTitle)?")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)

        Text("\(names) can't open the link you sent.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Button("Add", action: onAdd)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isAdding)
        .keyboardShortcut(.defaultAction)
    }
    .padding(12)
    .frame(width: 320)
  }

  private var avatars: some View {
    ZStack(alignment: .bottomTrailing) {
      if let first = gap.users.first {
        UserAvatar(user: first.user, size: 30)
      }
      Image(systemName: "lock.fill")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14)
        .background(.regularMaterial, in: Circle())
        .offset(x: 3, y: 3)
        .accessibilityHidden(true)
    }
  }
}

struct ChatToolbarLinkAccessPromptPresentation: ViewModifier {
  let toolbarState: ChatToolbarState
  let anchor: ChatToolbarState.Anchor

  @State private var isAdding = false

  func body(content: Content) -> some View {
    content
      .popover(isPresented: Binding(
        get: { toolbarState.linkAccessPromptGap(for: anchor) != nil },
        set: { isPresented in
          guard !isPresented, toolbarState.linkAccessPromptGap(for: anchor) != nil else { return }
          toolbarState.dismissPresentation()
        }
      ), arrowEdge: .bottom) {
        if let gap = toolbarState.linkAccessPromptGap(for: anchor) {
          LinkedThreadAccessPromptView(gap: gap, isAdding: isAdding) {
            add(gap)
          }
        }
      }
  }

  @MainActor
  private func add(_ gap: LinkedThreadAccessGap) {
    guard !isAdding else { return }
    isAdding = true

    Task { @MainActor in
      defer { isAdding = false }

      var added: [UserInfo] = []
      for user in gap.users {
        do {
          try await Api.realtime.send(.addChatParticipant(chatID: gap.chat.id, userID: user.user.id))
          added.append(user)
        } catch {
          Log.shared.error("Failed to add linked thread recipient", error: error)
        }
      }

      toolbarState.dismissPresentation()
      guard !added.isEmpty else {
        ToastCenter.shared.showError("Couldn't add them to \(gap.chatTitle)")
        return
      }
      let who = added.count == 1 ? (added[0].user.firstName ?? added[0].user.displayName) : "\(added.count) people"
      ToastCenter.shared.showSuccess("Added \(who) to \(gap.chatTitle)")
    }
  }
}
