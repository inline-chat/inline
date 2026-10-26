import Auth
import InlineKit
import InlineUI
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @Environment(\.dependencies) private var dependencies
  @ObservedObject private var auth = Auth.shared
  @AppStorage(ExperimentalFeatureFlags.fileBrowserKey) private var fileBrowserEnabled = false
  @AppStorage(ExperimentalFeatureFlags.gridTranscriptionKey)
  private var gridTranscriptionEnabled = false
  @StateObject private var settings = AppSettings.shared
  @AppStorage(ExperimentalFeatureFlags.newThreadAgentPickerKey)
  private var newThreadAgentPickerEnabled = false

  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false
  @AppStorage(ExperimentalFeatureFlags.macMessageSelectionKey)
  private var messageSelectionEnabled = false
  @AppStorage(ExperimentalFeatureFlags.quickForwardKey)
  private var quickForwardEnabled = false
  @AppStorage(ExperimentalFeatureFlags.richMessageCopyEditingKey)
  private var richMessageCopyEditingEnabled = false

  var body: some View {
    Form {
      // Keep experiments grouped by purpose; see AGENTS.md before adding a section.
      agentsSection
      messagesSection
      gridSection
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
      Toggle(isOn: $settings.richTextMultiSurfaceSelectionEnabled) {
        SettingsRowLabel(
          .richMessageMultiBlockSelection,
          description: "Select and copy across text blocks within one rich message."
        )
      }
      .settingsSearchAnchor(.richMessageMultiBlockSelection)
    } header: {
      SettingsSectionHeader("Agents", subtitle: "Prompt workflows, agent controls, and rich responses.")
    }
  }

  private var messagesSection: some View {
    Section {
      Toggle(isOn: $richMessageCopyEditingEnabled) {
        SettingsRowLabel(
          .richCopyMarkdownEditing,
          description: "Preserve formatting when copying messages. Show Markdown syntax when pasting formatted text or editing a message."
        )
      }
      .settingsSearchAnchor(.richCopyMarkdownEditing)
      Toggle(isOn: $messageSelectionEnabled) {
        SettingsRowLabel(
          .selectMultipleMessages,
          description: "Select messages to forward or delete together. Right-click a message and choose Select Messages."
        )
      }
      .settingsSearchAnchor(.selectMultipleMessages)
      Toggle(isOn: $quickForwardEnabled) {
        SettingsRowLabel(
          .quickForward,
          description: "Work in progress. Forward multiple messages with an optional message without opening another chat."
        )
      }
      .settingsSearchAnchor(.quickForward)
    } header: {
      SettingsSectionHeader("Messages")
    }
  }

  private var gridSection: some View {
    Section {
      Toggle(isOn: $gridTranscriptionEnabled) {
        SettingsRowLabel(
          .gridTranscription,
          description: "Try meeting transcripts in Grid. The interface is experimental and will be redesigned."
        )
      }
      .settingsSearchAnchor(.gridTranscription)
    } header: {
      SettingsSectionHeader("Grid")
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
