import InlineKit
import InlineUI
import SwiftUI

struct SpaceView: View {
  var spaceId: Int64

  @Environment(\.appDatabase) var database
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var data: DataManager
  @EnvironmentStateObject var fullSpaceViewModel: FullSpaceViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpaceViewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  @State var openCreateThreadSheet = false
  @State var openAddMemberSheet = false

  var body: some View {
    VStack {
      List {
        Section {
          ForEach(getCombinedItems(), id: \.id) { item in
            combinedItemRow(for: item)
          }
        }
      }
      .listStyle(.plain)
      .animation(.default, value: fullSpaceViewModel.chats)
      .animation(.default, value: fullSpaceViewModel.memberChats)
    }
    .frame(maxWidth: .infinity)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      Group {
        ToolbarItem(id: "Space", placement: .topBarLeading) {
          HStack {
            if let space = fullSpaceViewModel.space {
              InitialsCircle(firstName: space.name, lastName: nil, size: 26)
                .padding(.trailing, 4)

              VStack(alignment: .leading) {
                Text(space.name)
                  .font(.title3)
                  .fontWeight(.semibold)
              }
            }
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button(action: {
              openCreateThreadSheet = true
            }) {
              Text("Create Thread")
            }
            Button(action: {
              openAddMemberSheet = true
            }) {
              Text("Add Member")
            }
          } label: {
            Image(systemName: "ellipsis")
              .tint(Color.secondary)
          }
        }
      }
    }
    .toolbarRole(.editor)
    .sheet(isPresented: $openCreateThreadSheet) {
      CreateThread(showSheet: $openCreateThreadSheet, spaceId: spaceId)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    }
    .sheet(isPresented: $openAddMemberSheet) {
      AddMember(showSheet: $openAddMemberSheet, spaceId: spaceId)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    }
    .task {
      do {
        try await data.getDialogs(spaceId: spaceId)

      } catch {
        Log.shared.error("Failed to getPrivateChats", error: error)
      }
    }
    .onAppear {
      Task {
        try await data.getSpace(spaceId: spaceId)
      }
    }
  }

  // MARK: - Helper Methods

  private func getCombinedItems() -> [CombinedItem] {
    let memberItems = fullSpaceViewModel.memberChats.map { CombinedItem.member($0) }
    let chatItems = fullSpaceViewModel.chats.map { CombinedItem.chat($0) }

    return (memberItems + chatItems).sorted { item1, item2 in

      let pinned1 = item1.isPinned
      let pinned2 = item2.isPinned
      if pinned1 != pinned2 { return pinned1 }

      return item1.date > item2.date
    }
  }

  @ViewBuilder
  private func combinedItemRow(for item: CombinedItem) -> some View {
    switch item {
    case .member(let memberChat):
      Button {
        nav.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
      } label: {
        ChatRowView(item: .space(memberChat))
      }

    case .chat(let chat):
      Button {
        nav.push(.chat(peer: chat.peerId))
      } label: {
        ChatRowView(item: .space(chat))
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button {
          Task {
            try await data.updateDialog(
              peerId: chat.peerId,
              pinned: !(chat.dialog.pinned ?? false)
            )
          }
        } label: {
          Image(systemName: chat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
      }
      .tint(.indigo)
      .listRowBackground(chat.dialog.pinned ?? false ? Color(.systemGray6).opacity(0.5) : .clear)
    }
  }
}

// MARK: - CombinedItem Enum

private enum CombinedItem: Identifiable {
  case member(SpaceChatItem)
  case chat(SpaceChatItem)

  var id: Int64 {
    switch self {
    case .member(let item): return item.user?.id ?? 0
    case .chat(let item): return item.id
    }
  }

  var date: Date {
    switch self {
    case .member(let item): return item.message?.date ?? item.chat?.date ?? Date()
    case .chat(let item): return item.message?.date ?? item.chat?.date ?? Date()
    }
  }

  var isPinned: Bool {
    switch self {
    case .member(let item): return item.dialog.pinned ?? false
    case .chat(let item): return item.dialog.pinned ?? false
    }
  }
}

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
