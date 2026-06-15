import SwiftUI

enum MacToolbarLayout: Equatable {
  case regular
  case compact

  var titleSpacing: CGFloat {
    switch self {
    case .regular:
      return 8
    case .compact:
      return 6
    }
  }

  var titleMaxWidth: CGFloat {
    switch self {
    case .regular:
      return 280
    case .compact:
      return 220
    }
  }

  var chatIconSize: CGFloat {
    switch self {
    case .regular:
      return Theme.chatToolbarIconSize
    case .compact:
      return 24
    }
  }

  var titleFontSize: CGFloat {
    switch self {
    case .regular:
      return 13
    case .compact:
      return 12
    }
  }

  var subtitleFontSize: CGFloat {
    switch self {
    case .regular:
      return 11
    case .compact:
      return 10
    }
  }

  var breadcrumbHorizontalPadding: CGFloat {
    switch self {
    case .regular:
      return 5
    case .compact:
      return 4
    }
  }

  var breadcrumbVerticalPadding: CGFloat {
    switch self {
    case .regular:
      return 1
    case .compact:
      return 0
    }
  }

  var breadcrumbCornerRadius: CGFloat {
    switch self {
    case .regular:
      return 5
    case .compact:
      return 4
    }
  }

  var botPresencePreviewSize: CGFloat {
    switch self {
    case .regular:
      return 22
    case .compact:
      return 18
    }
  }

  var botPresenceCornerRadius: CGFloat {
    switch self {
    case .regular:
      return 6
    case .compact:
      return 5
    }
  }

  var visibleParticipantCount: Int {
    switch self {
    case .regular:
      return 3
    case .compact:
      return 2
    }
  }

  var participantAvatarSize: CGFloat {
    switch self {
    case .regular:
      return 24
    case .compact:
      return 20
    }
  }

  var participantOverlap: CGFloat {
    switch self {
    case .regular:
      return 6
    case .compact:
      return 5
    }
  }

  var participantHorizontalPadding: CGFloat {
    switch self {
    case .regular:
      return 8
    case .compact:
      return 5
    }
  }
}

extension MacToolbarStyle {
  var layout: MacToolbarLayout {
    switch self {
    case .unified:
      return .regular
    case .unifiedCompact:
      return .compact
    }
  }
}

extension View {
  func macToolbarLayout(_ layout: MacToolbarLayout) -> some View {
    environment(\.macToolbarLayout, layout)
  }
}

extension EnvironmentValues {
  @Entry var macToolbarLayout = MacToolbarLayout.regular
}
