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
  @AppStorage(SidebarAgents.rowNewThreadButtonKey)
  private var agentRowNewThreadEnabled = false

  @AppStorage(ExperimentalFeatureFlags.quickForwardKey)
  private var quickForwardEnabled = false

  var body: some View {
    Form {
      // Keep experiments grouped by purpose; see AGENTS.md before adding a section.
      agentsSection
      messagesSection
      filesSection
    }
    .settingsFormStyle()
  }

  private var agentsSection: some View {
    Section {
      if #available(macOS 26.0, *) {
        Toggle(isOn: $newThreadAgentPickerEnabled) {
          SettingsRowLabel(
            .newThreadAgentPicker,
            description: "Choose an agent in the new-thread composer and keep it for future threads. Starts with None."
          )
        }
        .settingsSearchAnchor(.newThreadAgentPicker)
      }
      Toggle(isOn: $agentRowNewThreadEnabled) {
        SettingsRowLabel(
          .sidebarAgentRowNewThread,
          description: "Show a + on agent chats in the sidebar that starts a new thread with the agent."
        )
      }
      .settingsSearchAnchor(.sidebarAgentRowNewThread)
      Toggle(isOn: $settings.richTextInlineMathEnabled) {
        SettingsRowLabel(
          .inlineMathAttachments,
          description: "Replace supported inline LaTeX with native formula attachments. Display formulas always render normally."
        )
      }
      .settingsSearchAnchor(.inlineMathAttachments)
      Toggle(isOn: $settings.messageWidgetsEnabled) {
        SettingsRowLabel(
          .messageWidgets,
          description: "Show charts, mockups and other HTML that agents send as live widgets in messages, sandboxed with no network access."
        )
      }
      .settingsSearchAnchor(.messageWidgets)
    } header: {
      SettingsSectionHeader("Agents", subtitle: "Prompt workflows, agent controls, and rich responses.")
    }
  }

  private var messagesSection: some View {
    Section {
      Toggle(isOn: $quickForwardEnabled) {
        SettingsRowLabel(
          .quickForward,
          description: "Work in progress. Forward multiple messages with an optional message without opening another chat."
        )
      }
      .settingsSearchAnchor(.quickForward)
      Toggle(isOn: $settings.stableChatRouteEnabled) {
        SettingsRowLabel(
          .stableChatRoute,
          description: "Keep the chat view and its toolbar in place when switching chats instead of rebuilding them."
        )
      }
      .settingsSearchAnchor(.stableChatRoute)
      Toggle(isOn: $settings.coreTextMessageTextEnabled) {
        SettingsRowLabel(
          .coreTextMessageText,
          description: "Draw message text with Inline's own text renderer instead of the system text view, for faster scrolling. Rich messages are unchanged."
        )
      }
      .settingsSearchAnchor(.coreTextMessageText)
      Toggle(isOn: $settings.timelineMessageListEnabled) {
        SettingsRowLabel(
          .timelineMessageList,
          description: "A rewritten message list: trackpad scrolling that matches the system, no jumps when history loads, agent replies that grow a line at a time, and messages, composer and list moving in one animation."
        )
      }
      .settingsSearchAnchor(.timelineMessageList)
    } header: {
      SettingsSectionHeader("Messages")
    }
  }

  private var filesSection: some View {
    Section {
      Toggle(isOn: $fileBrowserEnabled) {
        SettingsRowLabel(.fileBrowser, description: "Browse files, images, and videos by chat in a separate Files window.")
      }
      .settingsSearchAnchor(.fileBrowser)
      .onChange(of: fileBrowserEnabled) { _, enabled in
        if !enabled { FilesWindowController.closeIfOpen() }
      }
      if fileBrowserEnabled, let dependencies {
        Button("Open Files") { FilesWindowController.show(dependencies: dependencies) }
          .disabled(auth.currentUserId == nil)
      }
    } header: {
      SettingsSectionHeader("Files")
    }
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
