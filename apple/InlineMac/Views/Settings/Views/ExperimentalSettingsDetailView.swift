import InlineKit
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Experimental") {
        Toggle("Enable voice messages", isOn: $appSettings.enableVoiceMessages)
        Toggle("Enable reply thread", isOn: $appSettings.enableReplyThreadMenuItems)
        Toggle("Sidebar as Inbox", isOn: $appSettings.sidebarAsInbox)
        Picker("Message style", selection: $appSettings.messageRenderStyle) {
          ForEach(MessageRenderStyle.allCases, id: \.self) { style in
            Text(style.title).tag(style)
          }
        }
        .pickerStyle(.segmented)
        Text("Message style applies to newly opened chats. Voice features may require an app restart.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
