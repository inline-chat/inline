#if DEBUG
import AppKit
import InlineKit
import SwiftUI

/// Debug builds only: `--peerinfo-harness` opens one window listing every kind
/// of chat info on an in-memory database, signed in as a fixture user, instead
/// of the app's windows. Nothing reaches the server. `--peerinfo-harness-case
/// ID` selects a case (see `PeerInfoDebugFixture.cases`), `--peerinfo-harness-dark`
/// shows it in dark mode.
@MainActor
enum PeerInfoMacHarness {
  private static var window: NSWindow?

  static func show(dependencies: AppDependencies) {
    if CommandLine.arguments.contains("--peerinfo-harness-dark") {
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    PeerInfoDebugFixture.seed(dependencies.database)
    PeerInfoDebugFixture.seedAgents()
    let root = PeerInfoMacHarnessView()
      .environment(dependencies: dependencies)
    let controller = NSHostingController(rootView: root)
    let window = NSWindow(contentViewController: controller)
    window.title = "Chat Info Harness"
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 980, height: 860))
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.window = window
  }
}

private struct PeerInfoMacHarnessView: View {
  @State private var selection: String? = {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--peerinfo-harness-case"), index + 1 < arguments.count {
      return arguments[index + 1]
    }
    return PeerInfoDebugFixture.cases.first?.id
  }()

  var body: some View {
    NavigationSplitView {
      List(PeerInfoDebugFixture.cases, selection: $selection) { item in
        Text(item.title).tag(item.id)
      }
      .navigationSplitViewColumnWidth(200)
    } detail: {
      if let item = PeerInfoDebugFixture.cases.first(where: { $0.id == selection }) {
        ChatInfo(peerId: item.peer)
          .id(item.id)
      }
    }
  }
}
#endif
