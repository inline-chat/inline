import SwiftUI

// SwiftFormat requires indented cases; SwiftLint's default alignment rule disagrees.
// swiftlint:disable switch_case_alignment
/// A sidebar-only presentation choice. It never owns or changes detail navigation.
enum IPadSidebarScope: String, CaseIterable, Identifiable {
  case allChats
  case open

  var id: Self {
    self
  }

  var title: LocalizedStringResource {
    switch self {
      case .allChats: "All Chats"
      case .open: "Open"
    }
  }

  var accessibilityTitle: LocalizedStringResource {
    switch self {
      case .allChats: "All Chats"
      case .open: "Open Chats"
    }
  }

  var homeTab: ExperimentalHomeTab {
    switch self {
      case .allChats: .allChats
      case .open: .inbox
    }
  }
}

// swiftlint:enable switch_case_alignment

/// Uses Apple's native iPad appearance on every supported lane. iPadOS 27 adds
/// tab semantics for assistive technologies while retaining segmented visuals.
struct IPadSidebarSwitcher: View {
  @Binding var selection: IPadSidebarScope

  var body: some View {
    styledPicker
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
  }

  @ViewBuilder
  private var styledPicker: some View {
    #if compiler(>=6.4)
    if #available(iOS 27.0, *) {
      picker.pickerStyle(.tabs)
    } else {
      picker.pickerStyle(.segmented)
    }
    #else
    picker.pickerStyle(.segmented)
    #endif
  }

  private var picker: some View {
    Picker("Chat List", selection: $selection) {
      ForEach(IPadSidebarScope.allCases) { scope in
        Text(scope.title)
          .tag(scope)
          .accessibilityLabel(Text(scope.accessibilityTitle))
      }
    }
    .labelsHidden()
    .accessibilityIdentifier("iPadChatListFilter")
  }
}
