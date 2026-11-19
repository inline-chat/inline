import InlineKit
import SwiftUI

/// The chat info tab selector, used as the pinned section header above the tab content.
///
/// A native segmented control rather than a custom capsule strip: it takes the system look
/// on each OS (the classic segmented control on macOS 15, the Liquid Glass capsule on
/// macOS 26) and brings keyboard focus, arrow-key selection and VoiceOver's "tab N of M"
/// without custom code. Six titled segments fit the 640pt column; when they don't fit, the
/// segments switch to their symbols, keeping titles for VoiceOver.
///
/// The bar is full-bleed: it lays the control in the chat info column itself and draws its
/// own background and bottom hairline across the whole width, so content scrolling under
/// it while pinned is covered edge to edge. Place it bare, without column padding or a
/// background.
struct PeerInfoMacTabBar: View {
  let tabs: [PeerInfoTab]
  @Binding var selection: PeerInfoTab

  init(tabs: [PeerInfoTab], selection: Binding<PeerInfoTab>) {
    self.tabs = tabs
    _selection = selection
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      picker(showsTitles: true)
      picker(showsTitles: false)
    }
    .peerInfoColumn()
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func picker(showsTitles: Bool) -> some View {
    Picker("Chat Info Sections", selection: $selection) {
      ForEach(tabs) { tab in
        segment(tab, showsTitle: showsTitles)
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func segment(_ tab: PeerInfoTab, showsTitle: Bool) -> some View {
    if showsTitle {
      Text(tab.title)
    } else {
      Image(systemName: tab.systemImage)
        .accessibilityLabel(tab.title)
    }
  }
}

#if DEBUG
#Preview("Tab bar") {
  @Previewable @State var selection: PeerInfoTab = .media
  VStack(spacing: 0) {
    PeerInfoMacTabBar(tabs: [.members, .threads, .media, .files, .voice, .links], selection: $selection)
    PeerInfoMacTabBar(tabs: [.media, .files, .voice, .links], selection: $selection)
      .frame(width: 360)
  }
  .frame(width: 720)
}
#endif
