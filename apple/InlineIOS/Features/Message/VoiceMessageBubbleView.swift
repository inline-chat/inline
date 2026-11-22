import Combine
import InlineCompatUI
import InlineKit
import InlineProtocol
import UIKit

/// UIKit twin of InlineUI's `VoiceMessageBubble` in `.bubble` mode: a Messages-style row with
/// glyph, waveform and time, drawn directly on the message bubble. Same metrics, colors and
/// bar math; tap plays or pauses, drag seeks. Used on every iOS version.
@MainActor
final class VoiceMessageBubbleView: UIView {
  static let bubbleHeight: CGFloat = 28

  static func preferredBubbleWidth(duration: Int32) -> CGFloat {
    min(132 + CGFloat(max(duration, 0)) * 6, 240)
  }

  private(set) var message: InlineKit.Message
  private let outgoing: Bool
  private let glyphButton = UIButton(type: .custom)
  private let glyphImage = UIImageView()
  private let ringTrack = CAShapeLayer()
  private let ringProgress = CAShapeLayer()
  private let waveform = VoiceWaveformView()
  private let timeLabel = UILabel()

  private var cancellables: Set<AnyCancellable> = []
  private var progressCancellable: AnyCancellable?
  private var downloadProgress: DownloadProgress?
  private var downloadedLocalURL: URL?
  private var autoDownloadRequestedVoiceID: Int64?
  private var downloadRevision = UUID()

  private var player: SharedAudioPlayer { .shared }

  init(message: InlineKit.Message, outgoing: Bool) {
    self.message = message
    self.outgoing = outgoing
    super.init(frame: .zero)
    semanticContentAttribute = .forceLeftToRight
    setUp()
    refreshLocalURLFromMessage()
    bind()
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: Setup

  private func setUp() {
    glyphImage.contentMode = .center
    glyphImage.isUserInteractionEnabled = false
    for layer in [ringTrack, ringProgress] {
      layer.fillColor = nil
      layer.lineWidth = 2
      layer.lineCap = .round
      glyphButton.layer.addSublayer(layer)
    }
    glyphButton.addSubview(glyphImage)
    glyphButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
    glyphButton.isAccessibilityElement = true
    glyphButton.accessibilityTraits = .button

    timeLabel.font = UIFont.monospacedDigitSystemFont(
      ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular
    )
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)
    timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    waveform.onTap = { [weak self] in self?.waveformTapped() }
    waveform.onSeek = { [weak self] progress in self?.seek(to: progress) }

    let row = UIStackView(arrangedSubviews: [glyphButton, waveform, timeLabel])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: Self.bubbleHeight),
      glyphButton.widthAnchor.constraint(equalToConstant: 22),
      glyphButton.heightAnchor.constraint(equalToConstant: Self.bubbleHeight),
      waveform.heightAnchor.constraint(equalToConstant: 22),
    ])
    let primary = outgoing ? UIColor.white : UIColor.label
    waveform.foreground = primary
    waveform.background = outgoing ? UIColor.white.withAlphaComponent(0.45) : UIColor.secondaryLabel.withAlphaComponent(0.4)
    waveform.samples = Array(message.voiceContent?.waveform ?? Data())
    glyphImage.tintColor = primary
    ringProgress.strokeColor = primary.cgColor
    ringTrack.strokeColor = waveform.background.cgColor
    timeLabel.textColor = outgoing ? UIColor.white.withAlphaComponent(0.9) : .secondaryLabel
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let center = CGPoint(x: glyphButton.bounds.midX, y: glyphButton.bounds.midY)
    glyphImage.frame = glyphButton.bounds
    let ring = UIBezierPath(
      arcCenter: center, radius: 10, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
    ).cgPath
    ringTrack.path = ring
    ringProgress.path = ring
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // The glyph is small; reach into the bubble padding so it's still easy to hit.
    bounds.insetBy(dx: -8, dy: -8).contains(point)
  }

  /// Reuse for another message in the same cell.
  func update(message newMessage: InlineKit.Message) {
    let voiceChanged = newMessage.voiceRemoteId != message.voiceRemoteId
    let pathChanged = newMessage.voiceLocalRelativePath != message.voiceLocalRelativePath
    message = newMessage
    if voiceChanged {
      downloadRevision = UUID()
      downloadedLocalURL = nil
      downloadProgress = nil
      autoDownloadRequestedVoiceID = nil
      waveform.samples = Array(newMessage.voiceContent?.waveform ?? Data())
      bindDownloadProgress()
    }
    refreshLocalURLFromMessage()
    if pathChanged, localURL != nil { downloadProgress = nil }
    requestAutoDownloadIfNeeded()
    render()
  }

  // MARK: State

  private var voiceID: Int64? { message.voiceRemoteId }
  private var isCurrentVoice: Bool { player.isCurrentVoice(message) }
  private var isPlaying: Bool { isCurrentVoice && player.state.isPlaying }

  private var localURL: URL? {
    Self.existing(downloadedLocalURL) ?? Self.existing(message.voiceLocalURL)
  }

  private var isDownloading: Bool {
    guard localURL == nil, let voiceID else { return false }
    return FileDownloader.shared.isVoiceDownloadActive(voiceId: voiceID)
  }

  private var downloadID: String {
    voiceID.map { "voice_\($0)" } ?? "voice_\(message.messageId)"
  }

  private var visibleDownloadProgress: DownloadProgress? {
    guard let downloadProgress, isDownloading, downloadProgress.error == nil else { return nil }
    return downloadProgress.isComplete ? nil : downloadProgress
  }

  private var hasDownloadError: Bool {
    guard let error = downloadProgress?.error else { return false }
    return (error as NSError).code != NSURLErrorCancelled
  }

  private func bind() {
    player.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.render() }
      .store(in: &cancellables)
    bindDownloadProgress()
    requestAutoDownloadIfNeeded()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      progressCancellable?.cancel()
      progressCancellable = nil
    } else if progressCancellable == nil {
      bindDownloadProgress()
      requestAutoDownloadIfNeeded()
    }
  }

  private func bindDownloadProgress() {
    progressCancellable?.cancel()
    guard let voiceID else {
      downloadProgress = nil
      return
    }
    if let progress = FileDownloader.shared.currentVoiceProgress(voiceId: voiceID) {
      apply(progress)
    }
    progressCancellable = FileDownloader.shared.voiceProgressPublisher(voiceId: voiceID)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in self?.apply(progress) }
  }

  private func apply(_ progress: DownloadProgress) {
    guard progress.id == downloadID else { return }
    if localURL != nil || progress.isCancellation {
      downloadProgress = nil
    } else if progress.error != nil {
      downloadProgress = progress
    } else if isDownloading, progress.totalBytes > 0 {
      downloadProgress = progress
    } else {
      downloadProgress = nil
    }
    render()
  }

  private func render() {
    let progress = visibleDownloadProgress
    if let progress {
      ringTrack.isHidden = false
      ringProgress.isHidden = false
      ringProgress.strokeEnd = CGFloat(max(0.04, progress.progress))
      glyphImage.image = UIImage(
        systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
      )
    } else {
      ringTrack.isHidden = true
      ringProgress.isHidden = true
      let image = UIImage(
        systemName: glyphName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
      )
      if glyphImage.image != image { glyphImage.compatSetSymbol(image, animated: window != nil) }
    }
    glyphButton.accessibilityLabel = actionLabel
    waveform.progress = isCurrentVoice ? player.playbackProgress(for: message) : 0
    timeLabel.text = timeText
    accessibilityValue = timeText
  }

  private var glyphName: String {
    if localURL != nil { return isPlaying ? "pause.fill" : "play.fill" }
    if isDownloading { return "xmark" }
    if hasDownloadError { return "arrow.clockwise" }
    return "arrow.down"
  }

  private var actionLabel: String {
    if localURL != nil { return isPlaying ? "Pause voice message" : "Play voice message" }
    if isDownloading { return "Cancel download" }
    if hasDownloadError { return "Retry voice message download" }
    return "Download voice message"
  }

  private var timeText: String {
    if hasDownloadError { return "Failed" }
    if let progress = visibleDownloadProgress, progress.totalBytes > 0 {
      return "\(Int((progress.progress * 100).rounded()))%"
    }
    let seconds = isCurrentVoice ? player.state.currentTime : TimeInterval(message.voiceContent?.duration ?? 0)
    let clamped = max(Int(seconds.rounded()), 0)
    return String(format: "%d:%02d", clamped / 60, clamped % 60)
  }

  // MARK: Actions

  @objc private func primaryTapped() {
    if localURL == nil, let voiceID, isDownloading {
      player.cancelVoiceSelection(mediaID: voiceID)
      downloadProgress = nil
      render()
      return
    }
    CompatHaptics.impact(.light)
    player.requestVoicePlayback(for: message, fileURLOverride: localURL)
  }

  private func waveformTapped() {
    // Only the glyph, which shows an xmark while downloading, cancels a download.
    guard !isDownloading else { return }
    primaryTapped()
  }

  private func seek(to progress: Double) {
    if !isCurrentVoice {
      guard let localURL else { return }
      do {
        try player.prepareVoice(for: message, fileURLOverride: localURL)
      } catch {
        player.reportPlaybackError(error)
        return
      }
    }
    player.seekVoice(to: progress, for: message)
  }

  private func requestAutoDownloadIfNeeded() {
    guard let voiceID, let voice = message.voiceContent else { return }
    guard localURL == nil, !isDownloading, autoDownloadRequestedVoiceID != voiceID else { return }
    guard AutoDownloadPolicy.shouldDownload(kind: .voice, sizeBytes: voice.size > 0 ? voice.size : nil) else { return }
    autoDownloadRequestedVoiceID = voiceID
    let revision = downloadRevision
    bindDownloadProgress()
    FileDownloader.shared.downloadVoice(message: message, priority: .visible) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self, self.downloadRevision == revision else { return }
        if case let .success(url) = result {
          self.downloadedLocalURL = url
        }
        self.downloadProgress = nil
        self.render()
      }
    }
  }

  private func refreshLocalURLFromMessage() {
    if downloadedLocalURL == nil, let url = Self.existing(message.voiceLocalURL) {
      downloadedLocalURL = url
    } else if Self.existing(downloadedLocalURL) == nil {
      downloadedLocalURL = nil
    }
  }

  private static func existing(_ url: URL?) -> URL? {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }
}

// MARK: - Waveform

/// Rounded bars from a voice waveform, filled up to `progress`. Matches `AudioWaveformView`
/// (relative amplitude, 64 target bars, 2.5pt bars with 2pt spacing).
@MainActor
final class VoiceWaveformView: UIView {
  var samples: [UInt8] = [] { didSet { invalidateBars() } }
  var progress: Double = 0 { didSet { if oldValue != progress { setNeedsDisplay() } } }
  var foreground: UIColor = .label { didSet { setNeedsDisplay() } }
  var background: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }
  var onTap: (() -> Void)?
  var onSeek: ((Double) -> Void)?

  private let targetBarCount = 64
  private let barWidth: CGFloat = 2.5
  private let barSpacing: CGFloat = 2
  private let minBarHeight: CGFloat = 2.5
  private var cachedBars: [CGFloat] = []
  private var cachedWidth: CGFloat = -1

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    contentMode = .redraw
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    addGestureRecognizer(pan)
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 22) }

  private func invalidateBars() {
    cachedWidth = -1
    setNeedsDisplay()
  }

  private func bars(for width: CGFloat) -> [CGFloat] {
    if width == cachedWidth { return cachedBars }
    let available = Int((width + barSpacing) / (barWidth + barSpacing))
    let count = max(1, min(targetBarCount, max(available, 1)))
    cachedBars = Self.normalizedBars(samples, count: count)
    cachedWidth = width
    return cachedBars
  }

  override func draw(_ rect: CGRect) {
    let bars = bars(for: bounds.width)
    guard !bars.isEmpty else { return }
    let filled = Int((Double(bars.count) * min(max(progress, 0), 1)).rounded(.down))
    for (index, value) in bars.enumerated() {
      let height = max(minBarHeight, bounds.height * value)
      let x = CGFloat(index) * (barWidth + barSpacing)
      let bar = CGRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
      (index < filled ? foreground : background).setFill()
      UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2).fill()
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    setNeedsDisplay()
  }

  @objc private func tapped() { onTap?() }

  @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
    guard recognizer.state == .changed || recognizer.state == .ended else { return }
    let contentWidth = CGFloat(bars(for: bounds.width).count) * (barWidth + barSpacing) - barSpacing
    guard contentWidth > 0 else { return }
    let x = recognizer.location(in: self).x
    onSeek?(Double(min(max(x / contentWidth, 0), 1)))
  }

  // Same normalization as AudioWaveformView (relative amplitude, stretch short samples).
  static func normalizedBars(_ samples: [UInt8], count: Int) -> [CGFloat] {
    guard !samples.isEmpty else { return Array(repeating: 0.12, count: count) }
    let reduced: [UInt8]
    if samples.count == count {
      reduced = samples
    } else {
      let bucket = Double(samples.count) / Double(count)
      reduced = (0 ..< count).map { index in
        let start = Int(Double(index) * bucket)
        let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucket)))
        return samples[start ..< end].max() ?? 0
      }
    }
    let minSample = CGFloat(reduced.min() ?? 0)
    let spread = max(CGFloat(reduced.max() ?? 0) - minSample, 1)
    return reduced.map { sample in
      let value = CGFloat(sample)
      let level = min(max(max(value / 255, (value - minSample) / spread), 0), 1)
      let curved = CGFloat(pow(Double(level), 0.72))
      return min(1, max(0.12, 0.12 + curved * 0.88))
    }
  }
}
