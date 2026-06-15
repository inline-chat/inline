import SwiftUI

struct AppearanceSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Theme") {
        Picker("Appearance", selection: $appSettings.appearance) {
          ForEach(AppAppearance.allCases) { appearance in
            Text(appearance.title).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Window") {
        Toggle("Compact toolbar", isOn: Binding(
          get: { appSettings.toolbarStyle == .unifiedCompact },
          set: { appSettings.toolbarStyle = $0 ? .unifiedCompact : .unified }
        ))
      }

      Section("Messages") {
        Picker("Message style", selection: $appSettings.messageRenderStyle) {
          ForEach(MessageRenderStyle.allCases, id: \.self) { style in
            Text(style.title).tag(style)
          }
        }
        .pickerStyle(.segmented)

        Text("Message style applies to newly opened chats.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  AppearanceSettingsDetailView()
}
