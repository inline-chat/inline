import SwiftUI
import InlineKit

struct HomeSidebar: View {
    @EnvironmentObject var ws: WebSocketManager
    
    var body: some View {
        List {
            NavigationLink(destination: Text("Home")) {
                Label("Home", systemImage: "house")
            }
            NavigationLink(destination: Text("Profile")) {
                Label("Profile", systemImage: "person")
            }
            
            SpaceItem()
        }
        .listStyle(SidebarListStyle())
        .safeAreaInset(edge: .top, content: {
            VStack(alignment: .leading) {
                SelfUser()
                Text("Connection state : \(ws.connectionState)")
            }
        })
    }
}

#Preview {
    NavigationSplitView {
        HomeSidebar()
            .previewsEnvironment(.populated)
    } detail: {
        Text("Welcome.")
    }
}
