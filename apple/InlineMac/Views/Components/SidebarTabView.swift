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
    let label: LocalizedStringKey?
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey?
    let fontSize: CGFloat

    init(
      value: Tab,
      label: LocalizedStringKey? = nil,
      systemImage: String,
      fontSize: CGFloat = 16,
      accessibilityLabel: LocalizedStringKey? = nil
    ) {
      self.value = value
      self.label = label
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
            label: tab.label,
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
      .overlay(alignment: .top) {
        if showDivider {
          Divider().opacity(0.4)
        }
      }
    }
  }
}

#Preview {
  enum Tab: String, Hashable { case archive, inbox, members }
  return SidebarTabView<Tab>(
    tabs: [
      .init(value: .archive, label: "Archive", systemImage: "archivebox.fill"),
      .init(value: .inbox, label: "Inbox", systemImage: "bubble.left.and.bubble.right.fill", fontSize: 15),
      .init(value: .members, label: "Members", systemImage: "person.2.fill"),
    ],
    selected: .inbox,
    onSelect: { _ in }
  )
  .background(Color(.windowBackgroundColor))
  .frame(height: 42)
  .padding()
}
