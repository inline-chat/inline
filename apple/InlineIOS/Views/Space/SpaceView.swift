import InlineKit
import SwiftUI

struct SpaceView: View {
    var spaceId: Int64

    @Environment(\.appDatabase) var database
    @EnvironmentObject var nav: Navigation

    @EnvironmentStateObject var fullSpaceViewModel: FullSpaceViewModel

    init(spaceId: Int64) {
        self.spaceId = spaceId
        _fullSpaceViewModel = EnvironmentStateObject { env in
            FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
        }
    }

    var body: some View {
        VStack {
            List {
                if let members = fullSpaceViewModel.members {
                    Section(header: Text("Members")) {
                        ForEach(members) { member in
                            MemberView(userId: member.userId)
                        }
                    }
                }

                if let chats = fullSpaceViewModel.chats {
                    Section(header: Text("Threads")) {
                        ForEach(chats) { chat in
                            Text(chat.title ?? "Thread")
                                .onTapGesture {
                                    nav.push(.chat(id: chat.id))
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
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 2) {
                    Button(action: {
                        nav.popToRoot()
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }

                    if let space = fullSpaceViewModel.space {
                        Text(space.name)
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

#Preview {
    SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
