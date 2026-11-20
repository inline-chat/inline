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

  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false
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
      Toggle(isOn: $settings.richContentRendererEnabled) {
        SettingsRowLabel(
          .richContentRenderer,
          description: "Render supported agent Markdown as native rich-content blocks in messages."
        )
      }
      .settingsSearchAnchor(.richContentRenderer)
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
      Toggle(isOn: $nativeFileDownloadsEnabled) {
        SettingsRowLabel(
          .nativeFileDownloads,
          description: "Download documents and videos over the realtime connection."
        )
      }
      .settingsSearchAnchor(.nativeFileDownloads)
      .disabled(!nativeFileDownloadsAvailable && !nativeFileDownloadsEnabled)
    } header: {
      SettingsSectionHeader("Files")
    } footer: {
      if nativeFileDownloadsAvailable {
        Text("Other media use standard downloads. Turn off to use standard downloads for everything.")
      } else if nativeFileDownloadsEnabled {
        Text("Sign in to use native file downloads. Turn off to clear the saved preference.")
      } else {
        Text("Sign in to use native file downloads.")
      }
    }
  }

  private var nativeFileDownloadsAvailable: Bool {
    // Observe the existing auth owner so the control updates after a session change.
    auth.getIsLoggedIn()
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
