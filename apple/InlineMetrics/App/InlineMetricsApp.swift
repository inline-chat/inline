import AppKit
import SwiftUI

@MainActor
final class MetricsAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct InlineMetricsApp: App {
  @NSApplicationDelegateAdaptor(MetricsAppDelegate.self) private var delegate
  @State private var store = MetricsStore()

  var body: some Scene {
    Window("Inline Metrics", id: "dashboard") {
      DashboardView(store: store)
        .onOpenURL { url in
          guard url.scheme == "inline-metrics", url.host == "refresh" else { return }
          NSApp.activate(ignoringOtherApps: true)
          Task { await store.refresh() }
        }
    }
    .defaultSize(width: 740, height: 560)
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Metrics") {
        Button("Refresh Metrics") { Task { await store.refresh() } }
          .keyboardShortcut("r").disabled(!store.isSignedIn || store.isBusy)
      }
    }

    MenuBarExtra("Inline Metrics", systemImage: "chart.xyaxis.line") {
      MetricsMenu(store: store)
    }
  }
}

private struct MetricsMenu: View {
  @Environment(\.openWindow) private var openWindow
  let store: MetricsStore

  var body: some View {
    if let metrics = store.snapshot.visibleMetrics(at: Date()) {
      Text("\(metrics.dau.formatted()) active today")
      Text("\(metrics.messagesToday.formatted()) messages today")
      Text(store.snapshot.status(at: Date()))
      Divider()
    }
    Button(store.isSignedIn ? "Open Metrics" : "Sign In…") {
      openWindow(id: "dashboard")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button("Refresh Now") { Task { await store.refresh() } }
      .disabled(!store.isSignedIn || store.isBusy)
    Divider()
    Button("Quit Inline Metrics") { NSApp.terminate(nil) }
  }
}
