import Foundation
import InlineKit
import SwiftUI

public enum InlineTeamToolbarBadgeVisibility {
  private static let productionUserIDs: Set<Int64> = [1600, 1900]
  private static let developmentPreviewEmail = "dena@inline.chat"

  public static func shouldShow(
    for user: User,
    includesDevelopmentPreview: Bool = false
  ) -> Bool {
    if productionUserIDs.contains(user.id) {
      return true
    }

    guard includesDevelopmentPreview else { return false }
    return user.email?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .localizedCaseInsensitiveCompare(developmentPreviewEmail) == .orderedSame
  }
}

@MainActor
public struct InlineTeamToolbarBadge: View {
  private let size: CGFloat

  public init(size: CGFloat = 10) {
    self.size = size
  }

  public var body: some View {
    Image("InlineLogoSymbol", bundle: .main)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .fixedSize()
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[.bottom] - 1
      }
      .contentShape(Rectangle())
      .help("Inline Team")
      .accessibilityLabel("Inline Team")
  }
}
