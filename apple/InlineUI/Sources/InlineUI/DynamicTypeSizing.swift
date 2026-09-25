import SwiftUI

public extension View {
  /// Retains a custom system-font size at the default setting and follows Dynamic Type on iOS.
  func scaledFont(
    size: CGFloat,
    weight: Font.Weight = .regular,
    design: Font.Design = .default,
    relativeTo style: Font.TextStyle = .body
  ) -> some View {
    modifier(ScaledSystemFont(size: size, weight: weight, design: design, style: style))
  }

  /// Use for icon chrome; media and avatar contents already scale within their own bounds.
  func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, relativeTo style: Font.TextStyle = .body,
                   alignment: Alignment = .center) -> some View {
    modifier(ScaledIconFrame(width: width, height: height, style: style, alignment: alignment))
  }
}

private struct ScaledSystemFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  let baseSize: CGFloat
  let weight: Font.Weight
  let design: Font.Design

  init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
    _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    baseSize = size
    self.weight = weight
    self.design = design
  }

  func body(content: Content) -> some View {
    #if os(iOS)
    content.font(.system(size: size, weight: weight, design: design))
    #else
    content.font(.system(size: baseSize, weight: weight, design: design))
    #endif
  }
}

private struct ScaledIconFrame: ViewModifier {
  @ScaledMetric private var scale: CGFloat
  let width: CGFloat?
  let height: CGFloat?
  let alignment: Alignment

  init(width: CGFloat?, height: CGFloat?, style: Font.TextStyle, alignment: Alignment) {
    _scale = ScaledMetric(wrappedValue: 1, relativeTo: style)
    self.width = width
    self.height = height
    self.alignment = alignment
  }

  func body(content: Content) -> some View {
    #if os(iOS)
    content.frame(width: width.map { $0 * scale }, height: height.map { $0 * scale }, alignment: alignment)
    #else
    content.frame(width: width, height: height, alignment: alignment)
    #endif
  }
}
