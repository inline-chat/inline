import SwiftUI

/// The "What's New in Inline" sheet. Marks the announcement seen as soon as it appears.
public struct WhatsNewView: View {
  private let announcement: WhatsNewAnnouncement
  private let onContinue: () -> Void

  public init(announcement: WhatsNewAnnouncement, onContinue: @escaping () -> Void) {
    self.announcement = announcement
    self.onContinue = onContinue
  }

  public var body: some View {
    content
      .onAppear {
        if WhatsNewStore.shared.announcement?.id == announcement.id {
          WhatsNewStore.shared.markSeen()
        }
      }
  }

#if os(macOS)
  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("What’s New in Inline")
        .font(.system(size: 22, weight: .bold))
        .padding(.bottom, 24)

      rows(spacing: 18)

      HStack {
        Link("Full Changelog", destination: WhatsNewAnnouncement.changelogURL)
          .font(.callout)
          // Keep initial focus on Continue instead of ringing the link.
          .focusable(false)

        Spacer()

        Button(action: onContinue) {
          Text("Continue")
            .padding(.horizontal, 12)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
      }
      .padding(.top, 28)
    }
    .padding(.horizontal, 32)
    .padding(.top, 32)
    .padding(.bottom, 20)
    .frame(width: 440)
  }
#else
  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("What’s New in Inline")
          .font(.largeTitle.bold())
          .padding(.bottom, 36)

        rows(spacing: 28)

        Link("Full Changelog", destination: WhatsNewAnnouncement.changelogURL)
          .font(.body)
          .padding(.top, 32)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 32)
      .padding(.top, 56)
      .padding(.bottom, 24)
    }
    .modifier(WhatsNewContinueBar(onContinue: onContinue))
  }
#endif

  private func rows(spacing: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(announcement.itemsForCurrentPlatform) { item in
        WhatsNewRow(item: item)
      }
    }
  }
}

private struct WhatsNewRow: View {
  let item: WhatsNewItem

#if os(macOS)
  @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 24
  private let textSpacing: CGFloat = 2
  private let titleFont: Font = .system(size: 13, weight: .semibold)
  private let detailFont: Font = .system(size: 13)
#else
  @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 32
  private let textSpacing: CGFloat = 2
  private let titleFont: Font = .headline
  private let detailFont: Font = .body
#endif

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      Image(systemName: item.systemImage)
        .font(.system(size: iconSize))
        .foregroundStyle(.tint)
        .frame(width: iconSize * 1.4)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: textSpacing) {
        Text(item.title)
          .font(titleFont)
        Text(item.detail)
          .font(detailFont)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

#if os(iOS)
/// Pins Continue in the bottom safe area, over a soft scroll edge on iOS 26.
private struct WhatsNewContinueBar: ViewModifier {
  let onContinue: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom, spacing: 0) {
          button
            .buttonStyle(.glassProminent)
        }
    } else {
      content
        .safeAreaInset(edge: .bottom, spacing: 0) {
          button
            .buttonStyle(.borderedProminent)
            .background(.bar)
        }
    }
  }

  private var button: some View {
    Button(action: onContinue) {
      Text("Continue")
        .font(.headline)
        .frame(maxWidth: .infinity)
    }
    .buttonBorderShape(.capsule)
    .controlSize(.extraLarge)
    .padding(.horizontal, 32)
    .padding(.top, 12)
    .padding(.bottom, 16)
  }
}
#endif

#Preview {
  if let announcement = WhatsNewAnnouncement.current {
    WhatsNewView(announcement: announcement, onContinue: {})
  }
}
