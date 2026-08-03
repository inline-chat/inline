import SwiftUI

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

struct ChatInfoTabBar: View {
  let tabs: [ChatInfoTab]
  @Binding var selection: ChatInfoTab

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        ChatInfoTabItems(tabs: tabs, selection: $selection)
          .padding(.horizontal, 16)
      }
      .scrollIndicators(.hidden)
      .defaultScrollAnchor(.center)
      .onAppear {
        proxy.scrollTo(selection, anchor: .center)
      }
      .onChange(of: selection) { _, newSelection in
        withAnimation(.smooth(duration: 0.25)) {
          proxy.scrollTo(newSelection, anchor: .center)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Chat info sections")
  }
}

private struct ChatInfoTabItems: View {
  let tabs: [ChatInfoTab]
  @Binding var selection: ChatInfoTab
  @Namespace private var selectionHighlight

  var body: some View {
    HStack(spacing: 4) {
      ForEach(tabs) { tab in
        Button {
          guard selection != tab else { return }
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          withAnimation(.smooth(duration: 0.25)) {
            selection = tab
          }
        } label: {
          Text(tab.title)
            .font(.callout)
            .foregroundStyle(selection == tab ? .primary : .secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
              if selection == tab {
                Capsule()
                  .fill(.thinMaterial)
                  .matchedGeometryEffect(id: "selection", in: selectionHighlight)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .id(tab)
      }
    }
  }
}
