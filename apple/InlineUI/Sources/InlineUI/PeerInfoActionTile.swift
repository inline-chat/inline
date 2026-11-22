import SwiftUI

/// The face of one button in the row under the chat info header: a symbol over
/// a short title, and an optional line naming the current choice.
///
/// Callers wrap it in a `Button` or `Menu` with `.buttonStyle(.plain)` and
/// pass `PeerInfoActionTileButtonStyle` so the pressed state matches.
@available(iOS 17.0, *)
public struct PeerInfoActionTile: View {
  private let title: String
  private let systemImage: String
  private let detail: String?
  private let isHighlighted: Bool

  public init(_ title: String, systemImage: String, detail: String? = nil, isHighlighted: Bool = false) {
    self.title = title
    self.systemImage = systemImage
    self.detail = detail
    self.isHighlighted = isHighlighted
  }

  public var body: some View {
    VStack(spacing: Metrics.spacing) {
      Image(systemName: systemImage)
        .font(.system(size: Metrics.symbolSize, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .frame(height: Metrics.symbolSize + 2)
        .contentTransition(.symbolEffect(.replace))

      VStack(spacing: 0) {
        Text(title)
          .font(Metrics.titleFont)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        if let detail {
          Text(detail)
            .font(Metrics.detailFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .foregroundStyle(isHighlighted ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
    .frame(maxWidth: .infinity, minHeight: Metrics.height)
    .padding(.horizontal, 4)
    .background(Metrics.background, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
  }

  private enum Metrics {
    #if os(macOS)
    static let height: CGFloat = 54
    static let symbolSize: CGFloat = 16
    static let spacing: CGFloat = 4
    static let cornerRadius: CGFloat = 10
    static let titleFont: Font = .system(size: 11.5, weight: .medium)
    static let detailFont: Font = .system(size: 10)
    static var background: some ShapeStyle { Color(nsColor: .quaternaryLabelColor).opacity(0.55) }
    #else
    static let height: CGFloat = 60
    static let symbolSize: CGFloat = 19
    static let spacing: CGFloat = 5
    static let cornerRadius: CGFloat = 12
    static let titleFont: Font = .caption.weight(.medium)
    static let detailFont: Font = .caption2
    static var background: some ShapeStyle { Color(uiColor: .secondarySystemGroupedBackground) }
    #endif
  }
}

/// Dims an action tile while it is pressed, like a system button.
public struct PeerInfoActionTileButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.55 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// Lays out action tiles at equal widths. Up to four fill the row; the row
/// never grows wider than four tiles would need, so two tiles don't stretch.
public struct PeerInfoActionRow<Content: View>: View {
  private let count: Int
  private let content: Content

  public init(count: Int, @ViewBuilder content: () -> Content) {
    self.count = count
    self.content = content()
  }

  public var body: some View {
    HStack(spacing: Self.spacing) {
      content
    }
    .frame(maxWidth: Self.maxTileWidth * CGFloat(max(count, 1)) + Self.spacing * CGFloat(max(count - 1, 0)))
    .frame(maxWidth: .infinity)
  }

  #if os(macOS)
  static var spacing: CGFloat { 8 }
  static var maxTileWidth: CGFloat { 104 }
  #else
  static var spacing: CGFloat { 8 }
  static var maxTileWidth: CGFloat { 120 }
  #endif
}
