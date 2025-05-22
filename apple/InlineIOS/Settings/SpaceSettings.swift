import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpaceSettingsView: View {
  let spaceId: Int64
  @EnvironmentObject private var navigation: Navigation
  @EnvironmentObject private var data: DataManager
  @EnvironmentStateObject private var viewModel: FullSpaceViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  private var isCreator: Bool {
    viewModel.members.first { $0.userInfo.user.id == Auth.shared.getCurrentUserId() }?.member.role == .owner
  }

  var body: some View {
    List {
      Section {
        HStack {
          if let space = viewModel.space {
            SpaceAvatar(space: space, size: 42)
              .padding(.trailing, 6)

          } else {
            Circle()
              .fill(Color(.systemGray6))
              .frame(width: 42, height: 42)
              .padding(.trailing, 6)
          }
          VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.space?.nameWithoutEmoji ?? "Space")
              .font(.body)
              .fontWeight(.medium)

            Text("\(viewModel.members.count) \(viewModel.members.count == 1 ? "member" : "members")")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
      }
      Section(header: Text("Space ID")) {
        HStack {
          Text("\(viewModel.space?.id ?? 0)")

          Spacer()
          Button(action: {
            UIPasteboard.general.string = "\(viewModel.space?.id ?? 0)"
            ToastManager.shared.showToast(
              "Space ID copied to clipboard",
              type: .success,
              systemImage: "doc.on.doc.fill"
            )
          }) {
            Image(systemName: "doc.on.doc.fill")
              .foregroundColor(.secondary)
          }
        }
      }
      Section {
        NavigationLink(destination: SpaceIntegrationsView(spaceId: spaceId)) {
          HStack {
            Image(systemName: "app.connected.to.app.below.fill")
              .foregroundColor(.white)
              .frame(width: 25, height: 25)
              .background(Color.purple)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Integrations")
              .foregroundColor(.primary)
              .padding(.leading, 4)
            Spacer()
          }
          .padding(.vertical, 2)
        }
      }

      Section {
        Button(role: .destructive) {
          showSpaceActionAlert()
        } label: {
          if isCreator {
            Label("Delete Space", systemImage: "trash.fill")
              .foregroundColor(.red)
          } else {
            Label("Leave Space", systemImage: "rectangle.portrait.and.arrow.right.fill")
              .foregroundColor(.primary)
          }
        }
      }

      .toolbarRole(.editor)
      .toolbar(.hidden, for: .tabBar)
      .toolbar {
        ToolbarItem(id: "settings", placement: .principal) {
          HStack {
            Image(systemName: "gearshape.fill")
              .foregroundColor(.secondary)
              .font(.callout)
              .padding(.trailing, 4)
            VStack(alignment: .leading) {
              Text("\(viewModel.space?.nameWithoutEmoji ?? "Space") Settings")
                .font(.body)
                .fontWeight(.semibold)
            }
          }
        }
      }
    }
  }

  private func showSpaceActionAlert() {
    let title = isCreator ? "Delete Space" : "Leave Space"
    let message = isCreator
      ? "Are you sure you want to delete this space? This action cannot be undone."
      : "Are you sure you want to leave this space?"

    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in
      Task {
        do {
          navigation.pop()
          if isCreator {
            try await data.deleteSpace(spaceId: spaceId)
          } else {
            try await data.leaveSpace(spaceId: spaceId)
          }
        } catch {
          Log.shared.error("Failed to \(isCreator ? "delete" : "leave") space", error: error)
        }
      }
    })

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootVC = windowScene.windows.first?.rootViewController
    {
      rootVC.topmostPresentedViewController.present(alert, animated: true)
    }
  }
}

#Preview {
  SpaceSettingsView(spaceId: 1)
}
