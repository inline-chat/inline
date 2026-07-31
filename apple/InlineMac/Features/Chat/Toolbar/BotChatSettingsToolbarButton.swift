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
      BotChatSettingsPopover(coordinator: coordinator) { hostInstallationID, botUserID, port, capability in
        let panel = NSOpenPanel()
        panel.title = "Pick a Project Folder"
        panel.message = "This folder stays on this Mac and is shared only with your selected agent."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folderURL = panel.url else {
          throw CancellationError()
        }
        return try await LocalAgentWorkspaceRegistrar.register(
          folderURL: folderURL,
          hostInstallationID: hostInstallationID,
          botUserID: botUserID,
          port: port,
          capability: capability
        )
      } localFolderPickerAvailable: { hostInstallationID, botUserID, port, capability in
        await LocalAgentWorkspaceRegistrar.isAvailable(
          hostInstallationID: hostInstallationID,
          botUserID: botUserID,
          port: port,
          capability: capability
        )
      }
    }
  }
}
