import InlineKit
import SwiftUI

/// The checkmark next to a person's name: blue for Pro, gold for Believer. Hovering (macOS) or
/// tapping (iOS) names the plan.
public struct UserBadgeView: View {
  private let kind: UserBadgeKind
  private let size: CGFloat
  private let baselineOffset: CGFloat
  private let labelsItself: Bool

  /// - Parameter labelsItself: Pass false when the caller attaches its own tooltip.
  public init(_ kind: UserBadgeKind, size: CGFloat = 14, baselineOffset: CGFloat = 2, labelsItself: Bool = true) {
    self.kind = kind
    self.size = size
    self.baselineOffset = baselineOffset
    self.labelsItself = labelsItself
  }

  public var body: some View {
    Image(systemName: "checkmark.seal.fill")
      .resizable()
      .scaledToFit()
      .symbolRenderingMode(.palette)
      .foregroundStyle(.white, fill)
      .frame(width: size, height: size)
      .fixedSize()
      .alignmentGuide(.firstTextBaseline) { $0[.bottom] - baselineOffset }
      .badgeLabel(labelsItself ? kind.title : nil)
      .accessibilityLabel(kind.title)
  }

  private var fill: AnyShapeStyle {
    switch kind {
    case .pro:
      AnyShapeStyle(Color(red: 0.11, green: 0.61, blue: 0.94))
    case .believer:
      AnyShapeStyle(LinearGradient(
        colors: [Color(red: 0.98, green: 0.80, blue: 0.27), Color(red: 0.90, green: 0.60, blue: 0.10)],
        startPoint: .top,
        endPoint: .bottom
      ))
    }
  }
}

/// A person's name badges, in X's order: plan checkmark, then the Pro team space they belong to.
/// With a space in context the team badge is that space's; without one, the space they represent.
public struct UserNameBadges: View {
  private let user: User
  private let spaceID: Int64?
  private let size: CGFloat
  private let showsTeam: Bool

  public init(user: User, spaceID: Int64?, size: CGFloat = 14, showsTeam: Bool = true) {
    self.user = user
    self.spaceID = spaceID
    self.size = size
    self.showsTeam = showsTeam
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      if let badge = user.badge {
        UserBadgeView(badge, size: size)
      }
      if showsTeam, !user.bot {
        SpaceMemberBadge(userID: user.id, spaceID: spaceID, size: size)
          .id("\(user.id):\(spaceID.map(String.init) ?? "affiliation")")
      }
    }
  }
}

extension View {
  /// Names a badge: a tooltip on macOS, a small popover on tap on iOS.
  @ViewBuilder
  func badgeLabel(_ text: String?) -> some View {
    if let text {
      #if os(iOS)
      modifier(BadgeLabelPopover(text: text))
      #else
      help(text)
      #endif
    } else {
      self
    }
  }
}

#if os(iOS)
private struct BadgeLabelPopover: ViewModifier {
  let text: String
  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture { isPresented = true }
      .popover(isPresented: $isPresented) {
        Text(text)
          .font(.footnote.weight(.semibold))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .presentationCompactAdaptation(.popover)
      }
      .accessibilityAddTraits(.isButton)
  }
}
#endif

/// The signed-in account's plan next to its name in Settings: the checkmark for a personal plan,
/// the badge of a Pro team space whose plan covers them, or a small "Free" tag for neither.
public struct AccountPlanTag: View {
  private let user: User
  private let size: CGFloat

  public init(user: User, size: CGFloat = 14) {
    self.user = user
    self.size = size
  }

  public var body: some View {
    AccountPlanTagContent(user: user, size: size)
      .id(user.id)
  }
}

private struct AccountPlanTagContent: View {
  let user: User
  let size: CGFloat
  @StateObject private var teams: TeamPlansViewModel

  init(user: User, size: CGFloat) {
    self.user = user
    self.size = size
    _teams = StateObject(wrappedValue: TeamPlansViewModel(db: .shared, userID: user.id))
  }

  // On iOS the row is a navigation link; a tap there should open the account, not a popover.
  #if os(iOS)
  private let labelsItself = false
  #else
  private let labelsItself = true
  #endif

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      if let badge = user.badge {
        UserBadgeView(badge, size: size, labelsItself: labelsItself)
      }
      if let team = shownTeam {
        Group {
          if SpaceMemberBadgePolicy.hasBadgePhoto(team) {
            SpaceBadgeTile(space: team, size: size)
          } else {
            PlanTextTag(text: "Team")
          }
        }
        .badgeLabel(labelsItself ? teamLabel(team) : nil)
        .accessibilityLabel(teamLabel(team))
      } else if user.badge == nil {
        PlanTextTag(text: "Free")
          .accessibilityLabel("Free plan")
      }
    }
  }

  /// The team whose badge shows: the first with a photo, matching what others see.
  private var shownTeam: Space? {
    teams.spaces.first(where: SpaceMemberBadgePolicy.hasBadgePhoto) ?? teams.spaces.first
  }

  private func teamLabel(_ team: Space) -> String {
    let others = teams.spaces.count - 1
    return others > 0 ? "Pro through \(team.displayName) and \(others) more" : "Pro through \(team.displayName)"
  }
}

private struct PlanTextTag: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().fill(.quaternary))
  }
}
