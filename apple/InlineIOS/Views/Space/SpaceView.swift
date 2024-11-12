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
        if fullSpaceViewModel.members.count > 0 {
          Section(header: Text("Members")) {
            ForEach(fullSpaceViewModel.members) { member in
              MemberView(userId: member.userId)
                .onTapGesture {
                  nav.push(.chat(peer: .user(id: member.userId)))
                }
            }
          }
        }

        if fullSpaceViewModel.chats.count > 0 {
          Section(header: Text("Threads")) {
            ForEach(fullSpaceViewModel.chats, id: \.self) { _ in
              HStack {
                InitialsCircle(firstName: "Thread", lastName: nil, size: 25)
                  .padding(.trailing, 4)
                Text("Thread")
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
              .onTapGesture {
//                                nav.push(.chat(peer: chat.))
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
      ToolbarItem(placement: .principal) {
        HStack(spacing: 2) {
          if let space = fullSpaceViewModel.space {
            InitialsCircle(firstName: space.name, lastName: nil, size: 26)
              .padding(.trailing, 6)
            Text(space.name)
              .font(.title3)
              .fontWeight(.medium)
              .foregroundColor(.primary)
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
    .toolbarRole(.editor)
    .sheet(isPresented: $openCreateThreadSheet) {
      CreateThread(showSheet: $openCreateThreadSheet, spaceId: spaceId)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    }
  }
}

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
