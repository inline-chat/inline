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
  }

  private var isCreator: Bool {
    membershipStatus.role == .owner
  }

  private var isAdminOrOwner: Bool {
    membershipStatus.canManageMembers
  }

  private var spaceName: String {
    viewModel.space?.displayName ?? "Space"
  }

  private var memberSummary: String {
    let count = viewModel.members.count
    return "\(count) member\(count == 1 ? "" : "s")"
  }

  private var roleSummary: String {
    switch membershipStatus.role {
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

  var body: some View {
    Form {
      Section("Space") {
        SpaceSettingsIdentityRow(
          space: viewModel.space,
          title: spaceName,
          subtitle: memberSummary,
          detail: roleSummary
        )
      }

      Section {
        Button {
          openMembers()
        } label: {
          SpaceSettingsNavigationRow(
            title: "Members",
            subtitle: isAdminOrOwner ? "Review and manage access" : "Only admins can manage members",
            systemImage: "person.2"
          )
        }
        .buttonStyle(.plain)
        .disabled(!isAdminOrOwner)

        Button {
          openIntegrations()
        } label: {
          SpaceSettingsNavigationRow(
            title: "Integrations",
            subtitle: "Connect tools and configure defaults",
            systemImage: "app.connected.to.app.below.fill"
          )
        }
        .buttonStyle(.plain)
      } header: {
        Text("Manage")
      } footer: {
        if !isAdminOrOwner {
          Text("Only space admins and owners can manage members.")
        }
      }

      Section {
        Button(role: .destructive) {
          if isCreator {
            showDeleteConfirm = true
          } else {
            showLeaveConfirm = true
          }
        } label: {
          Label(
            isCreator ? "Delete Space..." : "Leave Space...",
            systemImage: isCreator ? "trash" : "rectangle.portrait.and.arrow.right"
          )
        }
        .disabled(isPerformingAction)
      } footer: {
        Text(
          isCreator
            ? "Deleting this space removes it for everyone."
            : "Leaving removes your access to this space."
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
      Text("You will lose access to this space.")
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
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Delete Space?")
          .font(.title3)
          .fontWeight(.semibold)

        Text("This will delete \(spaceName) for everyone. This action cannot be undone.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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

private struct SpaceSettingsIdentityRow: View {
  let space: Space?
  let title: String
  let subtitle: String
  let detail: String

  var body: some View {
    HStack(spacing: 12) {
      if let space {
        SpaceAvatar(space: space, size: 40)
      } else {
        Circle()
          .fill(.quaternary)
          .frame(width: 40, height: 40)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .lineLimit(1)

        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.vertical, 3)
  }
}

private struct SpaceSettingsNavigationRow: View {
  @Environment(\.isEnabled) private var isEnabled

  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)

        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      Image(systemName: "chevron.right")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 2)
    .opacity(isEnabled ? 1 : 0.5)
    .contentShape(Rectangle())
  }
}

#Preview {
  SpaceSettingsView(spaceId: 1)
    .previewsEnvironmentForMac(.populated)
}
