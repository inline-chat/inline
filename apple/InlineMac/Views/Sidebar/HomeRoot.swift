import SwiftUI

struct HomeRoot: View {
  @EnvironmentObject var window: MainWindowViewModel

  var body: some View {
    if #available(macOS 15.0, *) {
      content
//        .toolbar(.hidden, for: .windowToolbar)
//        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
//        .toolbar(removing: .title)
    } else {
      content
    }
  }

  var content: some View {
    Text("")
      .padding()
      .navigationTitle("")
  }
}
