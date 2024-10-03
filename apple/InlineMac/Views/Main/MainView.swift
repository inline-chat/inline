import SwiftUI

struct MainView: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel

    var body: some View {
        NavigationSplitView {
            List {
                Text("Hi")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 380)
        } detail: {
            Text("Context")
        }
        
    }
}
