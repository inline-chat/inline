public struct SidebarScrollEdgeVisibility: Equatable, Sendable {
  public let top: Bool
  public let bottom: Bool

  public init(top: Bool, bottom: Bool) {
    self.top = top
    self.bottom = bottom
  }

  public static func resolve(
    viewportStart: Double,
    viewportLength: Double,
    contentLength: Double,
    tolerance: Double = 0.5
  ) -> Self {
    let viewportEnd = viewportStart + max(viewportLength, 0)
    return Self(
      top: viewportStart > tolerance,
      bottom: viewportEnd < contentLength - tolerance
    )
  }
}
