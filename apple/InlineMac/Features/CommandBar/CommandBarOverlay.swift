import AppKit
import SwiftUI

struct CommandBar: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @State private var viewModel: QuickSearchViewModel?

  var body: some View {
    Group {
      if nav.cmdKVisible, let viewModel, let dependencies {
        CommandBarOverlay(viewModel: viewModel)
          .environment(dependencies: dependencies)
          .padding(.top, 56)
          .zIndex(1)
      }
    }
    .onAppear {
      updateViewModel()
    }
    .onChange(of: nav.cmdKVisible) { _, visible in
      guard visible else { return }
      updateViewModel()
      viewModel?.requestFocus()
    }
  }

  private func updateViewModel() {
    guard let dependencies else { return }
    let model: QuickSearchViewModel
    if let viewModel {
      model = viewModel
    } else {
      model = QuickSearchViewModel(dependencies: dependencies)
      viewModel = model
    }
    model.attach(nav3: nav) {
      SettingsWindowController.show(using: dependencies)
    }
  }
}

private struct CommandBarOverlay: View {
  @Environment(\.keyMonitor) private var keyMonitor
  @Environment(\.nav) private var nav
  @ObservedObject var viewModel: QuickSearchViewModel
  @State private var arrowUnsubscriber: (() -> Void)?
  @State private var vimUnsubscriber: (() -> Void)?
  @State private var returnUnsubscriber: (() -> Void)?
  @State private var localKeyMonitor: Any?

  var body: some View {
    QuickSearchOverlayView(
      viewModel: viewModel,
      onDismiss: {
        close()
      },
      onSizeChange: { _ in }
    )
    .onAppear {
      viewModel.requestFocus()
      installKeyHandling()
    }
    .onDisappear {
      viewModel.reset()
      removeKeyHandling()
    }
    .onEscapeKey("swiftui_command_bar_escape") {
      close()
    }
    .onExitCommand {
      close()
    }
    .onMoveCommand { direction in
      switch direction {
      case .up:
        viewModel.moveSelection(isForward: false)
      case .down:
        viewModel.moveSelection(isForward: true)
      default:
        break
      }
    }
  }

  private func close() {
    nav.closeCommandBar()
  }

  private func installKeyHandling() {
    if keyMonitor != nil {
      installKeyMonitorHandlers()
      return
    }

    guard localKeyMonitor == nil else { return }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event) ? nil : event
    }
  }

  private func installKeyMonitorHandlers() {
    guard let keyMonitor else { return }
    guard arrowUnsubscriber == nil else { return }

    arrowUnsubscriber = keyMonitor.addHandler(for: .verticalArrowKeys, key: "swiftui_command_bar_arrows") { event in
      handleArrow(event)
    }
    vimUnsubscriber = keyMonitor.addHandler(for: .vimNavigation, key: "swiftui_command_bar_vim") { event in
      handleVim(event)
    }
    returnUnsubscriber = keyMonitor.addHandler(for: .returnKey, key: "swiftui_command_bar_return") { _ in
      activateSelection()
    }
  }

  private func removeKeyHandling() {
    arrowUnsubscriber?()
    arrowUnsubscriber = nil
    vimUnsubscriber?()
    vimUnsubscriber = nil
    returnUnsubscriber?()
    returnUnsubscriber = nil

    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
  }

  private func handle(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 126, 125:
      handleArrow(event)
      return true
    case 36:
      activateSelection()
      return true
    default:
      break
    }

    if event.modifierFlags.contains(.control),
       let char = event.charactersIgnoringModifiers?.lowercased(),
       ["j", "k", "n", "p"].contains(char)
    {
      handleVim(event)
      return true
    }

    return false
  }

  private func handleArrow(_ event: NSEvent) {
    switch event.keyCode {
    case 126:
      viewModel.moveSelection(isForward: false)
    case 125:
      viewModel.moveSelection(isForward: true)
    default:
      break
    }
  }

  private func handleVim(_ event: NSEvent) {
    guard let char = event.charactersIgnoringModifiers?.lowercased() else { return }
    switch char {
    case "k", "p":
      viewModel.moveSelection(isForward: false)
    case "j", "n":
      viewModel.moveSelection(isForward: true)
    default:
      break
    }
  }

  private func activateSelection() {
    if viewModel.activateSelection() {
      close()
    }
  }
}
