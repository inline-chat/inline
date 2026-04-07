import InlineKit
import RealtimeV2
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()

  var body: some View {
    Form {
      Section("Experimental") {
        Toggle("Enable new Mac UI", isOn: $appSettings.enableNewMacUI)
        Toggle("Enable voice messages", isOn: $appSettings.enableVoiceMessages)
        Toggle("Enable reply thread", isOn: $appSettings.enableReplyThreadMenuItems)
        Picker("Message style", selection: $appSettings.messageRenderStyle) {
          ForEach(MessageRenderStyle.allCases, id: \.self) { style in
            Text(style.title).tag(style)
          }
        }
        .pickerStyle(.segmented)
        Toggle("Enable sync message updates", isOn: $enableSyncMessageUpdates)
        Text("Message style applies to newly opened chats. Voice features and sync changes may require an app restart.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear {
      enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()
    }
    .onChange(of: enableSyncMessageUpdates) { _, _ in
      Task { await realtimeV2.setEnableSyncMessageUpdates(enableSyncMessageUpdates) }
    }
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
