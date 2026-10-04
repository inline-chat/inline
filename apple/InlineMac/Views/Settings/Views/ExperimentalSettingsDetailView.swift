import Auth
import InlineKit
import InlineUI
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @Environment(\.dependencies) private var dependencies
  @ObservedObject private var auth = Auth.shared
  @AppStorage(ExperimentalFeatureFlags.fileBrowserKey) private var fileBrowserEnabled = false
  @StateObject private var settings = AppSettings.shared
  @AppStorage(ExperimentalFeatureFlags.newThreadAgentPickerKey)
  private var newThreadAgentPickerEnabled = false
  @AppStorage(ExperimentalFeatureFlags.agentActivityKey)
  private var agentActivityEnabled = false

  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false
  @AppStorage(ExperimentalFeatureFlags.macMessageSelectionKey)
  private var messageSelectionEnabled = false
  @AppStorage(ExperimentalFeatureFlags.quickForwardKey)
  private var quickForwardEnabled = false
  @AppStorage(ExperimentalFeatureFlags.richMessageCopyEditingKey)
  private var richMessageCopyEditingEnabled = false
  @AppStorage(ExperimentalMessageListFeature.key)
  private var messageListV2Enabled = false

  var body: some View {
    Form {
      // Keep experiments grouped by purpose; see AGENTS.md before adding a section.
      agentsSection
      messagesSection
      filesSection
      if ExperimentalMessageListFeature.isAvailable {
        developerToolsSection
      }
    }
    .settingsFormStyle()
    .onAppear { _ = ExperimentalFeatureFlags.agentActivityEnabled }
  }

  private var agentsSection: some View {
    Section {
      Toggle(isOn: $agentActivityEnabled) {
        SettingsRowLabel(
          "Agent Activity",
          description: "Show Working with a spinner and expandable agent steps. Requires an opted-in agent and Rich Content Renderer. Restart Inline after changing."
        )
      }
      if #available(macOS 26.0, *) {
        Toggle(isOn: $newThreadAgentPickerEnabled) {
          SettingsRowLabel(
            "New Thread Agent Picker",
            description: "Choose an agent in the new-thread composer and keep it for future threads. Starts with None."
          )
        }
      }
      Toggle(isOn: $settings.richContentRendererEnabled) {
        SettingsRowLabel(
          "Rich Content Renderer",
          description: "Render supported agent Markdown as native rich-content blocks in messages."
        )
      }
      Toggle(isOn: $settings.richTextInlineMathEnabled) {
        SettingsRowLabel(
          "Inline Math Attachments",
          description: "Replace supported inline LaTeX with native formula attachments. Display formulas always render normally."
        )
      }
      Toggle(isOn: $settings.richTextMultiSurfaceSelectionEnabled) {
        SettingsRowLabel(
          "Rich Message Multi-Block Selection",
          description: "Select and copy across text blocks within one rich message."
        )
      }
    } header: {
      SettingsSectionHeader("Agents", subtitle: "Prompt workflows, agent controls, and rich responses.")
    }
  }

  private var messagesSection: some View {
    Section {
      Toggle(isOn: $richMessageCopyEditingEnabled) {
        SettingsRowLabel(
          "Rich Copy & Markdown Editing",
          description: "Preserve formatting when copying messages. Show Markdown syntax when pasting formatted text or editing a message."
        )
      }
      Toggle(isOn: $messageSelectionEnabled) {
        SettingsRowLabel(
          "Select Multiple Messages",
          description: "Select messages to forward or delete together. Right-click a message and choose Select Messages."
        )
      }
      Toggle(isOn: $quickForwardEnabled) {
        SettingsRowLabel(
          "Quick Forward",
          description: "Work in progress. Forward multiple messages with an optional message without opening another chat."
        )
      }
    } header: {
      SettingsSectionHeader("Messages")
    }
  }

  private var filesSection: some View {
    Section {
      Toggle(isOn: $fileBrowserEnabled) {
        SettingsRowLabel("File Browser", description: "Browse files, images, and videos by chat in a separate Files window.")
      }
      .onChange(of: fileBrowserEnabled) { _, enabled in
        if !enabled { FilesWindowController.closeIfOpen() }
      }
      if fileBrowserEnabled, let dependencies {
        Button("Open Files") { FilesWindowController.show(dependencies: dependencies) }
          .disabled(auth.currentUserId == nil)
      }
      Toggle(isOn: $nativeFileDownloadsEnabled) {
        SettingsRowLabel(
          "Native File Downloads",
          description: "Download message documents over encrypted realtime. Other media still use CDN."
        )
      }
    } header: {
      SettingsSectionHeader("Files")
    } footer: {
      Text("Requires a V3 session and server support. Turn off to retry failed downloads using CDN.")
    }
  }

  private var developerToolsSection: some View {
    Section {
      Toggle(isOn: $messageListV2Enabled) {
        SettingsRowLabel(
          "Message List V2 (WIP)",
          description: "Unfinished Debug experiment with known scrolling and performance issues. Applies to newly opened chats."
        )
      }
    } header: {
      SettingsSectionHeader("Developer Tools")
    }
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
