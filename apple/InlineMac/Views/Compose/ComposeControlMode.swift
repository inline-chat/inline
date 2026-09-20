import AppKit

/// Stable Glass Compose topologies. The layout describes where Compose-owned
/// controls live; feature availability is configured separately.
enum GlassComposeLayout {
  /// Existing chat layout with detached Glass attachment and voice controls.
  case sideControls

  /// One end-to-end Glass surface with a compact internal accessory row.
  case accessoryBar

  var viewportHorizontalInset: CGFloat {
    switch self {
      case .sideControls: ChatLayoutMetrics.leadingControlCenterX - ComposeControlMode.glass.sideButtonSize / 2
      case .accessoryBar: 0
    }
  }

  var viewportBottomInset: CGFloat {
    switch self {
      case .sideControls: 14
      case .accessoryBar: 8
    }
  }

  var accessoryBarHeight: CGFloat {
    switch self {
      case .sideControls: 0
      case .accessoryBar: 32
    }
  }
}

enum ComposeControlPresentation {
  case standard
  case accessoryBar

  func buttonSize(mode: ComposeControlMode) -> CGFloat {
    switch self {
      case .standard: mode.inlineButtonSize
      case .accessoryBar: 24
    }
  }

  func iconPointSize(mode: ComposeControlMode) -> CGFloat {
    switch self {
      case .standard: mode.sendIconPointSize
      case .accessoryBar: 13
    }
  }

  var sendSymbolName: String {
    switch self {
      case .standard: "arrow.up"
      case .accessoryBar: "arrow.up"
    }
  }
}

enum ComposeControlMode {
  case legacy
  case glass

  var textMinHeight: CGFloat {
    switch self {
      case .legacy:
        Theme.composeMinHeight
      case .glass:
        34
    }
  }

  var wrapperMinHeight: CGFloat {
    switch self {
      case .legacy:
        Theme.composeMinHeight + Theme.composeOuterSpacing
      case .glass:
        glassControlsMinHeight + viewportBottomInset
    }
  }

  var viewportHorizontalInset: CGFloat {
    switch self {
      case .legacy:
        Theme.composeOuterSpacing
      case .glass:
        GlassComposeLayout.sideControls.viewportHorizontalInset
    }
  }

  var viewportBottomInset: CGFloat {
    switch self {
      case .legacy:
        0
      case .glass:
        14
    }
  }

  var sideButtonSize: CGFloat {
    switch self {
      case .legacy:
        Theme.composeButtonSize
      case .glass:
        34
    }
  }

  var inlineButtonSize: CGFloat {
    switch self {
      case .legacy:
        Theme.composeButtonSize
      case .glass:
        28
    }
  }

  var silentButtonSize: CGFloat {
    switch self {
      case .legacy:
        Theme.composeButtonSize * 0.94
      case .glass:
        26
    }
  }

  var sendButtonSize: CGFloat {
    inlineButtonSize
  }

  var voiceInputButtonSize: CGFloat {
    switch self {
      case .legacy:
        Theme.composeButtonSize
      case .glass:
        inlineButtonSize
    }
  }

  var voiceInputButtonVisualSize: CGFloat {
    switch self {
      case .legacy:
        voiceInputButtonSize
      case .glass:
        // Glass divergence: active voice controls sit inside the compact 34pt
        // compose pill, so the visible circles are smaller than their hit area.
        24
    }
  }

  var voiceInputRowSpacing: CGFloat {
    switch self {
      case .legacy:
        10
      case .glass:
        8
    }
  }

  var voiceInputHorizontalPadding: CGFloat {
    switch self {
      case .legacy:
        4
      case .glass:
        8
    }
  }

  var voiceInputWaveformHeight: CGFloat {
    switch self {
      case .legacy:
        20
      case .glass:
        18
    }
  }

  var voiceInputTargetBarCount: Int {
    switch self {
      case .legacy:
        160
      case .glass:
        // Glass divergence: use a high cap so AudioWaveformView's geometry
        // chooses the count from available width instead of leaving empty row
        // space on wide compose pills.
        1_000
    }
  }

  var voiceInputBarWidth: CGFloat {
    switch self {
      case .legacy:
        1.5
      case .glass:
        1.2
    }
  }

  var voiceInputBarSpacing: CGFloat {
    switch self {
      case .legacy:
        2
      case .glass:
        1.8
    }
  }

  var voiceInputRecordingDotSize: CGFloat {
    switch self {
      case .legacy:
        8
      case .glass:
        6
    }
  }

  var emojiButtonSize: CGFloat {
    switch self {
      case .legacy:
        Theme.composeButtonSize
      case .glass:
        // Glass divergence: emoji is inside the compose pill near send, so it
        // uses inline action sizing instead of the outer side-circle size.
        inlineButtonSize
    }
  }

  var voiceButtonSize: CGFloat {
    switch self {
      case .legacy:
        Theme.composeButtonSize
      case .glass:
        // Glass divergence: the idle voice affordance lives in the trailing
        // glass circle, not inside the compose pill.
        sideButtonSize
    }
  }

  var glassControlsMinHeight: CGFloat {
    max(textMinHeight, sideButtonSize)
  }

  var glassSpacing: CGFloat {
    switch self {
      case .legacy:
        6
      case .glass:
        14
    }
  }

  var pillContentInset: CGFloat {
    switch self {
      case .legacy:
        0
      case .glass:
        4
    }
  }

  /// Centers the fixed-size send button inside the compact pill's trailing cap.
  /// Deriving both axes from the same geometry keeps the three visible edge
  /// insets equal if the pill or button size changes.
  var sendButtonEdgeInset: CGFloat {
    (textMinHeight - sendButtonSize) / 2
  }

  var usesInputStyleTextInsets: Bool {
    switch self {
      case .legacy:
        false
      case .glass:
        // Glass divergence: the glass compose behaves like a normal input,
        // not the legacy compose that recenters a single line in a taller field.
        true
    }
  }

  var inlineButtonBottomInset: CGFloat {
    switch self {
      case .legacy:
        0
      case .glass:
        max(0, (textMinHeight - inlineButtonSize) / 2)
    }
  }

  var usesCustomHoverFill: Bool {
    self == .legacy
  }

  var sideIconPointSize: CGFloat {
    switch self {
      case .legacy:
        sideButtonSize * 0.5
      case .glass:
        15
    }
  }

  var emojiIconPointSize: CGFloat {
    switch self {
      case .legacy:
        emojiButtonSize * 0.5
      case .glass:
        14
    }
  }

  var inlineIconPointSize: CGFloat {
    switch self {
      case .legacy:
        inlineButtonSize * 0.56
      case .glass:
        14
    }
  }

  var voiceButtonIconPointSize: CGFloat {
    switch self {
      case .legacy:
        inlineIconPointSize
      case .glass:
        sideIconPointSize
    }
  }

  var silentIconPointSize: CGFloat {
    switch self {
      case .legacy:
        silentButtonSize * 0.58
      case .glass:
        14
    }
  }

  var sendIconPointSize: CGFloat {
    switch self {
      case .legacy:
        16
      case .glass:
        15
    }
  }

  var voiceInputIconPointSize: CGFloat {
    switch self {
      case .legacy:
        13
      case .glass:
        12.5
    }
  }
}
