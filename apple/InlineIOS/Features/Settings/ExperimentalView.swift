import InlineKit
import InlineIOSUI
import InlineMessageLayout
import SwiftUI

struct ExperimentalView: View {
  @AppStorage(ExperimentalFeatureFlags.newThreadComposerKey)
  private var newThreadComposerEnabled = false

  @AppStorage(EarlyUploadSettings.enabledKey)
  private var earlyUploadsEnabled = true

  @AppStorage(MessageContextMenuFeature.preferenceKey)
  private var customContextMenuEnabled = true

  @AppStorage(TimelineFeature.preferenceKey)
  private var timelineEnabled = true

  @AppStorage(MessageAlbumView.layoutStyleKey)
  private var albumLayout = AlbumLayoutStyle.telegram.rawValue

  var body: some View {
    List {
      // Use the same purpose-based groups as macOS; see AGENTS.md when adding experiments.
      Section {
        SettingsItem(icon: "arrow.up.circle", iconColor: .green, title: "Upload While Writing") {
          Toggle("Upload While Writing", isOn: $earlyUploadsEnabled)
            .labelsHidden()
        }
      } header: {
        Text("Files")
      } footer: {
        Text("Upload While Writing: photos start uploading when you attach them, so they send sooner. Removing one deletes what was uploaded. Off: uploads start when you send.")
      }

      Section {
        SettingsItem(icon: "square.and.pencil", iconColor: .orange, title: "New Thread Composer") {
          Toggle("New Thread Composer", isOn: $newThreadComposerEnabled)
            .labelsHidden()
        }
      } header: {
        Text("Threads")
      } footer: {
        Text("New Thread opens a composer so the thread starts from its first message. Off: New Thread creates an empty thread and opens it.")
      }

      Section {
        SettingsItem(
          icon: "contextualmenu.and.cursorarrow",
          iconColor: .indigo,
          title: "Message Menu Text Selection"
        ) {
          Toggle("Message Menu Text Selection", isOn: $customContextMenuEnabled)
            .labelsHidden()
            .onChange(of: customContextMenuEnabled) { _, enabled in
              if enabled { MessageContextMenuFeature.resetCrashGuard() }
            }
        }
      } header: {
        Text("Messages")
      } footer: {
        Text("Holding a message opens Inline's menu, where you can select and quote part of the text. Turn it off to use the system menu. Reopen the chat after changing it.")
      }

      if SettingsBuildAudience.showsDebugTools {
        Section {
          SettingsItem(
            icon: "list.bullet.rectangle.fill",
            iconColor: .purple,
            title: "New Message List"
          ) {
            Toggle("New Message List", isOn: $timelineEnabled)
              .labelsHidden()
          }
          SettingsItem(
            icon: "square.grid.2x2.fill",
            iconColor: .teal,
            title: "Album Layout"
          ) {
            Picker("Album Layout", selection: $albumLayout) {
              // Islands are the Mac's minimal style.
              ForEach(AlbumLayoutStyle.allCases.filter { $0 != .islands }, id: \.rawValue) { style in
                Text(style.title).tag(style.rawValue)
              }
            }
            .labelsHidden()
          }
        } header: {
          Text("Developer Tools")
        } footer: {
          Text("Album Layout picks how photos sent together are drawn in the next message view. Reopen the chat after changing it.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Experimental") {
  NavigationStack {
    ExperimentalView()
  }
}
