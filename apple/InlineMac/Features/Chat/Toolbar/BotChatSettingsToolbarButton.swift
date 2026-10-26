import InlineKit
import InlineMacUI
import InlineProtocol
import SwiftUI

struct BotChatSettingsToolbarButton: View {
  let coordinator: BotChatSettingsCoordinator
  @ObservedObject var agentThreadModel: AgentThreadToolbarModel
  let toolbarState: ChatToolbarState
  let updateAgentContext: (InlineProtocol.AgentThreadContext) async throws -> Void
  @ObservedObject private var agentWorkStore = AgentWorkStateStore.shared

  private var anchor: ChatToolbarState.Anchor { .button(.botSettings) }

  /// The agent these settings are for: the thread's own agent, else the bot
  /// selected in the popover.
  private var settingsBotUserID: Int64? {
    agentThreadModel.context?.botUserID ?? coordinator.selectedBotID
  }

  /// Output mode applies to bridge v2 agents, which report a runtime.
  private var showsOutputMode: Bool {
    settingsBotUserID.map { agentWorkStore.runtimeBotUserIDs.contains($0) } ?? false
  }

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
      BotChatSettingsPopover(
        coordinator: coordinator,
        showsThreadConfiguration: agentThreadModel.context != nil || showsOutputMode,
        threadConfiguration: {
          VStack(alignment: .leading, spacing: 0) {
            AgentThreadSettingsSection(
              model: agentThreadModel,
              update: updateAgentContext
            )
            if showsOutputMode, let botUserID = settingsBotUserID {
              if agentThreadModel.context != nil { Divider().padding(.horizontal, 12) }
              AgentOutputModeSettingsSection(peer: coordinator.peer, botUserID: botUserID)
            }
          }
        },
        remoteFolderPicker: { hostInstallationID, botUserID, hostLabel in
          guard let parent = NSApp.keyWindow?.parent ?? NSApp.mainWindow ?? NSApp.keyWindow else {
            throw CancellationError()
          }
          toolbarState.dismissPresentation()
          let client = RemoteFilesystemClient(peer: coordinator.peer, botID: botUserID, hostID: hostInstallationID)
          let workspaceID = try await RemoteFolderBrowser.pick(on: parent, hostLabel: hostLabel) { path, after, register in
            let response = try await client.request(path: path, after: after, register: register)
            if case let .workspaceID(workspaceID)? = response.result {
              try await coordinator.prepareRegisteredFolder(workspaceID, botID: botUserID)
            }
            return response
          }
          guard coordinator.selectedBotID == botUserID else { throw CancellationError() }
          toolbarState.presentBotSettings()
          return workspaceID
        },
        localFolderPicker: { hostInstallationID, botUserID, port, capability in
          let panel = NSOpenPanel()
          panel.title = "Pick a Project Folder"
          panel.message = "This folder stays on this Mac and is shared only with your selected agent."
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = false
          guard panel.runModal() == .OK, let folderURL = panel.url else {
            throw CancellationError()
          }
          let workspaceID = try await LocalAgentWorkspaceRegistrar.register(
            folderURL: folderURL,
            hostInstallationID: hostInstallationID,
            botUserID: botUserID,
            port: port,
            capability: capability
          )
          try await coordinator.prepareRegisteredFolder(workspaceID, botID: botUserID)
          return workspaceID
        },
        localFolderPickerAvailable: { hostInstallationID, botUserID, port, capability in
          await LocalAgentWorkspaceRegistrar.isAvailable(
            hostInstallationID: hostInstallationID,
            botUserID: botUserID,
            port: port,
            capability: capability
          )
        }
      )
      .task(id: settingsBotUserID) {
        guard let botUserID = settingsBotUserID else { return }
        await AgentOutputModeSettingsLoader.load(peer: coordinator.peer, botUserID: botUserID)
      }
    }
  }
}
