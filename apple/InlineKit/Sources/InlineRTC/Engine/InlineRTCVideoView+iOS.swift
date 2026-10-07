#if os(iOS)
import Foundation
import LiveKit
import UIKit

/// The same renderer contract used by the Mac viewer, backed by UIKit on iOS.
@MainActor
public final class InlineRTCVideoView: UIView {
  private let renderer = VideoView()
  private let dimensionObserver = IOSGridVideoDimensionObserver()

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
        renderer.isEnabled = true
        renderer.track = screenShare?.videoTrack?.liveKitTrack
      } else {
        renderer.track = nil
        renderer.isEnabled = false
      }
    }
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    renderer.backgroundColor = .clear
    renderer.layoutMode = .fit
    renderer.mirrorMode = .off
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
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  private func reportCurrentDimensions() {
    guard let dimensions = screenShare?.videoTrack?.dimensions else { return }
    onVideoDimensionsChanged?(dimensions)
  }
}

private final class IOSGridVideoDimensionObserver: NSObject, TrackDelegate, @unchecked Sendable {
  @MainActor var onDimensionsChanged: ((InlineRTCVideoDimensions) -> Void)?

  nonisolated func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
    guard let dimensions else { return }
    let value = InlineRTCVideoDimensions(width: Int(dimensions.width), height: Int(dimensions.height))
    Task { @MainActor [weak self] in self?.onDimensionsChanged?(value) }
  }
}
#endif
