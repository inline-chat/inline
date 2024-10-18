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
            if let members = fullSpaceViewModel.members {
                List(members) { member in
                    MemberView(userId: member.userId)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 8) {
                    Button(action: {
                        nav.popToRoot()
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.secondary)
                            .font(.body)
                    }

                    if let space = fullSpaceViewModel.space {
                        Text(space.name)
                            .font(.headline)
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
