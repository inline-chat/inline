import SwiftUI

struct SidebarSectionHeader: View {
  let imageSystemName: String
  let title: String
  let action: () -> Void

  init(
    imageSystemName: String,
    title: String,
    action: @escaping () -> Void
  ) {
    self.imageSystemName = imageSystemName
    self.title = title
    self.action = action
  }

  var body: some View {
    Button {
      action()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: Theme.sidebarIconSpacing) {
        Image(systemName: imageSystemName)
          .font(.title3)
          .foregroundStyle(.tertiary)
          .frame(width: Theme.sidebarIconSize, alignment: .center)
        Text(title)
          .font(Theme.sidebarItemFont)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .frame(height: 32)
  }
}

#Preview {
  NavigationSplitView {
    List {
      Section {
        // item
        Text("Item 1")
          .frame(maxWidth: .infinity)
      } header: {
        SidebarSectionHeader(
          imageSystemName: "person.2.fill",
          title: "Contacts"
        ) {
          print("Button tapped")
        }
        
      }
    }
    .listStyle(.sidebar)
  } detail: {
    Text("Welcome.")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding()
  }
}
