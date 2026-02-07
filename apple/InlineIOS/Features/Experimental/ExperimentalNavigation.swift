import InlineKit
import SwiftUI

@MainActor
@Observable
final class ExperimentalNavigationModel {
  var path: [Destination] = []
  var presentedSheet: Sheet?

  func push(_ destination: Destination) {
    path.append(destination)
  }

  func pop() {
    _ = path.popLast()
  }

  func popToRoot() {
    path.removeAll(keepingCapacity: true)
  }

  func presentSheet(_ sheet: Sheet) {
    presentedSheet = sheet
  }

  func dismissSheet() {
    presentedSheet = nil
  }

  func reset() {
    popToRoot()
    dismissSheet()
  }
}

private struct ExperimentalHomeView: View {
  @Bindable var nav: ExperimentalNavigationModel

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        SpacePickerMenu(
          onSelectSpace: { space in
            nav.push(.space(id: space.id))
          },
          onCreateSpace: {
            nav.push(.createSpace)
          }
        )
      }
    }
  }
}

private struct ExperimentalSpacesView: View {
  var body: some View {
    EmptyView()
      .navigationTitle("Spaces")
  }
}

private struct ExperimentalSpaceView: View {
  let spaceId: Int64

  var body: some View {
    EmptyView()
      .navigationTitle("Space \(spaceId)")
  }
}

private struct ExperimentalPlaceholderView: View {
  let title: String

  var body: some View {
    VStack(spacing: 12) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
      Text("Experimental destination placeholder")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

struct ExperimentalDestinationView: View {
  @Bindable var nav: ExperimentalNavigationModel
  let destination: Destination

  var body: some View {
    switch destination {
    case .chats:
      ExperimentalHomeView(nav: nav)
    case .archived:
      ExperimentalPlaceholderView(title: "Archived")
    case .spaces:
      ExperimentalSpacesView()
    case let .space(id):
      ExperimentalSpaceView(spaceId: id)
    case let .chat(peer):
      ExperimentalPlaceholderView(title: "Chat \(peer)")
    case let .chatInfo(chatItem):
      ExperimentalPlaceholderView(title: "Chat Info \(chatItem.id)")
    case let .spaceSettings(spaceId):
      ExperimentalPlaceholderView(title: "Space Settings \(spaceId)")
    case let .spaceIntegrations(spaceId):
      ExperimentalPlaceholderView(title: "Space Integrations \(spaceId)")
    case let .integrationOptions(spaceId, provider):
      ExperimentalPlaceholderView(title: "Integration \(provider) \(spaceId)")
    case .createSpaceChat:
      ExperimentalPlaceholderView(title: "Create Space Chat")
    case let .createThread(spaceId):
      ExperimentalPlaceholderView(title: "Create Thread \(spaceId)")
    case .createSpace:
      ExperimentalPlaceholderView(title: "Create Space")
    }
  }
}

struct ExperimentalSheetView: View {
  let sheet: Sheet

  var body: some View {
    switch sheet {
    case .settings:
      NavigationStack {
        SettingsView()
      }
    case .createSpace:
      ExperimentalPlaceholderView(title: "Create Space (Sheet)")
    case .alphaSheet:
      ExperimentalPlaceholderView(title: "Alpha Sheet")
    case let .addMember(spaceId):
      ExperimentalPlaceholderView(title: "Add Member \(spaceId)")
    }
  }
}
