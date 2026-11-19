import InlineKit
import SwiftUI
import UIKit

enum ChatInfoTab: CaseIterable, Hashable, Identifiable {
  case info
  case media
  case voice
  case files
  case links

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .info: "Info"
    case .media: "Media"
    case .voice: "Voice"
    case .files: "Files"
    case .links: "Links"
    }
  }
}

/// The chat info section switcher: a centered capsule of tabs with a pill that slides to
/// the selection. It scrolls sideways inside the capsule when the tabs don't fit.
///
/// Liquid Glass on iOS 26, a material capsule before. Selecting another tab plays a
/// selection haptic; tapping the selected one calls `onReselect` (scroll to top).
struct ChatInfoTabBar<Tab: Hashable & Identifiable>: View {
  let tabs: [Tab]
  @Binding var selection: Tab
  let title: (Tab) -> String
  var onReselect: ((Tab) -> Void)?

  init(
    tabs: [Tab],
    selection: Binding<Tab>,
    title: @escaping (Tab) -> String,
    onReselect: ((Tab) -> Void)? = nil
  ) {
    self.tabs = tabs
    _selection = selection
    self.title = title
    self.onReselect = onReselect
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      track(scrolls: false)
      track(scrolls: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isTabBar)
    .accessibilityLabel("Sections")
  }

  @ViewBuilder
  private func track(scrolls: Bool) -> some View {
    let items = ChatInfoTabBarItems(tabs: tabs, selection: $selection, title: title, onReselect: onReselect)
    if scrolls {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          items
        }
        .scrollIndicators(.hidden)
        .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
        .onChange(of: selection) { _, newSelection in
          withAnimation(.smooth(duration: 0.3)) {
            proxy.scrollTo(newSelection.id, anchor: .center)
          }
        }
      }
      .chatInfoTabBarTrack()
    } else {
      items
        .fixedSize()
        .chatInfoTabBarTrack()
    }
  }
}

extension ChatInfoTabBar where Tab == ChatInfoTab {
  init(tabs: [ChatInfoTab], selection: Binding<ChatInfoTab>, onReselect: ((ChatInfoTab) -> Void)? = nil) {
    self.init(tabs: tabs, selection: selection, title: { String(localized: $0.title) }, onReselect: onReselect)
  }
}

extension ChatInfoTabBar where Tab == PeerInfoTab {
  init(tabs: [PeerInfoTab], selection: Binding<PeerInfoTab>, onReselect: ((PeerInfoTab) -> Void)? = nil) {
    self.init(tabs: tabs, selection: selection, title: \.title, onReselect: onReselect)
  }
}

private struct ChatInfoTabBarItems<Tab: Hashable & Identifiable>: View {
  let tabs: [Tab]
  @Binding var selection: Tab
  let title: (Tab) -> String
  let onReselect: ((Tab) -> Void)?

  @Namespace private var pill
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 2) {
      ForEach(tabs) { tab in
        let isSelected = tab == selection
        Button {
          select(tab)
        } label: {
          Text(title(tab))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background {
              if isSelected {
                ChatInfoTabBarPill()
                  .matchedGeometryEffect(id: "pill", in: pill)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(tab.id)
        // Inside the `.isTabBar` container VoiceOver reads each as "Media, tab, 3 of 6".
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(4)
  }

  private func select(_ tab: Tab) {
    guard tab != selection else {
      onReselect?(tab)
      return
    }
    UISelectionFeedbackGenerator().selectionChanged()
    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
      selection = tab
    }
  }
}

/// The selection pill: a lifted fill on glass, the segmented-control thumb before iOS 26.
private struct ChatInfoTabBarPill: View {
  var body: some View {
    if #available(iOS 26.0, *) {
      Capsule()
        .fill(Color(uiColor: .label).opacity(0.1))
    } else {
      Capsule()
        .fill(Color(uiColor: .systemBackground))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
  }
}

private extension View {
  /// The capsule behind the tabs, clipping them when they scroll.
  @ViewBuilder
  func chatInfoTabBarTrack() -> some View {
    if #available(iOS 26.0, *) {
      clipShape(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
    } else {
      clipShape(Capsule())
        .background(.regularMaterial, in: Capsule())
    }
  }
}
