import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpaceSettingsView: View {
  let spaceId: Int64

  @EnvironmentObject private var nav: Nav
  @EnvironmentObject private var data: DataManager

  @StateObject private var viewModel: FullSpaceViewModel
  @StateObject private var membershipStatus: SpaceMembershipStatusViewModel
  @State private var showConfirm = false
  @State private var actionError: String?

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = StateObject(wrappedValue: FullSpaceViewModel(db: AppDatabase.shared, spaceId: spaceId))
    _membershipStatus = StateObject(wrappedValue: SpaceMembershipStatusViewModel(db: AppDatabase.shared, spaceId: spaceId))
  }

  private var isCreator: Bool {
    membershipStatus.role == .owner
  }

  private var isAdminOrOwner: Bool {
    membershipStatus.canManageMembers
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header

        Form {
          Section("Space") {
            Button {
              nav.open(.spaceIntegrations(spaceId: spaceId))
            } label: {
              Label("Integrations", systemImage: "app.connected.to.app.below.fill")
            }

            Button {
              nav.open(.members(spaceId: spaceId))
            } label: {
              Label("Manage Members", systemImage: "person.2")
            }
            .disabled(!isAdminOrOwner)
          }

          Section {
            Button(role: .destructive) {
              showConfirm = true
            } label: {
              Label(
                isCreator ? "Delete Space" : "Leave Space",
                systemImage: isCreator ? "trash.fill" : "rectangle.portrait.and.arrow.right"
              )
            }
          }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await membershipStatus.refreshIfNeeded()
      try? await data.getSpace(spaceId: spaceId)
    }
    .alert(isCreator ? "Delete Space?" : "Leave Space?", isPresented: $showConfirm) {
      Button("Cancel", role: .cancel) {}
      Button(isCreator ? "Delete" : "Leave", role: .destructive, action: performAction)
    } message: {
      Text(
        isCreator
          ? "This will delete the space for everyone."
          : "You will lose access to this space."
      )
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

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      if let space = viewModel.space {
        SpaceAvatar(space: space, size: 56)
      } else {
        Circle()
          .fill(Color.gray.opacity(0.15))
          .frame(width: 56, height: 56)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(viewModel.space?.nameWithoutEmoji ?? "Space")
          .font(.title2)
          .fontWeight(.semibold)

        Text("\(viewModel.members.count) member\(viewModel.members.count == 1 ? "" : "s")")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
  }

  private func performAction() {
    Task {
      do {
        if isCreator {
          try await data.deleteSpace(spaceId: spaceId)
        } else {
          try await data.leaveSpace(spaceId: spaceId)
        }
        await MainActor.run {
          nav.openHome(replace: true)
        }
      } catch {
        await MainActor.run {
          actionError = error.localizedDescription
        }
        Log.shared.error("Failed to \(isCreator ? "delete" : "leave") space", error: error)
      }
    }
  }
}

#Preview {
  SpaceSettingsView(spaceId: 1)
    .previewsEnvironmentForMac(.populated)
}
