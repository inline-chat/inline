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
  public init() {}

  public var body: some View {
    Image("InlineLogoSymbol", bundle: .main)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: 10, height: 10)
      .fixedSize()
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[.bottom] - 1
      }
      .contentShape(Rectangle())
      .help("Inline Team")
      .accessibilityLabel("Inline Team")
  }
}
