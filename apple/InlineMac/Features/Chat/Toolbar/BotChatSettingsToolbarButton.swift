import InlineKit
import InlineMacUI
import SwiftUI

struct BotChatSettingsToolbarButton: View {
  let coordinator: BotChatSettingsCoordinator
  let toolbarState: ChatToolbarState

  private var anchor: ChatToolbarState.Anchor { .button(.botSettings) }

  var body: some View {
    Button {
      toolbarState.presentBotSettings()
    } label: {
      Label("Agent Settings", systemImage: "slider.horizontal.3")
        .labelStyle(.iconOnly)
    }
    .help("Agent Settings")
    .accessibilityLabel("Agent Settings")
    .onAppear { toolbarState.handleAppear(.botSettings) }
    .onDisappear { toolbarState.handleDisappear(.botSettings) }
    .popover(isPresented: Binding(
      get: { toolbarState.presentation == .botSettings(anchor) },
      set: { isPresented in
        if isPresented {
          toolbarState.presentBotSettings()
        } else if toolbarState.presentation == .botSettings(anchor) {
          toolbarState.dismissPresentation()
        }
      }
    ), arrowEdge: .bottom) {
      BotChatSettingsPopover(coordinator: coordinator)
    }
  }
}
