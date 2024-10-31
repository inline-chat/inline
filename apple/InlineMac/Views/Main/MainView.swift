import InlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel
    @EnvironmentObject var ws: WebSocketManager

    var body: some View {
        NavigationSplitView {
            List {}
                .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 380)
                .safeAreaInset(edge: .top, content: {
                    Text("Connection state : \(ws.connectionState)")
                })

        } detail: {
            Text("You're logged in!")
        }
    }
}
