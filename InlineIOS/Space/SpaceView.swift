import InlineKit
import InlineUI
import SwiftUI

struct SpaceView: View {
  var spaceId: Int64

  @Environment(\.appDatabase) var database
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var dataManager: DataManager
  @EnvironmentStateObject var fullSpaceViewModel: FullSpaceViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpaceViewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  @State var openCreateThreadSheet = false

  var body: some View {
    VStack {
      List {
        if fullSpaceViewModel.memberChats.count > 0 {
          Section(header: Text("Members")) {
            ForEach(fullSpaceViewModel.memberChats) { item in
              Button {
                nav.push(.chat(peer: .user(id: item.user?.id ?? 0)))
              } label: {
                ChatRowView(item: .space(item))
              }
            }
          }
        }

        if fullSpaceViewModel.chats.count > 0 {
          Section(header: Text("Threads")) {
            ForEach(fullSpaceViewModel.chats, id: \.self) { item in
              Button {
                nav.push(.chat(peer: item.peerId))
              } label: {
                ChatRowView(item: .space(item))
              }
            }
          }
        }
      }
      .listStyle(.plain)
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
    .task {
      do {
        try await dataManager.getDialogs(spaceId: spaceId)

      } catch {
        Log.shared.error("Failed to getPrivateChats", error: error)
      }
    }
  }
}

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
