import SwiftUI

public struct VerifiedBadge: View, Equatable {
  private let size: CGFloat

  public init(size: CGFloat = 13) {
    self.size = size
  }

  public var body: some View {
    Image(systemName: "checkmark.seal.fill")
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(Color.accentColor)
      .accessibilityHidden(true)
  }
}
