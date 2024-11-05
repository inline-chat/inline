import InlineKit
import InlineUI
import SwiftUI

struct SpaceItem: View {
    var space: Space
    
    var body: some View {
        HStack {
            SpaceAvatar(space: space, size: Theme.sidebarIconSize)
                .padding(.trailing, Theme.iconSpacing)
            Text(space.name)
        }.contextMenu {
            // Only creators can delete space for now
            if space.creator == true {
                Button("Delete Space", role: .destructive) {
                    act(.delete)
                }
            } else {
                Button("Leave Space") {
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
                try await ApiClient.shared.deleteSpace(spaceId: space.id)
            case .leave:
                try await ApiClient.shared.leaveSpace(spaceId: space.id)
            }
        }
    }
}

#Preview {
    SpaceItem(space: Space(name: "Space Name", date: Date()))
        .frame(width: 200)
        .previewsEnvironment(.populated)
}
