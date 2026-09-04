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
  private let baselineOffset: CGFloat

  public init(size: CGFloat = 12, baselineOffset: CGFloat = 1) {
    self.size = size
    self.baselineOffset = baselineOffset
  }

  public var body: some View {
    Image("InlineTeamBadgeAppIcon", bundle: .main)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .clipShape(tileShape)
      .overlay {
        tileShape
          .strokeBorder(.black.opacity(0.16), lineWidth: 0.5)
      }
      .fixedSize()
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[.bottom] - baselineOffset
      }
      .contentShape(Rectangle())
      .accessibilityLabel("Inline Team")
  }

  private var tileShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
  }
}
