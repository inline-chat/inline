import Foundation
import LiveKit

#if os(macOS)
import AppKit
import CoreGraphics
#endif

public struct InlineRTCScreenCaptureSource: Identifiable, Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case display
    case window
  }

  public struct Frame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  public let id: String
  public let kind: Kind
  public let name: String
  public let displayID: UInt32?
  public let frame: Frame
  public let pixelDimensions: InlineRTCVideoDimensions?

  let storage: InlineRTCScreenCaptureSourceStorage?

  init(
    id: String,
    name: String,
    displayID: UInt32?,
    kind: Kind = .display,
    frame: Frame = Frame(x: 0, y: 0, width: 1, height: 1),
    pixelDimensions: InlineRTCVideoDimensions? = nil,
    storage: InlineRTCScreenCaptureSourceStorage? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.displayID = displayID
    self.frame = frame
    self.pixelDimensions = pixelDimensions
    self.storage = storage
  }

  public static func == (
    lhs: InlineRTCScreenCaptureSource,
    rhs: InlineRTCScreenCaptureSource
  ) -> Bool {
    lhs.id == rhs.id
  }
}

public enum InlineRTCScreenShareQualityProfile: String, CaseIterable, Codable, Sendable {
  case automatic
  case detail
  case motion
  case saveBandwidth
  case maximum
}

enum InlineRTCScreenShareDegradationPolicy: Equatable, Sendable {
  case automatic
  case maintainResolution
  case maintainFramerate
  case balanced
}

struct InlineRTCScreenShareEncodingPolicy: Equatable, Sendable {
  let dimensions: InlineRTCVideoDimensions
  let framesPerSecond: Int
  let maximumBitrate: Int
  let degradationPolicy: InlineRTCScreenShareDegradationPolicy

  static func resolve(
    profile: InlineRTCScreenShareQualityProfile,
    source: InlineRTCScreenCaptureSource
  ) -> Self {
    let sourceDimensions = source.pixelDimensions
      ?? InlineRTCVideoDimensions(width: 1_920, height: 1_080)
    let maximumLongEdge: Int? = switch profile {
    case .automatic, .detail: 2_560
    case .motion: 1_920
    case .saveBandwidth: 1_280
    case .maximum: nil
    }
    let dimensions = fittedDimensions(
      sourceDimensions,
      maximumLongEdge: maximumLongEdge
    )

    return switch profile {
    case .automatic:
      Self(
        dimensions: dimensions,
        framesPerSecond: 15,
        maximumBitrate: automaticBitrate(for: dimensions),
        degradationPolicy: .automatic
      )
    case .detail:
      Self(
        dimensions: dimensions,
        framesPerSecond: 15,
        maximumBitrate: 5_000_000,
        degradationPolicy: .maintainResolution
      )
    case .motion:
      Self(
        dimensions: dimensions,
        framesPerSecond: 30,
        maximumBitrate: 5_000_000,
        degradationPolicy: .maintainFramerate
      )
    case .saveBandwidth:
      Self(
        dimensions: dimensions,
        framesPerSecond: 15,
        maximumBitrate: 1_500_000,
        degradationPolicy: .balanced
      )
    case .maximum:
      Self(
        dimensions: dimensions,
        framesPerSecond: 30,
        maximumBitrate: 10_000_000,
        degradationPolicy: .maintainResolution
      )
    }
  }

  private static func fittedDimensions(
    _ source: InlineRTCVideoDimensions,
    maximumLongEdge: Int?
  ) -> InlineRTCVideoDimensions {
    let sourceWidth = max(source.width, 2)
    let sourceHeight = max(source.height, 2)
    let sourceLongEdge = max(sourceWidth, sourceHeight)
    let scale = maximumLongEdge.map {
      min(Double($0) / Double(sourceLongEdge), 1)
    } ?? 1
    return InlineRTCVideoDimensions(
      width: encodeSafeDimension(Double(sourceWidth) * scale),
      height: encodeSafeDimension(Double(sourceHeight) * scale)
    )
  }

  private static func encodeSafeDimension(_ value: Double) -> Int {
    let rounded = max(Int(value.rounded(.down)), 2)
    return rounded.isMultiple(of: 2) ? rounded : rounded - 1
  }

  private static func automaticBitrate(for dimensions: InlineRTCVideoDimensions) -> Int {
    switch max(dimensions.width, dimensions.height) {
    case ...1_280: 1_500_000
    case ...1_920: 2_500_000
    default: 5_000_000
    }
  }
}

final class InlineRTCScreenCaptureSourceStorage: @unchecked Sendable {
  let rawValue: AnyObject

  init(rawValue: AnyObject) {
    self.rawValue = rawValue
  }
}

public struct InlineRTCVideoDimensions: Equatable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  public var aspectRatio: Double? {
    guard width > 0, height > 0 else { return nil }
    return Double(width) / Double(height)
  }
}

public struct InlineRTCScreenShareWindowLayout: Equatable, Sendable {
  public let aspectRatio: CGFloat
  public let initialContentSize: CGSize
  public let minimumContentSize: CGSize

  public init(
    aspectRatio: CGFloat,
    initialContentSize: CGSize,
    minimumContentSize: CGSize
  ) {
    self.aspectRatio = aspectRatio
    self.initialContentSize = initialContentSize
    self.minimumContentSize = minimumContentSize
  }
}

public enum InlineRTCScreenShareWindowSizePolicy {
  public static func layout(
    videoDimensions: InlineRTCVideoDimensions,
    backingScale: CGFloat,
    visibleFrameSize: CGSize
  ) -> InlineRTCScreenShareWindowLayout? {
    guard videoDimensions.width > 0,
          videoDimensions.height > 0,
          visibleFrameSize.width > 0,
          visibleFrameSize.height > 0
    else { return nil }

    let aspectRatio = CGFloat(videoDimensions.width) / CGFloat(videoDimensions.height)
    let maximumSize = CGSize(
      width: visibleFrameSize.width * 0.82,
      height: visibleFrameSize.height * 0.78
    )
    let scale = max(backingScale, 1)
    let naturalSize = CGSize(
      width: CGFloat(videoDimensions.width) / scale,
      height: CGFloat(videoDimensions.height) / scale
    )
    var initialSize = fit(naturalSize, inside: maximumSize)
    let preferredLongEdge = min(560, max(maximumSize.width, maximumSize.height))
    let currentLongEdge = max(initialSize.width, initialSize.height)
    if currentLongEdge < preferredLongEdge {
      let growth = min(
        preferredLongEdge / currentLongEdge,
        maximumSize.width / initialSize.width,
        maximumSize.height / initialSize.height
      )
      initialSize = CGSize(
        width: initialSize.width * growth,
        height: initialSize.height * growth
      )
    }

    let minimumLongEdge: CGFloat = 360
    let unconstrainedMinimum = if aspectRatio >= 1 {
      CGSize(width: minimumLongEdge, height: minimumLongEdge / aspectRatio)
    } else {
      CGSize(width: minimumLongEdge * aspectRatio, height: minimumLongEdge)
    }
    let minimumSize = fit(unconstrainedMinimum, inside: initialSize)

    return InlineRTCScreenShareWindowLayout(
      aspectRatio: aspectRatio,
      initialContentSize: initialSize,
      minimumContentSize: minimumSize
    )
  }

  private static func fit(_ size: CGSize, inside bounds: CGSize) -> CGSize {
    let scale = min(
      bounds.width / size.width,
      bounds.height / size.height,
      1
    )
    return CGSize(width: size.width * scale, height: size.height * scale)
  }
}

public final class InlineRTCVideoTrack: @unchecked Sendable, Equatable {
  fileprivate let liveKitTrack: VideoTrack

  init(_ liveKitTrack: VideoTrack) {
    self.liveKitTrack = liveKitTrack
  }

  public static func == (lhs: InlineRTCVideoTrack, rhs: InlineRTCVideoTrack) -> Bool {
    lhs === rhs || lhs.liveKitTrack === rhs.liveKitTrack
  }

  public var dimensions: InlineRTCVideoDimensions? {
    liveKitTrack.dimensions.map {
      InlineRTCVideoDimensions(width: Int($0.width), height: Int($0.height))
    }
  }
}

public struct InlineRTCScreenShare: Identifiable, Equatable, Sendable {
  public var id: String { publicationID }
  public let participantIdentity: String
  public let publicationID: String
  public let captureSourceID: String?
  public let isLocal: Bool
  public let videoTrack: InlineRTCVideoTrack?

  init(
    participantIdentity: String,
    publicationID: String,
    captureSourceID: String? = nil,
    isLocal: Bool,
    videoTrack: VideoTrack?
  ) {
    self.participantIdentity = participantIdentity
    self.publicationID = publicationID
    self.captureSourceID = captureSourceID
    self.isLocal = isLocal
    self.videoTrack = videoTrack.map(InlineRTCVideoTrack.init)
  }
}

public enum InlineRTCScreenShareViewerSelection {
  /// Resolves the publication an existing observer should render. The exact
  /// SID wins; a replacement is accepted only when one publication for the
  /// same participant makes the rebind unambiguous.
  public static func resolve(
    publicationID: String,
    participantIdentity: String,
    shares: [InlineRTCScreenShare]
  ) -> InlineRTCScreenShare? {
    if let exact = shares.first(where: {
      $0.publicationID == publicationID
        && $0.participantIdentity == participantIdentity
    }) {
      return exact
    }
    let replacements = shares.filter {
      $0.participantIdentity == participantIdentity
    }
    guard replacements.count == 1 else { return nil }
    return replacements[0]
  }
}

public enum InlineRTCScreenShareState: Equatable, Sendable {
  case off
  case publishing
  case published
  case stopping
  case failed(String)
}

#if os(macOS)
extension InlineRTCScreenCaptureSource {
  init(display: MacOSDisplay, index: Int) {
    let screen = NSScreen.screens.first { screen in
      (screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber)?.uint32Value == display.displayID
    }
    let title = screen?.localizedName ?? (
      display.displayID == CGMainDisplayID()
        ? "Main Display"
        : "Display \(index + 1)"
    )
    self.init(
      id: "display:\(display.displayID)",
      name: "\(title) (\(display.width)×\(display.height))",
      displayID: display.displayID,
      frame: Frame(
        x: display.frame.origin.x,
        y: display.frame.origin.y,
        width: display.frame.width,
        height: display.frame.height
      ),
      pixelDimensions: InlineRTCVideoDimensions(
        width: Int(display.width),
        height: Int(display.height)
      ),
      storage: InlineRTCScreenCaptureSourceStorage(rawValue: display)
    )
  }

  var liveKitSource: (any MacOSScreenCaptureSource)? {
    storage?.rawValue as? any MacOSScreenCaptureSource
  }
}

@MainActor
public final class InlineRTCVideoView: NSView {
  private let renderer = VideoView()
  private let dimensionObserver = InlineRTCVideoDimensionObserver()

  public var onVideoDimensionsChanged: ((InlineRTCVideoDimensions) -> Void)? {
    didSet {
      dimensionObserver.onDimensionsChanged = { [weak self] dimensions in
        self?.onVideoDimensionsChanged?(dimensions)
      }
      reportCurrentDimensions()
    }
  }

  public var screenShare: InlineRTCScreenShare? {
    didSet {
      let oldTrack = oldValue?.videoTrack
      let newTrack = screenShare?.videoTrack
      if oldTrack != newTrack {
        oldTrack?.liveKitTrack.remove(delegate: dimensionObserver)
        newTrack?.liveKitTrack.add(delegate: dimensionObserver)
      }
      renderer.track = isVideoEnabled ? newTrack?.liveKitTrack : nil
      reportCurrentDimensions()
    }
  }

  public var isVideoEnabled: Bool {
    get { renderer.isEnabled }
    set {
      guard renderer.isEnabled != newValue else { return }
      if newValue {
        // Enable first so assigning the desired track produces one attach.
        renderer.isEnabled = true
        renderer.track = screenShare?.videoTrack?.liveKitTrack
      } else {
        // Detach while the renderer is still enabled. Clearing a track after
        // disabling makes LiveKit remove the same renderer a second time when
        // SwiftUI dismantles the view.
        renderer.track = nil
        renderer.isEnabled = false
      }
    }
  }

  override public init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    renderer.layoutMode = .fit
    renderer.mirrorMode = .off
    renderer.wantsLayer = true
    renderer.layer?.backgroundColor = NSColor.clear.cgColor
    renderer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(renderer)
    NSLayoutConstraint.activate([
      renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
      renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
      renderer.topAnchor.constraint(equalTo: topAnchor),
      renderer.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func reportCurrentDimensions() {
    guard let dimensions = screenShare?.videoTrack?.dimensions else { return }
    onVideoDimensionsChanged?(dimensions)
  }
}

private final class InlineRTCVideoDimensionObserver: NSObject, TrackDelegate, @unchecked Sendable {
  @MainActor var onDimensionsChanged: ((InlineRTCVideoDimensions) -> Void)?

  nonisolated func track(_: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
    guard let dimensions else { return }
    let value = InlineRTCVideoDimensions(
      width: Int(dimensions.width),
      height: Int(dimensions.height)
    )
    Task { @MainActor [weak self] in
      self?.onDimensionsChanged?(value)
    }
  }
}
#endif
