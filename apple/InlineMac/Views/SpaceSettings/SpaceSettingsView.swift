import Foundation
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpaceSettingsView: View {
  let spaceId: Int64
  private let onOpenIntegrations: (() -> Void)?
  private let onOpenMembers: (() -> Void)?
  private let onExit: (() -> Void)?

  @EnvironmentObject private var nav: Nav
  @EnvironmentObject private var data: DataManager

  @StateObject private var viewModel: FullSpaceViewModel
  @StateObject private var membershipStatus: SpaceMembershipStatusViewModel
  @StateObject private var urlPreviewExclusions: SpaceUrlPreviewExclusionsViewModel
  @State private var showDeleteConfirm = false
  @State private var showLeaveConfirm = false
  @State private var actionError: String?
  @State private var isPerformingAction = false

  init(
    spaceId: Int64,
    onOpenIntegrations: (() -> Void)? = nil,
    onOpenMembers: (() -> Void)? = nil,
    onExit: (() -> Void)? = nil
  ) {
    self.spaceId = spaceId
    self.onOpenIntegrations = onOpenIntegrations
    self.onOpenMembers = onOpenMembers
    self.onExit = onExit
    _viewModel = StateObject(wrappedValue: FullSpaceViewModel(db: AppDatabase.shared, spaceId: spaceId))
    _membershipStatus = StateObject(wrappedValue: SpaceMembershipStatusViewModel(db: AppDatabase.shared, spaceId: spaceId))
    _urlPreviewExclusions = StateObject(wrappedValue: SpaceUrlPreviewExclusionsViewModel(spaceId: spaceId))
  }

  private var isCreator: Bool {
    membershipStatus.role == .owner || viewModel.space?.creator == true
  }

  private var isAdminOrOwner: Bool {
    isCreator || membershipStatus.canManageMembers
  }

  private var spaceName: String {
    viewModel.space?.displayName ?? "Space"
  }

  private var spaceSubtitle: String {
    guard viewModel.space != nil else { return "Loading space details" }
    return "\(memberSummary), \(threadSummary)"
  }

  private var memberSummary: String {
    countText(viewModel.members.count, singular: "member")
  }

  private var threadSummary: String {
    countText(viewModel.chats.count, singular: "thread")
  }

  private var directChatSummary: String {
    countText(viewModel.memberChats.count, singular: "direct chat")
  }

  private var createdSummary: String {
    guard let date = viewModel.space?.date else { return "Unknown" }
    return Self.createdFormatter.string(from: date)
  }

  private var roleSummary: String {
    if isCreator { return "Owner" }

    return switch membershipStatus.role {
      case .owner:
        "Owner"
      case .admin:
        "Admin"
      case .member:
        "Member"
      case nil:
        membershipStatus.isRefreshing ? "Checking access" : "Member"
    }
  }

  private var permissionSummary: String {
    if isCreator { return "Full administration for this space" }

    return switch membershipStatus.role {
      case .owner:
        "Full administration for this space"
      case .admin:
        "Can manage members and integrations"
      case .member:
        "Can use chats available to you"
      case nil:
        membershipStatus.isRefreshing ? "Checking latest permissions" : "Standard member access"
    }
  }

  private var integrationsButtonTitle: String {
    isAdminOrOwner ? "Manage Integrations..." : "View Integrations..."
  }

  private var destructiveSectionTitle: String {
    isCreator ? "Delete Space" : "Leave Space"
  }

  private var destructiveTitle: String {
    isCreator ? "Delete \(spaceName)" : "Leave \(spaceName)"
  }

  private var destructiveDescription: String {
    if isCreator {
      return "Permanently removes this space, its membership, and its chats for everyone."
    }
    return "Removes your membership and access to this space."
  }

  private var destructiveButtonTitle: String {
    isCreator ? "Delete Space..." : "Leave Space..."
  }

  private var actionProgressTitle: String {
    isCreator ? "Deleting..." : "Leaving..."
  }

  private static let createdFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  var body: some View {
    Form {
      Section("Space") {
        SpaceSettingsHeader(
          space: viewModel.space,
          title: spaceName,
          subtitle: spaceSubtitle,
          role: roleSummary
        )
      }

      Section("Overview") {
        LabeledContent("Created", value: createdSummary)
        LabeledContent("Members", value: memberSummary)
        LabeledContent("Threads", value: threadSummary)
        LabeledContent("Direct Chats", value: directChatSummary)
        LabeledContent("Space ID") {
          Text(String(spaceId))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
        }
      }

      Section("Your Access") {
        LabeledContent("Role", value: roleSummary)
        LabeledContent("Permissions") {
          Text(permissionSummary)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }

        if membershipStatus.isRefreshing {
          SpaceSettingsStatusRow(title: "Checking latest access...")
        }
      }

      Section("Administration") {
        SpaceSettingsActionRow(
          title: "Members",
          subtitle: "Review membership, invite teammates, and update member access.",
          systemImage: "person.2",
          buttonTitle: "Manage Members...",
          disabledReason: isAdminOrOwner ? nil : "Only space admins and owners can manage members.",
          action: openMembers
        )

        SpaceSettingsActionRow(
          title: "Integrations",
          subtitle: "Connect tools such as Linear and Notion, then configure defaults for this space.",
          systemImage: "app.connected.to.app.below.fill",
          buttonTitle: integrationsButtonTitle,
          disabledReason: nil
        ) {
          openIntegrations()
        }
      }

      if isAdminOrOwner {
        Section("URL Previews") {
          SpaceUrlPreviewExclusionsSettingsView(viewModel: urlPreviewExclusions)
        }
      }

      Section(destructiveSectionTitle) {
        SpaceSettingsDangerRow(
          title: destructiveTitle,
          subtitle: destructiveDescription,
          systemImage: isCreator ? "trash" : "rectangle.portrait.and.arrow.right",
          buttonTitle: destructiveButtonTitle,
          progressTitle: actionProgressTitle,
          isPerformingAction: isPerformingAction,
          action: confirmDestructiveAction
        )
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationTitle("Space Settings")
    .task {
      await membershipStatus.refreshIfNeeded()
      try? await data.getSpace(spaceId: spaceId)
      if isAdminOrOwner {
        await urlPreviewExclusions.loadIfNeeded()
      }
    }
    .sheet(isPresented: $showDeleteConfirm) {
      DeleteSpaceConfirmationSheet(
        spaceName: spaceName,
        isDeleting: isPerformingAction,
        onCancel: {
          guard !isPerformingAction else { return }
          showDeleteConfirm = false
        },
        onDelete: {
          performAction(.delete)
        }
      )
      .interactiveDismissDisabled(isPerformingAction)
    }
    .alert("Leave Space?", isPresented: $showLeaveConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("Leave", role: .destructive) {
        performAction(.leave)
      }
    } message: {
      Text("You will lose access to \(spaceName) and its chats.")
    }
    .alert("Error", isPresented: Binding<Bool>(
      get: { actionError != nil },
      set: { presented in
        if presented == false { actionError = nil }
      }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      if let actionError {
        Text(actionError)
      }
    }
  }

  private func countText(_ count: Int, singular: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : plural ?? "\(singular)s")"
  }

  private func openIntegrations() {
    if let onOpenIntegrations {
      onOpenIntegrations()
      return
    }

    nav.open(.spaceIntegrations(spaceId: spaceId))
  }

  private func openMembers() {
    if let onOpenMembers {
      onOpenMembers()
      return
    }

    nav.open(.members(spaceId: spaceId))
  }

  private func confirmDestructiveAction() {
    if isCreator {
      showDeleteConfirm = true
    } else {
      showLeaveConfirm = true
    }
  }

  private func performAction(_ action: SpaceSettingsAction) {
    guard !isPerformingAction else { return }
    isPerformingAction = true

    Task {
      do {
        switch action {
          case .delete:
            try await data.deleteSpace(spaceId: spaceId)
          case .leave:
            try await data.leaveSpace(spaceId: spaceId)
        }
        await MainActor.run {
          showDeleteConfirm = false
          showLeaveConfirm = false

          if let onExit {
            onExit()
          } else {
            nav.openHome(replace: true)
          }
          isPerformingAction = false
        }
      } catch {
        await MainActor.run {
          actionError = error.localizedDescription
          isPerformingAction = false
        }
        Log.shared.error("Failed to \(action.logName) space", error: error)
      }
    }
  }
}

private enum SpaceSettingsAction {
  case delete
  case leave

  var logName: String {
    switch self {
      case .delete:
        "delete"
      case .leave:
        "leave"
    }
  }
}

private struct DeleteSpaceConfirmationSheet: View {
  let spaceName: String
  let isDeleting: Bool
  let onCancel: () -> Void
  let onDelete: () -> Void

  @State private var confirmation = ""
  @FocusState private var isTextFieldFocused: Bool

  private var canDelete: Bool {
    confirmation == "DELETE"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(.orange)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 6) {
          Text("Delete \(spaceName)?")
            .font(.title3)
            .fontWeight(.semibold)

          Text("This permanently deletes the space for every member. This action cannot be undone.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Type DELETE to confirm.")
          .font(.callout)

        TextField("DELETE", text: $confirmation)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .disabled(isDeleting)
          .focused($isTextFieldFocused)
          .onSubmit {}
      }

      HStack {
        Spacer()

        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isDeleting)

        Button(role: .destructive) {
          onDelete()
        } label: {
          if isDeleting {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("Deleting...")
            }
          } else {
            Text("Delete Space")
          }
        }
        .disabled(!canDelete || isDeleting)
        .focusable(false)
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear {
      DispatchQueue.main.async {
        isTextFieldFocused = true
      }
    }
  }
}

private struct SpaceSettingsHeader: View {
  let space: Space?
  let title: String
  let subtitle: String
  let role: String

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      if let space {
        SpaceAvatar(space: space, size: 48)
      } else {
        Circle()
          .fill(.quaternary)
          .frame(width: 48, height: 48)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
          .lineLimit(1)

        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Text(role)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(.quaternary)
        )
        .lineLimit(1)
    }
    .padding(.vertical, 4)
  }
}

private struct SpaceSettingsActionRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let buttonTitle: String
  let disabledReason: String?
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        rowIcon

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .fontWeight(.medium)

          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 12)

        Button(buttonTitle, action: action)
          .controlSize(.small)
          .disabled(disabledReason != nil)
      }

      if let disabledReason {
        Text(disabledReason)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.leading, 32)
      }
    }
    .padding(.vertical, 4)
  }

  private var rowIcon: some View {
    Image(systemName: systemImage)
      .font(.system(size: 15, weight: .regular))
      .foregroundStyle(.secondary)
      .frame(width: 20, height: 20)
  }
}

private struct SpaceUrlPreviewExclusionsSettingsView: View {
  @ObservedObject var viewModel: SpaceUrlPreviewExclusionsViewModel
  @State private var draft = ""

  private var canAdd: Bool {
    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && viewModel.isMutating == false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        TextField("example.com or example.com/path", text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)

        Button("Add", action: add)
          .controlSize(.small)
          .disabled(!canAdd)
      }

      if viewModel.isLoading {
        SpaceSettingsStatusRow(title: "Loading exclusions...")
      } else if viewModel.exclusions.isEmpty {
        Text("No exclusions")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(viewModel.exclusions) { exclusion in
            SpaceUrlPreviewExclusionRow(
              exclusion: exclusion,
              isMutating: viewModel.isMutating,
              onRemove: {
                Task {
                  await viewModel.remove(id: exclusion.id)
                }
              }
            )

            if exclusion.id != viewModel.exclusions.last?.id {
              Divider()
            }
          }
        }
      }

      if let error = viewModel.errorMessage {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
    .task {
      await viewModel.loadIfNeeded()
    }
  }

  private func add() {
    guard canAdd else { return }
    let value = draft
    Task {
      await viewModel.add(value: value)
      if viewModel.errorMessage == nil {
        draft = ""
      }
    }
  }
}

private struct SpaceUrlPreviewExclusionRow: View {
  let exclusion: SpaceUrlPreviewExclusionItem
  let isMutating: Bool
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: exclusion.pathPrefix == nil ? "network" : "link")
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)

      Text(exclusion.displayValue)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)

      Spacer(minLength: 12)

      Button(role: .destructive, action: onRemove) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .disabled(isMutating)
      .help("Remove")
    }
    .padding(.vertical, 6)
  }
}

private struct SpaceSettingsDangerRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let buttonTitle: String
  let progressTitle: String
  let isPerformingAction: Bool
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fontWeight(.medium)

        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Button(role: .destructive, action: action) {
        if isPerformingAction {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text(progressTitle)
          }
        } else {
          Text(buttonTitle)
        }
      }
      .controlSize(.small)
      .disabled(isPerformingAction)
    }
    .padding(.vertical, 4)
  }
}

private struct SpaceSettingsStatusRow: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)

      Text(title)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview {
  SpaceSettingsView(spaceId: 1)
    .previewsEnvironmentForMac(.populated)
}
