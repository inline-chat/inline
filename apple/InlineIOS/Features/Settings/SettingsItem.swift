import SwiftUI

struct SettingsItem<TrailingContent: View>: View {
  let icon: String
  let iconColor: Color
  let title: String
  let trailingContent: () -> TrailingContent
  
  init(
    icon: String,
    iconColor: Color,
    title: String,
    @ViewBuilder trailingContent: @escaping () -> TrailingContent = { EmptyView() }
  ) {
    self.icon = icon
    self.iconColor = iconColor
    self.title = title
    self.trailingContent = trailingContent
  }
  
  var body: some View {
    HStack {
      Image(systemName: icon)
        .font(.callout)
        .foregroundColor(.white)
        .frame(width: 25, height: 25)
        .background(iconColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
      
      Text(title)
        .foregroundColor(.primary)
        .padding(.leading, 4)
      
      Spacer()
      
      trailingContent()
    }
    .padding(.vertical, 2)
  }
}

// Convenience initializer for items without trailing content
extension SettingsItem where TrailingContent == EmptyView {
  init(icon: String, iconColor: Color, title: String) {
    self.init(icon: icon, iconColor: iconColor, title: title, trailingContent: { EmptyView() })
  }
}

#Preview("Settings Item") {
  List {
    Section {
      SettingsItem(
        icon: "camera.fill",
        iconColor: .orange,
        title: "Change Profile Photo"
      )
      
      SettingsItem(
        icon: "app.connected.to.app.below.fill",
        iconColor: .purple,
        title: "Integrations"
      )
      
      SettingsItem(
        icon: "eraser.fill",
        iconColor: .red,
        title: "Clear Cache"
      ) {
        ProgressView()
          .padding(.trailing, 8)
      }
    }
  }
  .listStyle(.insetGrouped)
}