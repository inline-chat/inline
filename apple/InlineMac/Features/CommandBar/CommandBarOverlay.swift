import AppKit
import SwiftUI

struct CommandBar: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.commandBarRegistry) private var commandRegistry
  @Environment(\.nav) private var nav
  @State private var viewModel: QuickSearchViewModel?
  @State private var panelController: CommandBarPanelController?

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onHostingWindowChange { window in
        updateController()
        panelController?.setOwnerWindow(window)
        panelController?.setPresented(nav.cmdKVisible)
      }
      .onAppear {
        updateController()
      }
      .onChange(of: nav.cmdKVisible) { _, visible in
        if visible {
          updateController()
        }
        panelController?.setPresented(visible)
      }
      .onDisappear {
        panelController?.invalidate()
        panelController = nil
        viewModel = nil
      }
  }

  private func updateController() {
    guard let dependencies else { return }
    let model: QuickSearchViewModel
    if let viewModel {
      model = viewModel
    } else {
      model = QuickSearchViewModel(dependencies: dependencies)
      viewModel = model
    }
    model.attach(nav3: nav, commandRegistry: commandRegistry) {
      dependencies.appBridge.openSettings(dependencies: dependencies)
    }
    if panelController == nil {
      panelController = CommandBarPanelController(
        viewModel: model,
        nav: nav,
        dependencies: dependencies
      )
    }
  }
}
