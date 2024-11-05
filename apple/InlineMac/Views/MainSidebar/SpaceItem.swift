import InlineKit
import InlineUI
import SwiftUI

struct SpaceItem: View {
    @EnvironmentObject var dataManager: DataManager
    
    var space: Space
    
    var body: some View {
        HStack {
            SpaceAvatar(space: space, size: Theme.sidebarIconSize)
                .padding(.trailing, Theme.iconSpacing)
            Text(space.name)
        }.contextMenu {
            // Only creators can delete space for now
            if let creator = space.creator, creator == true {
                Button("Delete Space", role: .destructive) {
                    act(.delete)
                }
            } else {
                Button("Leave Space", role: .destructive) {
                    act(.leave)
                }
            }
        }
    }
    
    enum Action {
        case delete
        case leave
    }
    
    private func act(_ action: Action) {
        Task {
            // TODO:
            switch action {
            case .delete:
                try await dataManager.deleteSpace(spaceId: space.id)
            case .leave:
                try await dataManager.leaveSpace(spaceId: space.id)
            }
        }
    }
}

#Preview {
    SpaceItem(space: Space(name: "Space Name", date: Date()))
        .frame(width: 200)
        .previewsEnvironment(.populated)
}
