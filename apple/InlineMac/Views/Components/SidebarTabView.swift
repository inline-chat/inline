import SwiftUI

struct SidebarTabView<Tab: Hashable>: View {
  let tabs: [SidebarTabView.TabItem<Tab>]
  let selected: Tab
  let onSelect: (Tab) -> Void
  let showDivider: Bool
  let height: CGFloat

  struct TabItem<Tab: Hashable>: Identifiable {
    var id: Tab { value }
    let value: Tab
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey?
    let fontSize: CGFloat

    init(value: Tab, systemImage: String, fontSize: CGFloat = 16, accessibilityLabel: LocalizedStringKey? = nil) {
      self.value = value
      self.systemImage = systemImage
      self.fontSize = fontSize
      self.accessibilityLabel = accessibilityLabel
    }
  }

  init(
    tabs: [SidebarTabView.TabItem<Tab>],
    selected: Tab,
    showDivider: Bool = true,
    height: CGFloat = 42,
    onSelect: @escaping (Tab) -> Void
  ) {
    self.tabs = tabs
    self.selected = selected
    self.showDivider = showDivider
    self.height = height
    self.onSelect = onSelect
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      HStack(spacing: 0) {
        Spacer()
        ForEach(tabs) { tab in
          SidebarTabButton(
            systemImage: tab.systemImage,
            isActive: tab.value == selected,
            fontSize: tab.fontSize,
            accessibilityLabel: tab.accessibilityLabel
          ) {
            onSelect(tab.value)
          }
        }
        Spacer()
      }
      .frame(height: height)
      if showDivider {
        Divider().opacity(0.4).frame(maxHeight: 1).offset(y: -height / 2 + 1)
      }
    }
  }
}

#Preview {
  enum Tab: String, Hashable { case archive, inbox, members }
  return SidebarTabView<Tab>(
    tabs: [
      .init(value: .archive, systemImage: "archivebox.fill"),
      .init(value: .inbox, systemImage: "bubble.left.and.bubble.right.fill", fontSize: 15),
      .init(value: .members, systemImage: "person.2.fill"),
    ],
    selected: .inbox,
    onSelect: { _ in }
  )
  .background(Color(.windowBackgroundColor))
  .frame(height: 42)
  .padding()
}
