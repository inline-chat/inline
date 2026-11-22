import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import UIKit

/// UIKit twin of InlineIOSUI's `VoicePlaybackPill`: the compact playback surface shown in chat
/// headers and above the tab bar. Interactive Liquid Glass on iOS 26+, thin material before.
@MainActor
final class VoicePlaybackPillView: UIView {
  static let height: CGFloat = 52

  static func preferredHeight(compatibleWith traits: UITraitCollection) -> CGFloat {
    let title = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
      for: .systemFont(ofSize: 14, weight: .medium), compatibleWith: traits
    )
    let detail = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 13), compatibleWith: traits)
    let accessible = traits.preferredContentSizeCategory.isAccessibilityCategory
    let lines: CGFloat = accessible ? 2 : 1
    return max(height, ceil(title.lineHeight * lines + detail.lineHeight * lines + (accessible ? 66 : 12)))
  }

  private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
  private static let quickRates: [Float] = [1, 1.5, 2]

  var onOpen: ((AudioPlaybackOpenTarget) -> Void)?

  private let surface = CompatMaterialView(.glass(interactive: true))
  private let playButton = UIButton(type: .system)
  private let loadingRing = CAShapeLayer()
  private let loadingTrack = CAShapeLayer()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()
  private let metadataButton = UIControl()
  private let speedButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private let progressLine = UIView()
  private var progressWidth: NSLayoutConstraint!
  private var cancellables: Set<AnyCancellable> = []
  private var lastSnapshot = Snapshot()

  private var player: SharedAudioPlayer { .shared }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
    player.$state
      .combineLatest(player.$loadingVoice)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _, _ in self?.render() }
      .store(in: &cancellables)
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUp() {
    surface.translatesAutoresizingMaskIntoConstraints = false
    surface.compatSetCornerRadius(Self.height / 2)
    surface.clipsToBounds = true
    addSubview(surface)
    surface.pinEdges(to: self)

    playButton.tintColor = .label
    playButton.addAction(UIAction { [weak self] _ in
      self?.player.toggleCurrentPlayback()
      CompatHaptics.impact(.light)
    }, for: .touchUpInside)
    for layer in [loadingTrack, loadingRing] {
      layer.fillColor = nil
      layer.lineWidth = 2
      layer.lineCap = .round
      playButton.layer.addSublayer(layer)
    }
    loadingTrack.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.25).cgColor
    spinner.hidesWhenStopped = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    playButton.addSubview(spinner)

    titleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .medium))
    titleLabel.adjustsFontForContentSizeCategory = true
    detailLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    )
    detailLabel.adjustsFontForContentSizeCategory = true
    detailLabel.textColor = .secondaryLabel
    let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
    text.axis = .vertical
    text.spacing = 2
    text.isUserInteractionEnabled = false
    text.translatesAutoresizingMaskIntoConstraints = false
    metadataButton.addSubview(text)
    text.pinEdges(to: metadataButton, insets: UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 0))
    metadataButton.addAction(UIAction { [weak self] _ in
      guard let self, let target = currentSnapshot.openTarget else { return }
      onOpen?(target)
    }, for: .touchUpInside)
    metadataButton.isAccessibilityElement = true
    metadataButton.accessibilityTraits = .button
    metadataButton.accessibilityHint = "Opens the original message"

    var speedConfig = UIButton.Configuration.gray()
    speedConfig.cornerStyle = .small
    speedConfig.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
    speedButton.configuration = speedConfig
    speedButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      let rate = player.state.playbackRate
      player.setPlaybackRate(Self.quickRates.first { $0 > rate } ?? 1)
      CompatHaptics.selection()
    }, for: .touchUpInside)
    speedButton.accessibilityLabel = "Playback speed"
    speedButton.accessibilityHint = "Changes the speed. Touch and hold for all speeds"

    closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
    closeButton.tintColor = .secondaryLabel
    closeButton.addAction(UIAction { [weak self] _ in self?.player.stop() }, for: .touchUpInside)
    closeButton.accessibilityLabel = "Close voice playback"

    let row = UIStackView(arrangedSubviews: [playButton, metadataButton, speedButton, closeButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 0
    row.translatesAutoresizingMaskIntoConstraints = false
    surface.contentView.addSubview(row)

    progressLine.backgroundColor = .tintColor
    progressLine.alpha = 0.7
    progressLine.layer.cornerRadius = 1
    progressLine.translatesAutoresizingMaskIntoConstraints = false
    surface.contentView.addSubview(progressLine)
    progressWidth = progressLine.widthAnchor.constraint(equalToConstant: 0)

    let inset = Self.height / 2
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 4),
      row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -4),
      row.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
      row.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
      playButton.widthAnchor.constraint(equalToConstant: 44),
      playButton.heightAnchor.constraint(equalToConstant: 44),
      spinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      metadataButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      speedButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),
      heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
      progressLine.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: inset),
      progressLine.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor, constant: -2),
      progressLine.heightAnchor.constraint(equalToConstant: 2),
      progressWidth,
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let center = CGPoint(x: playButton.bounds.midX, y: playButton.bounds.midY)
    let ring = UIBezierPath(arcCenter: center, radius: 9, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
    loadingRing.path = ring
    loadingTrack.path = ring
    updateProgressLine()
  }

  // MARK: Rendering

  private struct Snapshot: Equatable {
    var display: AudioPlaybackDisplay?
    var openTarget: AudioPlaybackOpenTarget?
    var isLoading = false
    var loadingProgress: Double?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
  }

  private var liveSnapshot: Snapshot? {
    if let loading = player.loadingVoice {
      return Snapshot(
        display: loading.presentation.display,
        openTarget: loading.presentation.openTarget,
        isLoading: true,
        loadingProgress: loading.progress
      )
    }
    let state = player.state
    guard state.item?.kind == .voice else { return nil }
    return Snapshot(
      display: state.display,
      openTarget: state.openTarget,
      isPlaying: state.isPlaying || player.isStartingPlayback,
      currentTime: state.currentTime,
      duration: state.duration
    )
  }

  /// The closing pill keeps its last content while it fades out.
  private var currentSnapshot: Snapshot { liveSnapshot ?? lastSnapshot }

  private func render() {
    if let live = liveSnapshot { lastSnapshot = live }
    let content = currentSnapshot
    titleLabel.text = content.display?.senderName ?? "Voice message"
    let status: String
    if content.isLoading {
      status = content.loadingProgress.map { "Downloading \(Int(min(max($0, 0), 1) * 100))%" } ?? "Downloading…"
    } else {
      status = "\(Self.time(content.currentTime)) / \(Self.time(content.duration))"
    }
    if let context = content.display?.parentTitle, !context.isEmpty {
      detailLabel.text = "\(context) · \(status)"
    } else {
      detailLabel.text = status
    }
    metadataButton.isEnabled = content.openTarget != nil
    metadataButton.accessibilityLabel =
      "Voice message from \(content.display?.senderName ?? "Unknown sender") in \(content.display?.parentTitle ?? "chat")"
    metadataButton.accessibilityValue = content.isLoading
      ? "Downloading"
      : "\(Self.time(content.currentTime)) of \(Self.time(content.duration))"

    if content.isLoading {
      playButton.setImage(nil, for: .normal)
      playButton.isEnabled = false
      if let progress = content.loadingProgress {
        spinner.stopAnimating()
        loadingRing.isHidden = false
        loadingTrack.isHidden = false
        loadingRing.strokeColor = tintColor.cgColor
        loadingRing.strokeEnd = CGFloat(min(max(progress, 0), 1))
      } else {
        loadingRing.isHidden = true
        loadingTrack.isHidden = true
        spinner.startAnimating()
      }
      playButton.accessibilityLabel = "Downloading voice message"
    } else {
      spinner.stopAnimating()
      loadingRing.isHidden = true
      loadingTrack.isHidden = true
      playButton.isEnabled = true
      let symbol = UIImage(
        systemName: content.isPlaying ? "pause.fill" : "play.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      )
      if playButton.image(for: .normal) != symbol { playButton.setImage(symbol, for: .normal) }
      playButton.accessibilityLabel = content.isPlaying ? "Pause voice message" : "Play voice message"
    }

    let rate = player.state.playbackRate
    var config = speedButton.configuration ?? .gray()
    var attributes = AttributeContainer()
    attributes.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold).rounded
    config.attributedTitle = AttributedString(Self.rateLabel(rate), attributes: attributes)
    config.baseForegroundColor = rate != 1 ? tintColor : .secondaryLabel
    config.baseBackgroundColor = rate != 1 ? tintColor.withAlphaComponent(0.16) : .quaternarySystemFill
    speedButton.configuration = config
    speedButton.accessibilityValue = Self.rateLabel(rate)
    speedButton.menu = UIMenu(title: "Playback Speed", options: .singleSelection, children: Self.rates.map { value in
      UIAction(title: Self.rateLabel(value), state: value == rate ? .on : .off) { [weak self] _ in
        self?.player.setPlaybackRate(value)
      }
    })
    updateProgressLine()
  }

  private func updateProgressLine() {
    let content = currentSnapshot
    let progress: Double = if content.isLoading {
      min(max(content.loadingProgress ?? 0, 0), 1)
    } else if content.duration > 0 {
      min(max(content.currentTime / content.duration, 0), 1)
    } else {
      0
    }
    let available = max(0, bounds.width - Self.height)
    progressWidth.constant = available * CGFloat(progress)
  }

  private static func rateLabel(_ rate: Float) -> String {
    rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
  }

  private static func time(_ seconds: TimeInterval) -> String {
    let whole = Int(max(seconds.isFinite ? seconds : 0, 0))
    return String(format: "%d:%02d", whole / 60, whole % 60)
  }
}
