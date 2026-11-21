#if DEBUG
import AppKit
import InlineKit
import SwiftUI

/// Debug builds only: `--peerinfo-harness` opens one window listing every kind
/// of chat info on an in-memory database, signed in as a fixture user, instead
/// of the app's windows. Nothing reaches the server. `--peerinfo-harness-case
/// ID` selects a case (see `PeerInfoDebugFixture.cases`), `--peerinfo-harness-dark`
/// shows it in dark mode, `--peerinfo-harness-background` leaves focus alone.
@MainActor
enum PeerInfoMacHarness {
  private static var window: NSWindow?

  static func show(dependencies: AppDependencies) {
    if CommandLine.arguments.contains("--peerinfo-harness-dark") {
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    PeerInfoDebugFixture.seed(dependencies.database)
    PeerInfoDebugFixture.seedAgents()
    BotsSettingsDebugFixture.seed()
    let root = PeerInfoMacHarnessView()
      .environment(dependencies: dependencies)
    let controller = NSHostingController(rootView: root)
    let window = NSWindow(contentViewController: controller)
    window.title = "Chat Info Harness"
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 980, height: 860))
    window.center()
    // `--peerinfo-harness-background` shows the window without taking focus,
    // so unattended captures don't swallow someone's typing.
    if CommandLine.arguments.contains("--peerinfo-harness-background") {
      window.orderFrontRegardless()
    } else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
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
      List(selection: $selection) {
        ForEach(PeerInfoDebugFixture.cases) { item in
          Text(item.title).tag(item.id)
        }
        ForEach(BotsSettingsDebugFixture.Case.allCases, id: \.rawValue) { item in
          Text(item.title).tag(item.rawValue)
        }
      }
      .navigationSplitViewColumnWidth(200)
    } detail: {
      if let selection, let botsCase = BotsSettingsDebugFixture.Case(rawValue: selection) {
        BotsSettingsHarnessCase(harnessCase: botsCase)
          .id(selection)
      } else if let item = PeerInfoDebugFixture.cases.first(where: { $0.id == selection }) {
        ChatInfo(peerId: item.peer)
          .id(item.id)
      }
    }
  }
}
/// Settings → Bots in the state a case names (edit mode, a partial failure).
private struct BotsSettingsHarnessCase: View {
  let harnessCase: BotsSettingsDebugFixture.Case
  @State private var model: BotBulkEditModel?

  var body: some View {
    ZStack {
      if let model {
        BotsSettingsDetailView(bulk: model)
      } else {
        ProgressView()
      }
    }
    .task { model = await BotsSettingsDebugFixture.bulkModel(for: harnessCase) }
  }
}
#endif
