import SwiftUI

struct MainWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(action: openHelpWebsite) {
                Text("Help")
            }
            
            Divider()
            
            Button(action: openX) {
                Text("Updates on X")
            }
        }
    }
    
    private func openHelpWebsite() {
        NSWorkspace.shared.open(URL(string: "https://inline.chat/")!)
    }
    
    private func openX() {
        NSWorkspace.shared.open(URL(string: "https://x.com/inline_chat")!)
    }
}
