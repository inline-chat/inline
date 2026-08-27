import AppKit
import Foundation

public enum InlineTooltipPlacement: Equatable, Sendable {
  case automatic
  case above
  case below
  case left
  case right
  case cursor
}

public struct InlineTooltipShortcut: Equatable, Sendable {
  public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
  }

  public let key: String
  public let modifiers: Modifiers

  public init(_ key: String, modifiers: Modifiers = []) {
    self.key = key
    self.modifiers = modifiers
  }

  public static func command(_ key: String) -> Self {
    Self(key, modifiers: .command)
  }

  var keycapLabels: [String] {
    var labels: [String] = []
    if modifiers.contains(.control) { labels.append("⌃") }
    if modifiers.contains(.option) { labels.append("⌥") }
    if modifiers.contains(.shift) { labels.append("⇧") }
    if modifiers.contains(.command) { labels.append("⌘") }
    labels.append(displayKey)
    return labels
  }

  private var displayKey: String {
    switch key {
    case " ":
      "Space"
    case "\r", "\n":
      "↩"
    default:
      key.count == 1 ? key.uppercased() : key
    }
  }
}

public struct InlineTooltipContent {
  private enum TextStorage {
    case localized(LocalizedStringResource)
    case verbatim(String)
  }

  private let textStorage: TextStorage
  private let descriptionStorage: TextStorage?
  public let shortcut: InlineTooltipShortcut?

  public init(
    _ text: LocalizedStringResource,
    description: LocalizedStringResource? = nil,
    shortcut: InlineTooltipShortcut? = nil
  ) {
    textStorage = .localized(text)
    descriptionStorage = description.map(TextStorage.localized)
    self.shortcut = shortcut
  }

  public init(
    verbatim text: String,
    description: String? = nil,
    shortcut: InlineTooltipShortcut? = nil
  ) {
    textStorage = .verbatim(text)
    descriptionStorage = description.map(TextStorage.verbatim)
    self.shortcut = shortcut
  }

  var resolved: InlineTooltipResolvedContent {
    let text = Self.resolve(textStorage)
    let description = descriptionStorage.map(Self.resolve)

    return InlineTooltipResolvedContent(
      text: text,
      description: description,
      shortcut: shortcut
    )
  }

  private static func resolve(_ storage: TextStorage) -> String {
    switch storage {
    case let .localized(resource):
      String(localized: resource)
    case let .verbatim(value):
      value
    }
  }
}

struct InlineTooltipResolvedContent: Equatable {
  let text: String
  let description: String?
  let shortcut: InlineTooltipShortcut?

  init(
    text: String,
    description: String? = nil,
    shortcut: InlineTooltipShortcut?
  ) {
    self.text = text
    self.description = description
    self.shortcut = shortcut
  }
}

enum InlineTooltipGeometry {
  static let targetSpacing: CGFloat = 6
  static let screenMargin: CGFloat = 8
  static let cursorSpacing: CGFloat = 8

  private enum PhysicalPlacement {
    case above
    case below
    case left
    case right
  }

  static func frame(
    anchorFrame: CGRect,
    tooltipSize: CGSize,
    visibleFrame: CGRect,
    placement: InlineTooltipPlacement,
    renderingInset: CGFloat = 0
  ) -> CGRect {
    let renderingInset = min(
      max(renderingInset, 0),
      min(tooltipSize.width, tooltipSize.height) / 2
    )

    if placement == .cursor {
      return cursorFrame(
        point: CGPoint(x: anchorFrame.midX, y: anchorFrame.midY),
        tooltipSize: tooltipSize,
        visibleFrame: visibleFrame,
        renderingInset: renderingInset
      )
    }

    let candidates: [PhysicalPlacement] = switch placement {
    case .automatic, .above:
      [.above, .below]
    case .below:
      [.below, .above]
    case .left:
      [.left, .right]
    case .right:
      [.right, .left]
    case .cursor:
      preconditionFailure("Cursor placement is resolved separately")
    }
    let resolvedPlacement = candidates.first {
      hasRoom(
        for: $0,
        anchorFrame: anchorFrame,
        tooltipSize: tooltipSize,
        visibleFrame: visibleFrame,
        renderingInset: renderingInset
      )
    } ?? candidates[0]
    let proposedOrigin = origin(
      for: resolvedPlacement,
      anchorFrame: anchorFrame,
      tooltipSize: tooltipSize,
      renderingInset: renderingInset
    )
    return clampedFrame(
      origin: proposedOrigin,
      size: tooltipSize,
      visibleFrame: visibleFrame
    )
  }

  private static func origin(
    for placement: PhysicalPlacement,
    anchorFrame: CGRect,
    tooltipSize: CGSize,
    renderingInset: CGFloat
  ) -> CGPoint {
    switch placement {
    case .above:
      CGPoint(
        x: anchorFrame.midX - tooltipSize.width / 2,
        y: anchorFrame.maxY + targetSpacing - renderingInset
      )
    case .below:
      CGPoint(
        x: anchorFrame.midX - tooltipSize.width / 2,
        y: anchorFrame.minY - targetSpacing - tooltipSize.height + renderingInset
      )
    case .left:
      CGPoint(
        x: anchorFrame.minX - targetSpacing - tooltipSize.width + renderingInset,
        y: anchorFrame.midY - tooltipSize.height / 2
      )
    case .right:
      CGPoint(
        x: anchorFrame.maxX + targetSpacing - renderingInset,
        y: anchorFrame.midY - tooltipSize.height / 2
      )
    }
  }

  private static func hasRoom(
    for placement: PhysicalPlacement,
    anchorFrame: CGRect,
    tooltipSize: CGSize,
    visibleFrame: CGRect,
    renderingInset: CGFloat
  ) -> Bool {
    let frame = CGRect(
      origin: origin(
        for: placement,
        anchorFrame: anchorFrame,
        tooltipSize: tooltipSize,
        renderingInset: renderingInset
      ),
      size: tooltipSize
    )
    switch placement {
    case .above:
      return frame.maxY <= visibleFrame.maxY - screenMargin
    case .below:
      return frame.minY >= visibleFrame.minY + screenMargin
    case .left:
      return frame.minX >= visibleFrame.minX + screenMargin
    case .right:
      return frame.maxX <= visibleFrame.maxX - screenMargin
    }
  }

  private static func cursorFrame(
    point: CGPoint,
    tooltipSize: CGSize,
    visibleFrame: CGRect,
    renderingInset: CGFloat
  ) -> CGRect {
    let rightX = point.x + cursorSpacing - renderingInset
    let leftX = point.x - cursorSpacing - tooltipSize.width + renderingInset
    let belowY = point.y - cursorSpacing - tooltipSize.height + renderingInset
    let aboveY = point.y + cursorSpacing - renderingInset
    let candidates = [
      CGPoint(x: rightX, y: belowY),
      CGPoint(x: rightX, y: aboveY),
      CGPoint(x: leftX, y: belowY),
      CGPoint(x: leftX, y: aboveY),
    ]
    let proposedOrigin = candidates.first {
      fullyFits(
        CGRect(origin: $0, size: tooltipSize),
        visibleFrame: visibleFrame
      )
    } ?? candidates[0]
    return clampedFrame(
      origin: proposedOrigin,
      size: tooltipSize,
      visibleFrame: visibleFrame
    )
  }

  private static func fullyFits(_ frame: CGRect, visibleFrame: CGRect) -> Bool {
    frame.minX >= visibleFrame.minX + screenMargin
      && frame.maxX <= visibleFrame.maxX - screenMargin
      && frame.minY >= visibleFrame.minY + screenMargin
      && frame.maxY <= visibleFrame.maxY - screenMargin
  }

  private static func clampedFrame(
    origin: CGPoint,
    size: CGSize,
    visibleFrame: CGRect
  ) -> CGRect {
    let minX = visibleFrame.minX + screenMargin
    let maxX = visibleFrame.maxX - screenMargin - size.width
    let minY = visibleFrame.minY + screenMargin
    let maxY = visibleFrame.maxY - screenMargin - size.height
    return CGRect(
      x: clamp(origin.x, lower: minX, upper: maxX),
      y: clamp(origin.y, lower: minY, upper: maxY),
      width: size.width,
      height: size.height
    )
  }

  private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    guard lower <= upper else { return lower }
    return min(max(value, lower), upper)
  }
}
