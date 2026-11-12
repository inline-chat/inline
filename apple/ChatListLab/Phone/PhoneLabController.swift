import UIKit
import ChatListCore
import ChatListUIKit

private struct KeyboardWitness {
  let row: Int64
  let character: Int
  let initialDistance: CGFloat
}

private struct KeyboardFrameEvidence: Codable {
  let time: Double
  let displayLinkTimestamp: Double?
  let displayLinkTargetTimestamp: Double?
  let presentationTop: Double
  let layoutGuideTop: Double
  let systemKeyboardEndScreenY: Double?
  let bottomInset: Double
  let row: Int64?
  let character: Int?
  let glyphY: Double?
  let distanceToUsableBottom: Double?
  let expectedDistance: Double?
  let legalClamp: Bool?
  let originResidual: Double?
  let residual: Double?
  let endpointComparable: Bool
  let intent: String
  let isUserScrolling: Bool
}

/// One synchronous inset submission. Native touch motion cannot run between the two glyph reads.
private struct KeyboardTransactionEvidence: Codable {
  let time: Double
  let displayLinkTimestamp: Double?
  let displayLinkTargetTimestamp: Double?
  let row: Int64?
  let character: Int?
  let fixedWitnessRowIntersectsReading: Bool?
  let fixedWitnessGlyphInUsableViewport: Bool
  let visibleWitnessSelected: Bool
  let oldUsableBottom: Double
  let newUsableBottom: Double
  let guideDelta: Double
  let preGlyphY: Double?
  let postGlyphY: Double?
  let previousPostGlyphY: Double?
  let totalGlyphDeltaSincePreviousPost: Double?
  let integratedNativeMotionResidual: Double?
  let preNativeOrigin: Double
  let postNativeOrigin: Double
  let previousPostNativeOrigin: Double?
  let nativePanDeltaSincePreviousPost: Double?
  let insetOriginDelta: Double
  let panTranslationY: Double
  let panTranslationDeltaSincePrevious: Double?
  let preNativeBounce: Double
  let viewportAdjustment: String
  let desiredOrigin: Double?
  let legalOrigin: Double?
  let expectedPostOrigin: Double?
  let expectedPostGlyphY: Double?
  let glyphResidual: Double?
  let packageOriginResidual: Double?
  let nativeOriginResidual: Double?
  let legalClamp: Bool?
  let nativeDraggingAtStart: Bool
  let nativeDeceleratingAtStart: Bool
  let userScrollingAtStart: Bool
}

private struct KeyboardEvidence: Codable {
  var before: KeyboardFrameEvidence?
  var open: KeyboardFrameEvidence?
  var close: KeyboardFrameEvidence?
  var settledClose: KeyboardFrameEvidence?
  var frames: [KeyboardFrameEvidence] = []
  var transactions: [KeyboardTransactionEvidence] = []
  var focusEvents: [String] = []
  var keyboardNotifications: [String] = []
  var movingSamples = 0
  var maxAbsoluteResidual: Double = 0
  var legalClampSamples = 0
  var fixedWitnessOffscreenSamples = 0
  var integratedNativeMotionSamples = 0
  var maxAbsoluteIntegratedNativeMotionResidual: Double = 0
  var userGestureObserved = false
  var failureCount = 0
  var failures: [String] = []
}

private struct ReplayProgress: Codable {
  let state: String
  let requestedEvents: Int
  let completedEvents: Int
  let focusedEventsCompleted: Int
  let virtualPresentationSamples: Int
  let failureCount: Int
  let uptime: Double
}

/// A display-link callback samples UIKit geometry; it does not prove a compositor-delivered pixel frame.
private struct RotationFrameEvidence: Codable {
  let transition: Int
  let stage: String
  let uptime: Double
  let rootWidth: Double
  let listWidth: Double
  let nativeViewportWidth: Double
  let nativeCanvasWidth: Double
  let installedSnapshotWidth: Double?
  let publishedLayoutWidth: Double
  let requestedContextWidth: Double
  let preparationPending: Bool
  let nativeVisibleCells: Int
  let cellFrameMismatches: Int
  let mixedGeometry: Bool
  let witnessRow: Int64?
  let witnessCharacter: Int?
  let nativeGlyphViewportY: Double?
  let expectedGlyphViewportY: Double?
  let glyphResidual: Double?
  let originResidual: Double?
  let legalClamp: Bool?
  let witnessError: String?
  let intent: String
  let isUserScrolling: Bool
}

private struct RotationTransitionEvidence: Codable {
  let number: Int
  let fromWidth: Double
  let requestedWidth: Double
  var firstLayout: RotationFrameEvidence?
  var firstPublication: RotationFrameEvidence?
  var firstDisplayLinkSample: RotationFrameEvidence?
  var settled: RotationFrameEvidence?
}

private struct RotationEvidence: Codable {
  var displayEvidenceLevel = "CADisplayLink callback geometry; compositor delivery and pixels unmeasured"
  var transitions: [RotationTransitionEvidence] = []
  var firstLayoutMismatches = 0
  var firstPublicationMismatches = 0
  var firstDisplayMismatches = 0
  var maxAbsoluteGlyphResidual: Double = 0
}

/// The first two stages are native geometry observations, not proof of composited pixels.
private struct OwnershipFrameEvidence: Codable {
  let stage: String
  let uptime: Double
  let row: Int64?
  let character: Int?
  let nativeGlyphY: Double?
  let usableBottomY: Double
  let nativeOrigin: Double
  let packageOrigin: Double
  let expectedGlyphY: Double?
  let glyphResidual: Double?
  let originResidual: Double?
  let nativeOriginResidual: Double?
  let legalClamp: Bool?
  let intent: String
  let isUserScrolling: Bool
  let nativeDragging: Bool
}

private struct OwnershipEvidence: Codable {
  var evidenceLevel = "synchronous publication and CADisplayLink callback geometry; pixels unmeasured"
  var initialPublication: OwnershipFrameEvidence?
  var initialDisplay: OwnershipFrameEvidence?
  var beforeStationaryInset: OwnershipFrameEvidence?
  var firstInsetPublication: OwnershipFrameEvidence?
  var firstInsetDisplay: OwnershipFrameEvidence?
  var firstUserDrag: OwnershipFrameEvidence?
  var pressCount = 0
  var validStationaryPressCount = 0
  var insetCount = 0
  var dragCount = 0
  var spuriousUserScrollingCount = 0
  var maxAbsoluteFirstFrameGlyphResidual: Double = 0
  var maximumDragOriginDelta: Double = 0
  var failures: [String] = []
}

@MainActor
final class PhoneLabController: UIViewController, UIGestureRecognizerDelegate {
  private struct GlyphWitness {
    let row: Int64
    let character: Int
    let y: CGFloat
    let edge: TimelineAnchorEdge
    let viewportPoint: CGFloat
    let edgeDistance: CGFloat
    let rowFrame: CGRect
    let localY: CGFloat
    let bodyFrame: CGRect
    let textOffset: CGFloat
  }

  private let session = ChatListSession<Int64, LabContent>()
  private lazy var list = ChatListView<Int64, LabContent>(
    session: session,
    configuration: .init(usesAutomaticDisplayClock: !(replayRequested || keyboardFixtureRequested)),
    makeCell: { _, recycled in recycled ?? PhoneLabTextCell(frame: .zero) }
  )
  private var scenario = LabScenario()
  private var probe = LabGeometryProbe()
  private var replay = LabReplay()
  private let replayRequested = CommandLine.arguments.contains("--replay")
    || CommandLine.arguments.contains("--replay-events")
  private let requestedReplayEvents: Int = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--replay-events"),
          arguments.indices.contains(index + 1),
          let count = Int(arguments[index + 1]) else { return 2_048 }
    return min(2_048, max(0, count))
  }()
  private let bottomOcclusionFixtureRequested = CommandLine.arguments.contains("--bottom-occlusion-test")
  private let keyboardFixtureRequested = CommandLine.arguments.contains("--keyboard-test")
  /// The list tracks the keyboard itself (no lab sampling adapter).
  private let hostKeyboardRequested = CommandLine.arguments.contains("--host-keyboard")
  private let reorderRequested = CommandLine.arguments.contains("--reorder")
  /// Bars on the keyboard edge and the list's usable edge, to compare in a recording.
  private let markersRequested = CommandLine.arguments.contains("--markers")
  private let keyboardMarker = UIView()
  private let listMarker = UIView()
  private let resizeFixtureRequested = CommandLine.arguments.contains("--resize-test")
  private let rotationFixtureRequested = CommandLine.arguments.contains("--rotation-test")
  private let ownershipFixtureRequested = CommandLine.arguments.contains("--interaction-ownership-test")
  private let controls = UIStackView()
  private let status = UILabel()
  private let keyboardField = UITextField()
  private let keyboardGuideProbe = UIView()
  private let keyboardSamplesLabel = UILabel()
  private let keyboardMaxDriftLabel = UILabel()
  private let keyboardFailuresLabel = UILabel()
  private let keyboardSystemEdgeLabel = UILabel()
  private let sessionIntentLabel = UILabel()
  private let rotationFirstFrameLabel = UILabel()
  private let rotationFirstDisplayLabel = UILabel()
  private let rotationGlyphLabel = UILabel()
  private let ownershipPublicationLabel = UILabel()
  private let ownershipDisplayLabel = UILabel()
  private let ownershipPhaseLabel = UILabel()
  private let ownershipGlyphLabel = UILabel()
  private let topOcclusion = UIView()
  private let bottomOcclusion = UIView()
  private let decorations = PhoneDecorations()
  private var replayRunning = false
  private var hasStartedLaunchReplay = false
  private var launchReplayScheduled = false
  private var hasStartedBottomOcclusionFixture = false
  private var widthReduction: CGFloat = 0
  private var heightReduction: CGFloat = 0
  private var transactionTime: Double?
  private var manualClock: Double?
  private var keyboardDisplayLink: CADisplayLink?
  private var keyboardSettlingFrames = 0
  private var keyboardTransitionActive = false
  private var sampledKeyboardOverlap: CGFloat = 0
  private var keyboardWitness: KeyboardWitness?
  private var keyboardEvidence = KeyboardEvidence()
  private var keyboardSystemEndScreenY: CGFloat?
  private var keyboardReportPending = false
  private var lastKeyboardTransaction: KeyboardTransactionEvidence?
  private var rotationDisplayLink: CADisplayLink?
  private var rotationEvidence = RotationEvidence()
  private var rotationWitness: GlyphWitness?
  private var rotationInitialWidth: CGFloat?
  private var rotationDisplayTickSeen = false
  private var rotationCompletionSeen = false
  private var ownershipDisplayLink: CADisplayLink?
  private var ownershipPressRecognizer: UILongPressGestureRecognizer?
  private var ownershipEvidence = OwnershipEvidence()
  private var ownershipWitness: GlyphWitness?
  private var ownershipInsetSubmitting = false
  private var ownershipAwaitingInsetDisplay = false
  private var ownershipPressActive = false
  private var ownershipDidApplyInset = false
  private var ownershipWasDragging = false
  private var ownershipPreInsetOrigin: CGFloat?
  private var ownershipPreMaximumOrigin: CGFloat?
  private var ownershipDragStartOrigin: CGFloat?
  private let ownershipReportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("InteractionOwnershipLabResults-\(UUID().uuidString).json")
  private let rotationReportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("RotationLabResults-\(UUID().uuidString).json")
  private let keyboardReportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("KeyboardLabResults-\(UUID().uuidString).json")
  private let replayProgressURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ChatListReplayProgress.json")

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    controls.axis = .vertical
    controls.spacing = 4
    for row in [
      [("Older", LabOperation.prepend), ("Newer", .append), ("Delete", .delete), ("Height", .toggleHeight)],
      [("Top", LabOperation.topInset), ("Bottom", .bottomInset), ("Both", .heightAndInset), ("Width", .resizeWidth)]
    ] {
      let buttons = UIStackView()
      buttons.axis = .horizontal
      buttons.spacing = 4
      buttons.distribution = .fillEqually
      for (label, operation) in row {
        buttons.addArrangedSubview(button(label) { [weak self] in self?.perform(operation) })
      }
      controls.addArrangedSubview(buttons)
    }
    let navigation = UIStackView()
    navigation.axis = .horizontal
    navigation.spacing = 4
    navigation.distribution = .fillEqually
    navigation.addArrangedSubview(button("Latest") { [weak self] in self?.showLatest() })
    navigation.addArrangedSubview(button("Jump") { [weak self] in
      guard let self, let first = self.scenario.ids.first else { return }
      self.session.scroll(to: .init(id: first, position: .top(0)), at: CACurrentMediaTime())
    })
    if !keyboardFixtureRequested {
      navigation.addArrangedSubview(button("Replay") { [weak self] in self?.startReplay() })
    }
    if bottomOcclusionFixtureRequested || keyboardFixtureRequested {
      let position = button("Bottom Row") { [weak self] in self?.positionBottomOcclusionFixture() }
      position.accessibilityIdentifier = "lab-bottom-position"
      navigation.addArrangedSubview(position)
    }
    if hostKeyboardRequested {
      navigation.addArrangedSubview(button("Keyboard") { [weak self] in
        guard let self else { return }
        if self.keyboardField.isFirstResponder { self.keyboardField.resignFirstResponder() }
        else { _ = self.keyboardField.becomeFirstResponder() }
      })
    }
    if keyboardFixtureRequested {
      let show = button("Show Keyboard") { [weak self] in
        guard let self else { return }
        _ = self.keyboardField.becomeFirstResponder()
        self.recordKeyboardFocus("show button")
      }
      show.accessibilityIdentifier = "lab-keyboard-show"
      navigation.addArrangedSubview(show)
    }
    if resizeFixtureRequested {
      let resize = button("Resize Viewport") { [weak self] in self?.resizeViewportFixture() }
      resize.accessibilityIdentifier = "lab-viewport-resize"
      navigation.addArrangedSubview(resize)
    }
    controls.addArrangedSubview(navigation)
    if hostKeyboardRequested {
      keyboardField.borderStyle = .roundedRect
      keyboardField.placeholder = "Composer (list tracks the keyboard)"
      keyboardField.autocorrectionType = .no
      keyboardField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
      controls.addArrangedSubview(keyboardField)
    }
    if keyboardFixtureRequested {
      keyboardField.borderStyle = .roundedRect
      keyboardField.placeholder = "Open the actual keyboard"
      keyboardField.autocorrectionType = .no
      keyboardField.accessibilityIdentifier = "lab-keyboard-field"
      keyboardField.accessibilityValue = "focused false"
      keyboardField.setContentCompressionResistancePriority(.required, for: .vertical)
      keyboardField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
      keyboardField.addTarget(self, action: #selector(keyboardEditingBegan), for: .editingDidBegin)
      keyboardField.addTarget(self, action: #selector(keyboardEditingEnded), for: .editingDidEnd)
      let keyboardRow = UIStackView(arrangedSubviews: [
        keyboardField,
        button("Dismiss") { [weak self] in self?.keyboardField.resignFirstResponder() }
      ])
      keyboardRow.axis = .horizontal
      keyboardRow.spacing = 4
      keyboardRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      keyboardRow.arrangedSubviews.last?.accessibilityIdentifier = "lab-keyboard-dismiss"
      controls.addArrangedSubview(keyboardRow)
    }
    if keyboardFixtureRequested || resizeFixtureRequested || rotationFixtureRequested
      || ownershipFixtureRequested {
      let metrics = UIStackView()
      metrics.axis = .horizontal
      metrics.spacing = 8
      metrics.distribution = .fillEqually
      sessionIntentLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
      sessionIntentLabel.accessibilityIdentifier = "lab-session-intent"
      metrics.addArrangedSubview(sessionIntentLabel)
      if keyboardFixtureRequested {
        for label in [keyboardSamplesLabel, keyboardMaxDriftLabel,
                      keyboardFailuresLabel, keyboardSystemEdgeLabel] {
          label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
          metrics.addArrangedSubview(label)
        }
        keyboardSamplesLabel.accessibilityIdentifier = "lab-keyboard-samples"
        keyboardMaxDriftLabel.accessibilityIdentifier = "lab-keyboard-max-drift"
        keyboardFailuresLabel.accessibilityIdentifier = "lab-keyboard-failures"
        keyboardSystemEdgeLabel.accessibilityIdentifier = "lab-keyboard-system-edge"
        keyboardSystemEdgeLabel.text = "system edge unavailable"
      }
      if rotationFixtureRequested {
        for label in [rotationFirstFrameLabel, rotationFirstDisplayLabel, rotationGlyphLabel] {
          label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
          metrics.addArrangedSubview(label)
        }
        rotationFirstFrameLabel.accessibilityIdentifier = "lab-rotation-first-frame"
        rotationFirstDisplayLabel.accessibilityIdentifier = "lab-rotation-first-display"
        rotationGlyphLabel.accessibilityIdentifier = "lab-rotation-max-glyph-drift"
      }
      if ownershipFixtureRequested {
        for label in [ownershipPublicationLabel, ownershipDisplayLabel,
                      ownershipPhaseLabel, ownershipGlyphLabel] {
          label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
          metrics.addArrangedSubview(label)
        }
        ownershipPublicationLabel.accessibilityIdentifier = "lab-ownership-first-publication"
        ownershipDisplayLabel.accessibilityIdentifier = "lab-ownership-first-display"
        ownershipPhaseLabel.accessibilityIdentifier = "lab-ownership-phase"
        ownershipGlyphLabel.accessibilityIdentifier = "lab-ownership-max-glyph-drift"
      }
      controls.addArrangedSubview(metrics)
    }
    status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    status.numberOfLines = 2
    status.text = "Native text · prepared geometry"
    status.accessibilityIdentifier = "lab-status"
    topOcclusion.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.36)
    bottomOcclusion.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.36)
    topOcclusion.isUserInteractionEnabled = false
    bottomOcclusion.isUserInteractionEnabled = false
    view.addSubview(controls)
    view.addSubview(list)
    view.addSubview(status)
    if keyboardFixtureRequested {
      keyboardGuideProbe.isUserInteractionEnabled = false
      keyboardGuideProbe.backgroundColor = .clear
      keyboardGuideProbe.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(keyboardGuideProbe)
      NSLayoutConstraint.activate([
        keyboardGuideProbe.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        keyboardGuideProbe.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        keyboardGuideProbe.widthAnchor.constraint(equalToConstant: 1),
        keyboardGuideProbe.heightAnchor.constraint(equalToConstant: 1)
      ])
      for (name, selector) in [
        (UIResponder.keyboardWillShowNotification, #selector(keyboardWillShow(_:))),
        (UIResponder.keyboardDidShowNotification, #selector(keyboardDidShow(_:))),
        (UIResponder.keyboardWillChangeFrameNotification, #selector(keyboardWillChangeFrame(_:))),
        (UIResponder.keyboardDidChangeFrameNotification, #selector(keyboardDidChangeFrame(_:))),
        (UIResponder.keyboardWillHideNotification, #selector(keyboardWillHide(_:))),
        (UIResponder.keyboardDidHideNotification, #selector(keyboardDidHide(_:)))
      ] {
        NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
      }
      list.scrollView.keyboardDismissMode = .interactive
    }
    if hostKeyboardRequested { list.tracksKeyboard = true }
    session.onScrollEvent = { [weak self] event in
      if event == .navigationFinished { self?.status.text = "Navigation finished" }
    }
    if markersRequested {
      keyboardMarker.backgroundColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1)
      keyboardMarker.accessibilityIdentifier = "lab-marker-keyboard"
      keyboardMarker.isAccessibilityElement = true
      keyboardMarker.translatesAutoresizingMaskIntoConstraints = false
      keyboardMarker.isUserInteractionEnabled = false
      view.addSubview(keyboardMarker)
      NSLayoutConstraint.activate([
        keyboardMarker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        keyboardMarker.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
        keyboardMarker.heightAnchor.constraint(equalToConstant: 6),
        keyboardMarker.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
      ])
      listMarker.backgroundColor = UIColor(red: 1, green: 0, blue: 1, alpha: 1)
      listMarker.accessibilityIdentifier = "lab-marker-list"
      listMarker.isAccessibilityElement = true
      listMarker.isUserInteractionEnabled = false
    }
    if reorderRequested {
      session.canReorder = { _ in true }
      session.onReorder = { [weak self] move in
        guard let self else { return }
        self.scenario.move(move.id, to: move.toIndex)
        self.applyCurrent(at: CACurrentMediaTime())
        self.status.text = "Reordered \(move.id) from \(move.fromIndex) to \(move.toIndex)"
      }
      list.cellReorderStateChanged = { cell, lifted in
        UIView.animate(withDuration: 0.2) {
          cell.transform = lifted ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
          cell.alpha = lifted ? 0.92 : 1
        }
      }
      list.isReorderingEnabled = true
    }
    list.accessibilityIdentifier = "lab-list"
    list.scrollView.accessibilityIdentifier = "lab-scroll"
    if ownershipFixtureRequested {
      let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(ownershipPress(_:)))
      recognizer.minimumPressDuration = 0
      recognizer.allowableMovement = 12
      recognizer.cancelsTouchesInView = false
      recognizer.delegate = self
      list.scrollView.addGestureRecognizer(recognizer)
      ownershipPressRecognizer = recognizer
    }

    list.bindCell = { view, item, _ in (view as? PhoneLabTextCell)?.bind(item) }
    list.presentCell = { view, placement in (view as? PhoneLabTextCell)?.present(placement) }
    list.recycleCell = { view in (view as? PhoneLabTextCell)?.recycle() }
    list.captureCellAnchor = { view, _, visible in (view as? PhoneLabTextCell)?.capture(visible) }
    list.resolveCellAnchor = { view, _, anchor in (view as? PhoneLabTextCell)?.resolve(anchor) }
    list.presentOverlays = { [weak self] root, layout in
      guard let self else { return }
      if self.topOcclusion.superview !== root { root.addSubview(self.topOcclusion) }
      if self.bottomOcclusion.superview !== root { root.addSubview(self.bottomOcclusion) }
      self.topOcclusion.frame = CGRect(
        x: 0, y: 0, width: layout.viewport.width, height: layout.viewport.topInset
      )
      self.bottomOcclusion.frame = CGRect(
        x: 0, y: layout.viewport.height - layout.viewport.bottomInset,
        width: layout.viewport.width, height: layout.viewport.bottomInset
      )
      self.decorations.present(in: root, placements: self.session.decorationPlacements)
      if self.markersRequested {
        if self.listMarker.superview !== root { root.addSubview(self.listMarker) }
        self.listMarker.frame = CGRect(
          x: layout.viewport.width / 2, y: layout.viewport.height - layout.viewport.bottomInset - 6,
          width: layout.viewport.width / 2, height: 6
        )
      }
    }
    session.onNeedsSnapshot = { [weak self] _ in
      guard let self else { return }
      _ = self.applyCurrent(at: self.transactionTime ?? ProcessInfo.processInfo.systemUptime, animation: .none)
    }
    session.onPreparationError = { [weak self] error in self?.status.text = "Preparation: \(error)" }
    session.onPresentationChanged = { [weak self] in
      self?.updateSessionIntentLabel()
      self?.recordRotationFirstPublicationIfNeeded()
      self?.recordOwnershipPublicationIfNeeded()
      self?.scheduleLaunchReplayIfReady()
    }
    updateSessionIntentLabel()
    updateRotationLabels()
    updateOwnershipLabels()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets
    let controlsHeight: CGFloat = keyboardFixtureRequested ? 205
      : ((resizeFixtureRequested || rotationFixtureRequested || ownershipFixtureRequested) ? 138 : 112)
    controls.frame = CGRect(x: 8, y: safe.top + 4, width: view.bounds.width - 16, height: controlsHeight)
    let listTop = controls.frame.maxY + 7
    let statusHeight: CGFloat = 35
    list.frame = CGRect(
      x: widthReduction / 2, y: listTop, width: max(180, view.bounds.width - widthReduction),
      height: max(1, view.bounds.height - listTop - safe.bottom - statusHeight - heightReduction)
    )
    status.frame = CGRect(x: 12, y: list.frame.maxY + 3, width: view.bounds.width - 24, height: statusHeight)
    list.layoutIfNeeded()
    recordRotationFirstLayoutIfNeeded()
  }

  override func viewWillTransition(
    to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
  ) {
    if rotationFixtureRequested, session.snapshot != nil, view.window != nil {
      if let prior = rotationWitness { list.unpinCell(for: prior.row) }
      rotationWitness = witness(edge: currentReadingEdge)
      if let rotationWitness { list.pinCell(for: rotationWitness.row) }
      rotationInitialWidth = list.bounds.width
      rotationDisplayTickSeen = false
      rotationCompletionSeen = false
      rotationEvidence.transitions.append(.init(
        number: rotationEvidence.transitions.count + 1,
        fromWidth: Double(list.bounds.width), requestedWidth: Double(size.width)
      ))
      rotationDisplayLink?.isPaused = false
      status.text = "Rotation \(rotationEvidence.transitions.count) preparing"
      writeRotationEvidence()
      coordinator.animate(alongsideTransition: nil) { [weak self] _ in
        Task { @MainActor [weak self] in self?.finishRotationTransition() }
      }
    }
    super.viewWillTransition(to: size, with: coordinator)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if bottomOcclusionFixtureRequested, !hasStartedBottomOcclusionFixture {
      hasStartedBottomOcclusionFixture = true
      positionBottomOcclusionFixture()
    }
    if keyboardFixtureRequested, keyboardDisplayLink == nil {
      positionBottomOcclusionFixture()
      let link = CADisplayLink(target: self, selector: #selector(keyboardTick(_:)))
      link.add(to: .main, forMode: .common)
      link.isPaused = true
      keyboardDisplayLink = link
      _ = sampleKeyboard()
    }
    if rotationFixtureRequested, rotationDisplayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(rotationTick(_:)))
      link.add(to: .main, forMode: .common)
      link.isPaused = true
      rotationDisplayLink = link
    }
    if ownershipFixtureRequested, ownershipDisplayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(ownershipTick(_:)))
      link.add(to: .main, forMode: .common)
      ownershipDisplayLink = link
    }
    scheduleLaunchReplayIfReady()
  }

  private func scheduleLaunchReplayIfReady() {
    guard replayRequested, !hasStartedLaunchReplay, !launchReplayScheduled,
          view.window != nil else { return }
    guard session.snapshot != nil else {
      status.text = "Replay waiting for initial snapshot"
      return
    }
    launchReplayScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.launchReplayScheduled = false
      guard self.replayRequested, !self.hasStartedLaunchReplay,
            self.session.snapshot != nil else { return }
      self.hasStartedLaunchReplay = true
      self.startReplay()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    keyboardDisplayLink?.invalidate()
    keyboardDisplayLink = nil
    rotationDisplayLink?.invalidate()
    rotationDisplayLink = nil
    ownershipDisplayLink?.invalidate()
    ownershipDisplayLink = nil
  }

  private func button(_ label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(label, for: .normal)
    button.accessibilityIdentifier = "lab-\(label.lowercased())"
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    button.configuration = .tinted()
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  private func updateViewport(
    at time: Double, animation: ChatListAnimation,
    adjustment: ChatListViewportAdjustment = .preserveAnchor,
    bottomInsetOverride: CGFloat? = nil
  ) {
    guard list.bounds.width > 0, list.bounds.height > 0 else { return }
    if hostKeyboardRequested {
      list.setInsets(top: scenario.topInset, bottomAccessory: bottomInsetOverride ?? scenario.bottomInset,
                     animation: animation)
      return
    }
    transactionTime = time
    session.updateViewport(
      .init(width: list.bounds.width, height: list.bounds.height,
            topInset: scenario.topInset,
            bottomInset: min(list.bounds.height,
                             (bottomInsetOverride ?? scenario.bottomInset) + sampledKeyboardOverlap)),
      displayScale: view.window?.screen.scale ?? UIScreen.main.scale,
      animation: animation, at: time, viewportAdjustment: adjustment
    )
    transactionTime = nil
  }

  @discardableResult
  private func applyCurrent(at time: Double, animation: ChatListAnimation = .animated) -> Bool {
    let context = session.layoutContext
    guard context.width > 0 else { return false }
    do {
      _ = try session.apply(
        scenario.snapshot(width: context.width, scale: context.displayScale,
                          environmentRevision: context.environmentRevision),
        intent: ownershipFixtureRequested && session.snapshot == nil
          ? .reading(.init(id: 352, localY: 140, viewportY: 20, edge: .bottom)) : nil,
        animation: animation, at: time
      )
      return true
    } catch {
      status.text = "Apply failed: \(error)"
      return false
    }
  }

  private func perform(_ operation: LabOperation) {
    guard !replayRunning else { return }
    let time = nextTime()
    scenario.perform(operation, visibleID: session.timeline.layout.anchor()?.id)
    if operation == .resizeWidth { resizeList(at: time) }
    let generation = session.generation
    if operation.changesViewport { updateViewport(at: time, animation: .animated) }
    if session.generation == generation { _ = applyCurrent(at: time) }
    if manualClock != nil { list.advance(to: time + 0.4) }
    if keyboardFixtureRequested { keyboardDisplayLink?.isPaused = false }
    status.text = "\(scenario.eventCount) · \(operation) · \(scenario.ids.count) rows"
  }

  private func showLatest() {
    let time = nextTime()
    session.navigate(to: .latest, animation: .animated, at: time)
    if manualClock != nil { list.advance(to: time + 0.4) }
    if keyboardFixtureRequested { keyboardDisplayLink?.isPaused = false }
  }

  private func positionBottomOcclusionFixture() {
    let time = ProcessInfo.processInfo.systemUptime
    updateViewport(at: time, animation: .none)
    if session.snapshot == nil { _ = applyCurrent(at: time, animation: .none) }
    session.navigate(
      to: .reading(.init(id: 352, localY: 140, viewportY: 20, edge: .bottom)),
      animation: .none, at: time
    )
    status.text = "Bottom fixture · message 352"
  }

  private func resizeViewportFixture() {
    let time = ProcessInfo.processInfo.systemUptime
    heightReduction = heightReduction == 0 ? 100 : 0
    view.setNeedsLayout()
    view.layoutIfNeeded()
    updateViewport(at: time, animation: .none)
    list.advance(to: time)
    updateSessionIntentLabel()
    status.text = "Viewport height \(Int(list.bounds.height))"
  }

  private func updateSessionIntentLabel() {
    guard keyboardFixtureRequested || resizeFixtureRequested || rotationFixtureRequested
      || ownershipFixtureRequested else { return }
    let intent: String = switch session.timeline.intent {
    case .latest: "latest"
    case .reading: "reading"
    }
    sessionIntentLabel.text = "\(intent); userScrolling=\(session.isUserScrolling)"
  }

  private func captureKeyboardWitness(usableBottom: CGFloat) {
    guard keyboardWitness == nil,
          let placement = session.timeline.layout.placement(for: 352),
          let cell = list.cell(for: 352) as? PhoneLabTextCell else { return }
    let reading = session.timeline.layout.readingRect
    let visible = reading.intersection(placement.frame).offsetBy(
      dx: -placement.frame.minX, dy: -placement.frame.minY
    )
    guard !visible.isNull, let anchor = cell.capture(visible),
          let token = anchor.token.base as? PhoneGlyphToken,
          let glyphY = cell.glyphY(token.character, in: view) else { return }
    keyboardWitness = .init(
      row: token.row, character: token.character,
      initialDistance: usableBottom - glyphY
    )
  }

  @objc private func keyboardEditingBegan() { recordKeyboardFocus("editing began") }

  @objc private func keyboardEditingEnded() { recordKeyboardFocus("editing ended") }

  private func recordKeyboardFocus(_ reason: String) {
    keyboardField.accessibilityValue = "focused \(keyboardField.isFirstResponder)"
    let event = "\(reason): firstResponder=\(keyboardField.isFirstResponder), " +
      "field=\(keyboardField.convert(keyboardField.bounds, to: view)), " +
      "guideTop=\(view.keyboardLayoutGuide.layoutFrame.minY)"
    keyboardEvidence.focusEvents.append(event)
    NSLog("ChatListPhoneLab keyboard focus: %@", event)
    if keyboardField.isFirstResponder { keyboardDisplayLink?.isPaused = false }
    writeKeyboardEvidence()
  }

  private func recordKeyboardNotification(_ name: String, _ notification: Notification) {
    let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    keyboardSystemEndScreenY = frame?.minY
    keyboardSystemEdgeLabel.text = frame.map {
      String(format: "system edge %.2f pt", $0.minY)
    } ?? "system edge unavailable"
    let event = "\(name): firstResponder=\(keyboardField.isFirstResponder), " +
      "endScreenFrame=\(String(describing: frame)), " +
      "guideTop=\(view.keyboardLayoutGuide.layoutFrame.minY)"
    if keyboardEvidence.keyboardNotifications.count < 64 {
      keyboardEvidence.keyboardNotifications.append(event)
    }
    NSLog("ChatListPhoneLab keyboard notification: %@", event)
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    recordKeyboardNotification("willShow", notification)
    keyboardSystemEndScreenY = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
      .cgRectValue.minY
    let before = sampleKeyboard()
    if keyboardEvidence.before == nil { keyboardEvidence.before = before }
    if keyboardWitness == nil { recordKeyboardFailure("No native row 352 glyph before keyboard opening") }
    keyboardTransitionActive = true
    keyboardSettlingFrames = 0
    keyboardDisplayLink?.isPaused = false
  }

  @objc private func keyboardDidShow(_ notification: Notification) {
    recordKeyboardNotification("didShow", notification)
    keyboardSystemEndScreenY = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
      .cgRectValue.minY
    keyboardEvidence.open = sampleKeyboard()
    keyboardTransitionActive = false
    keyboardSettlingFrames = 4
    keyboardDisplayLink?.isPaused = false
    writeKeyboardEvidence()
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    recordKeyboardNotification("willHide", notification)
    keyboardSystemEndScreenY = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
      .cgRectValue.minY
    keyboardTransitionActive = true
    keyboardSettlingFrames = 0
    keyboardDisplayLink?.isPaused = false
  }

  @objc private func keyboardDidHide(_ notification: Notification) {
    recordKeyboardNotification("didHide", notification)
    keyboardSystemEndScreenY = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
      .cgRectValue.minY
    keyboardEvidence.close = sampleKeyboard()
    keyboardTransitionActive = false
    keyboardSettlingFrames = 4
    keyboardReportPending = true
    keyboardDisplayLink?.isPaused = false
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    recordKeyboardNotification("willChangeFrame", notification)
    keyboardSystemEndScreenY = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
      .cgRectValue.minY
    keyboardTransitionActive = true
    keyboardSettlingFrames = 0
    keyboardDisplayLink?.isPaused = false
  }

  @objc private func keyboardDidChangeFrame(_ notification: Notification) {
    recordKeyboardNotification("didChangeFrame", notification)
    _ = sampleKeyboard()
    writeKeyboardEvidence()
  }

  @objc private func keyboardTick(_ link: CADisplayLink) { _ = sampleKeyboard(link: link) }

  @discardableResult
  private func sampleKeyboard(link: CADisplayLink? = nil) -> KeyboardFrameEvidence {
    let time = ProcessInfo.processInfo.systemUptime
    view.layoutIfNeeded()
    let presentationTop = keyboardGuideProbe.layer.presentation()?.frame.minY
      ?? keyboardGuideProbe.frame.minY
    let layoutGuideTop = view.keyboardLayoutGuide.layoutFrame.minY
    let overlap = min(list.bounds.height, max(0, list.frame.maxY - presentationTop))
    let oldLayout = session.timeline.layout
    let oldUsableBottom = list.frame.maxY - oldLayout.viewport.bottomInset
    captureKeyboardWitness(usableBottom: oldUsableBottom)
    let fixedWitness = keyboardWitness
    let fixedRowIntersectsReading = fixedWitness.flatMap { witness in
      oldLayout.placement(for: witness.row)?.frame.intersects(oldLayout.readingRect)
    }
    let fixedGlyphBefore = fixedWitness.flatMap { witness in
      (list.cell(for: witness.row) as? PhoneLabTextCell)?.glyphY(witness.character, in: view)
    }
    let fixedGlyphInUsableViewport = fixedGlyphBefore.map {
      $0 >= list.frame.minY + oldLayout.viewport.topInset && $0 <= oldUsableBottom
    } ?? false
    let preNativeOrigin = list.scrollView.contentOffset.y
    let preLegalOrigin = min(oldLayout.maximumOrigin, max(0, preNativeOrigin))
    let preNativeBounce = preNativeOrigin - preLegalOrigin
    let wasDragging = list.scrollView.isDragging
    let wasUserScrolling = session.isUserScrolling
    if wasDragging || wasUserScrolling { keyboardEvidence.userGestureObserved = true }
    // An intentional drag can scroll the original endpoint glyph entirely out
    // of the native resident window. Select a fresh visible point before this
    // inset submission, then hold only that point through the same tick.
    let visibleWitness = keyboardEvidence.userGestureObserved ? witness(edge: .bottom) : nil
    let transactionRow = keyboardEvidence.userGestureObserved ? visibleWitness?.row : fixedWitness?.row
    let transactionCharacter = keyboardEvidence.userGestureObserved
      ? visibleWitness?.character : fixedWitness?.character
    let preGlyphY: CGFloat? = transactionRow.flatMap { (row: Int64) -> CGFloat? in
      guard let transactionCharacter else { return nil }
      return (list.cell(for: row) as? PhoneLabTextCell)?.glyphY(transactionCharacter, in: view)
    }
    let panTranslationY = list.scrollView.panGestureRecognizer.translation(in: list.scrollView).y
    let adjustment: ChatListViewportAdjustment = wasDragging ? .nativeInput : .preserveAnchor
    let context = session.layoutContext
    let submittedInset = context.width > 0 && abs(overlap - sampledKeyboardOverlap) > 0.01
    if submittedInset, let transactionRow { list.pinCell(for: transactionRow) }
    defer { if submittedInset, let transactionRow { list.unpinCell(for: transactionRow) } }
    if context.width > 0 {
      if submittedInset {
        sampledKeyboardOverlap = overlap
        updateViewport(at: time, animation: .none, adjustment: adjustment)
      }
      list.advance(to: time)
    }
    let layout = session.timeline.layout
    let usableBottom = list.frame.maxY - layout.viewport.bottomInset
    captureKeyboardWitness(usableBottom: usableBottom)
    let glyphY = keyboardWitness.flatMap { witness in
      (list.cell(for: witness.row) as? PhoneLabTextCell)?.glyphY(witness.character, in: view)
    }
    let distance = glyphY.map { usableBottom - $0 }
    var expectedDistance: CGFloat?
    var originResidual: CGFloat?
    var legalClamp: Bool?
    if let witness = keyboardWitness,
       let placement = layout.placement(for: witness.row),
       let cell = list.cell(for: witness.row) as? PhoneLabTextCell,
       let localY = cell.localGlyphY(witness.character) {
      let documentY = placement.frame.minY + localY
      let targetPoint = layout.viewport.height - layout.viewport.bottomInset - witness.initialDistance
      let desiredOrigin = documentY - targetPoint
      let legalOrigin = min(layout.maximumOrigin, max(0, desiredOrigin))
      legalClamp = abs(desiredOrigin - legalOrigin) > 0.5
      expectedDistance = layout.viewport.height - layout.viewport.bottomInset - documentY + legalOrigin
      originResidual = layout.originY - legalOrigin
    }
    let residual = distance.flatMap { value in expectedDistance.map { value - $0 } }
    var transaction: KeyboardTransactionEvidence?
    if submittedInset {
      let postGlyphY: CGFloat? = transactionRow.flatMap { (row: Int64) -> CGFloat? in
        guard let transactionCharacter else { return nil }
        return (list.cell(for: row) as? PhoneLabTextCell)?.glyphY(transactionCharacter, in: view)
      }
      var desiredOrigin: CGFloat?
      var legalOrigin: CGFloat?
      var expectedPostOrigin: CGFloat?
      var expectedPostGlyphY: CGFloat?
      var transactionResidual: CGFloat?
      var packageOriginResidual: CGFloat?
      var nativeOriginResidual: CGFloat?
      var transactionClamp: Bool?
      if let transactionRow, let transactionCharacter, let preGlyphY,
         let placement = layout.placement(for: transactionRow),
         let cell = list.cell(for: transactionRow) as? PhoneLabTextCell,
         let localY = cell.localGlyphY(transactionCharacter) {
        let documentY = placement.frame.minY + localY
        let preDistance = oldUsableBottom - preGlyphY
        let targetLocalY = layout.viewport.height - layout.viewport.bottomInset - preDistance
        let desired = documentY - targetLocalY
        let legal = min(layout.maximumOrigin, max(0, desired))
        // During rubber-banding the boundary, not the reading anchor, owns the
        // viewport. Preserve the independently measured displacement from that
        // boundary across the inset submission.
        let expectedOrigin: CGFloat = if adjustment == .nativeInput {
          preNativeOrigin
        } else if preNativeBounce < -0.01 {
          preNativeBounce
        } else if preNativeBounce > 0.01 {
          layout.maximumOrigin + preNativeBounce
        } else {
          legal
        }
        desiredOrigin = desired
        legalOrigin = legal
        expectedPostOrigin = expectedOrigin
        expectedPostGlyphY = list.frame.minY + documentY - expectedOrigin
        transactionClamp = abs(desired - legal) > 0.5
        packageOriginResidual = layout.originY - expectedOrigin
        nativeOriginResidual = list.scrollView.contentOffset.y - expectedOrigin
        if let postGlyphY, let expectedPostGlyphY {
          transactionResidual = postGlyphY - expectedPostGlyphY
        }
      }
      let previous = lastKeyboardTransaction
      let sameWitness = previous?.row == transactionRow
        && previous?.character == transactionCharacter
      let previousPostGlyphY: Double? = sameWitness ? previous?.postGlyphY : nil
      let postGlyphDouble: Double? = postGlyphY.map(Double.init)
      let totalGlyphDelta: Double? = if let postGlyphDouble, let previousPostGlyphY {
        postGlyphDouble - previousPostGlyphY
      } else { nil }
      let previousPostNativeOrigin: Double? = previous?.postNativeOrigin
      let nativePanDelta: Double? = previousPostNativeOrigin.map {
        Double(preNativeOrigin) - $0
      }
      let previousPanTranslation: Double? = previous?.panTranslationY
      let panTranslationDelta: Double? = previousPanTranslation.map {
        Double(panTranslationY) - $0
      }
      let integratedResidual: Double? = if adjustment == .nativeInput,
        let totalGlyphDelta, let nativePanDelta {
        totalGlyphDelta + nativePanDelta
      } else { nil }
      let trace = KeyboardTransactionEvidence(
        time: time,
        displayLinkTimestamp: link?.timestamp,
        displayLinkTargetTimestamp: link?.targetTimestamp,
        row: transactionRow, character: transactionCharacter,
        fixedWitnessRowIntersectsReading: fixedRowIntersectsReading,
        fixedWitnessGlyphInUsableViewport: fixedGlyphInUsableViewport,
        visibleWitnessSelected: visibleWitness != nil,
        oldUsableBottom: Double(oldUsableBottom), newUsableBottom: Double(usableBottom),
        guideDelta: Double(usableBottom - oldUsableBottom),
        preGlyphY: preGlyphY.map(Double.init), postGlyphY: postGlyphDouble,
        previousPostGlyphY: previousPostGlyphY,
        totalGlyphDeltaSincePreviousPost: totalGlyphDelta,
        integratedNativeMotionResidual: integratedResidual,
        preNativeOrigin: Double(preNativeOrigin),
        postNativeOrigin: Double(list.scrollView.contentOffset.y),
        previousPostNativeOrigin: previousPostNativeOrigin,
        nativePanDeltaSincePreviousPost: nativePanDelta,
        insetOriginDelta: Double(list.scrollView.contentOffset.y - preNativeOrigin),
        panTranslationY: Double(panTranslationY),
        panTranslationDeltaSincePrevious: panTranslationDelta,
        preNativeBounce: Double(preNativeBounce),
        viewportAdjustment: adjustment == .nativeInput ? "nativeInput" : "preserveAnchor",
        desiredOrigin: desiredOrigin.map { Double($0) },
        legalOrigin: legalOrigin.map { Double($0) },
        expectedPostOrigin: expectedPostOrigin.map { Double($0) },
        expectedPostGlyphY: expectedPostGlyphY.map { Double($0) },
        glyphResidual: transactionResidual.map { Double($0) },
        packageOriginResidual: packageOriginResidual.map { Double($0) },
        nativeOriginResidual: nativeOriginResidual.map { Double($0) },
        legalClamp: transactionClamp,
        nativeDraggingAtStart: wasDragging,
        nativeDeceleratingAtStart: list.scrollView.isDecelerating,
        userScrollingAtStart: wasUserScrolling
      )
      transaction = trace
      lastKeyboardTransaction = trace
      if keyboardEvidence.transactions.count < 2_048 { keyboardEvidence.transactions.append(trace) }
    }
    let frame = KeyboardFrameEvidence(
      time: time, displayLinkTimestamp: link.map { $0.timestamp },
      displayLinkTargetTimestamp: link.map { $0.targetTimestamp },
      presentationTop: Double(presentationTop),
      layoutGuideTop: Double(layoutGuideTop),
      systemKeyboardEndScreenY: keyboardSystemEndScreenY.map { Double($0) },
      bottomInset: Double(layout.viewport.bottomInset), row: keyboardWitness?.row,
      character: keyboardWitness?.character, glyphY: glyphY.map { Double($0) },
      distanceToUsableBottom: distance.map { Double($0) },
      expectedDistance: expectedDistance.map { Double($0) }, legalClamp: legalClamp,
      originResidual: originResidual.map { Double($0) },
      residual: residual.map { Double($0) },
      endpointComparable: !keyboardEvidence.userGestureObserved,
      intent: String(describing: session.timeline.intent),
      isUserScrolling: session.isUserScrolling
    )
    if let transaction,
       abs(transaction.newUsableBottom - transaction.oldUsableBottom) > 0.25 {
      keyboardEvidence.movingSamples += 1
      if transaction.viewportAdjustment == "preserveAnchor", transaction.legalClamp == true {
        keyboardEvidence.legalClampSamples += 1
      }
      if keyboardEvidence.userGestureObserved && !transaction.fixedWitnessGlyphInUsableViewport {
        keyboardEvidence.fixedWitnessOffscreenSamples += 1
      }
      if transaction.viewportAdjustment == "nativeInput",
         let integrated = transaction.integratedNativeMotionResidual {
        keyboardEvidence.integratedNativeMotionSamples += 1
        keyboardEvidence.maxAbsoluteIntegratedNativeMotionResidual = max(
          keyboardEvidence.maxAbsoluteIntegratedNativeMotionResidual, abs(integrated)
        )
        if abs(integrated) > 2 {
          recordKeyboardFailure(
            "Moving frame \(keyboardEvidence.movingSamples): integrated native-only " +
              "glyph residual \(integrated), pan delta " +
              "\(transaction.nativePanDeltaSincePreviousPost ?? .nan), guide delta " +
              "\(transaction.guideDelta)"
          )
        }
      }
      if let residual = transaction.glyphResidual,
         let packageOriginResidual = transaction.packageOriginResidual,
         let nativeOriginResidual = transaction.nativeOriginResidual {
        keyboardEvidence.maxAbsoluteResidual = max(
          keyboardEvidence.maxAbsoluteResidual, Double(abs(residual))
        )
        if abs(residual) > 2 || abs(packageOriginResidual) > 2 || abs(nativeOriginResidual) > 2 {
          recordKeyboardFailure(
            "Moving frame \(keyboardEvidence.movingSamples): synchronous glyph residual \(residual), " +
              "package origin residual \(packageOriginResidual), native origin residual " +
              "\(nativeOriginResidual), guide \(transaction.oldUsableBottom)->" +
              "\(transaction.newUsableBottom), clamp \(transaction.legalClamp == true), " +
              "dragging \(wasDragging)"
          )
        }
      } else {
        recordKeyboardFailure(
          "Moving frame \(keyboardEvidence.movingSamples) has no visible same-tick native glyph; " +
            "fixed row intersects=\(transaction.fixedWitnessRowIntersectsReading == true), " +
            "fixed glyph visible=\(transaction.fixedWitnessGlyphInUsableViewport), " +
            "candidate row=\(String(describing: transaction.row)), " +
            "adjustment=\(transaction.viewportAdjustment)"
        )
      }
    }
    if keyboardEvidence.frames.count < 2_048 { keyboardEvidence.frames.append(frame) }
    keyboardSamplesLabel.text = "samples \(keyboardEvidence.movingSamples)"
    keyboardMaxDriftLabel.text = String(
      format: "max drift %.2f pt", keyboardEvidence.maxAbsoluteResidual
    )
    keyboardFailuresLabel.text = "failures \(keyboardEvidence.failureCount)"
    updateSessionIntentLabel()
    if keyboardSettlingFrames > 0 {
      keyboardSettlingFrames -= 1
    }
    if !keyboardTransitionActive, !keyboardField.isFirstResponder,
       !list.scrollView.isDragging, keyboardSettlingFrames == 0,
       !session.timeline.isAnimating,
       abs(presentationTop - layoutGuideTop) <= 0.5 {
      keyboardDisplayLink?.isPaused = true
      if keyboardReportPending {
        keyboardReportPending = false
        keyboardEvidence.settledClose = frame
        writeKeyboardEvidence()
      }
    }
    return frame
  }

  private func recordKeyboardFailure(_ message: String) {
    keyboardEvidence.failureCount += 1
    if keyboardEvidence.failures.count < 64 { keyboardEvidence.failures.append(message) }
    keyboardFailuresLabel.text = "failures \(keyboardEvidence.failureCount)"
  }

  private func writeKeyboardEvidence() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(keyboardEvidence).write(to: keyboardReportURL, options: .atomic)
      NSLog("ChatListPhoneLab keyboard report: %@", keyboardReportURL.path)
    } catch {
      status.text = "Keyboard report write failed: \(error)"
    }
  }

  private func recordRotationFirstLayoutIfNeeded() {
    guard rotationFixtureRequested, let initial = rotationInitialWidth,
          abs(list.bounds.width - initial) > 1,
          let index = rotationEvidence.transitions.indices.last,
          rotationEvidence.transitions[index].firstLayout == nil else { return }
    let frame = rotationSample(stage: "synchronous-layout")
    rotationEvidence.transitions[index].firstLayout = frame
    if frame.mixedGeometry { rotationEvidence.firstLayoutMismatches += 1 }
    updateRotationLabels()
    writeRotationEvidence()
  }

  private func recordRotationFirstPublicationIfNeeded() {
    guard rotationFixtureRequested, let initial = rotationInitialWidth,
          abs(list.bounds.width - initial) > 1,
          let index = rotationEvidence.transitions.indices.last,
          rotationEvidence.transitions[index].firstPublication == nil else { return }
    let frame = rotationSample(stage: "host-publication")
    rotationEvidence.transitions[index].firstPublication = frame
    if frame.mixedGeometry { rotationEvidence.firstPublicationMismatches += 1 }
    updateRotationLabels()
    writeRotationEvidence()
  }

  @objc private func rotationTick(_ link: CADisplayLink) {
    guard let initial = rotationInitialWidth,
          abs(list.bounds.width - initial) > 1,
          let index = rotationEvidence.transitions.indices.last else { return }
    if !rotationDisplayTickSeen {
      rotationDisplayTickSeen = true
      let frame = rotationSample(stage: "display-link-callback")
      rotationEvidence.transitions[index].firstDisplayLinkSample = frame
      if frame.mixedGeometry { rotationEvidence.firstDisplayMismatches += 1 }
      updateRotationLabels()
      writeRotationEvidence()
    }
    if rotationCompletionSeen { finishRotationIfReady() }
  }

  private func finishRotationTransition() {
    rotationCompletionSeen = true
    finishRotationIfReady()
  }

  private func finishRotationIfReady() {
    guard rotationCompletionSeen, rotationDisplayTickSeen,
          let index = rotationEvidence.transitions.indices.last else { return }
    rotationEvidence.transitions[index].settled = rotationSample(stage: "transition-completion")
    if let witness = rotationWitness { list.unpinCell(for: witness.row) }
    rotationWitness = nil
    rotationInitialWidth = nil
    rotationCompletionSeen = false
    rotationDisplayLink?.isPaused = true
    status.text = "Rotation \(rotationEvidence.transitions.count) recorded"
    updateRotationLabels()
    writeRotationEvidence()
  }

  private func rotationSample(stage: String) -> RotationFrameEvidence {
    let layout = session.timeline.layout
    let snapshotWidth = session.snapshot?.context.width
    let requestedWidth = session.layoutContext.width
    let scale = view.window?.screen.scale ?? 1
    let tolerance: CGFloat = 0.6 / max(1, scale)
    let pending = snapshotWidth.map { abs($0 - requestedWidth) > tolerance } ?? true
    var visibleCells = 0
    var cellMismatches = 0
    for rowIndex in layout.visibleRows(in: layout.readingRect) {
      let placement = layout.rows[rowIndex]
      guard !placement.isExiting else { continue }
      guard let cell = list.cell(for: placement.row.id) as? PhoneLabTextCell else {
        cellMismatches += 1
        continue
      }
      visibleCells += 1
      let slot = cell.superview?.frame
      let body = placement.row.elements["body"]
      if slot.map({ !rotationRectMatches($0, placement.frame, tolerance: tolerance) }) ?? true
        || body.map({ !rotationRectMatches(cell.text.frame, $0, tolerance: tolerance) }) ?? false {
        cellMismatches += 1
      }
    }
    let canvasWidth = list.scrollView.contentSize.width
    let nativeWidth = list.scrollView.bounds.width
    let widthMismatch = abs(canvasWidth - layout.viewport.width) > tolerance
      || snapshotWidth.map { abs($0 - layout.viewport.width) > tolerance } ?? true
      || (!pending && abs(nativeWidth - layout.viewport.width) > tolerance)
    let originMismatch = abs(list.scrollView.contentOffset.y - layout.originY) > tolerance
    var nativeGlyphY: CGFloat?
    var expectedGlyphY: CGFloat?
    var glyphResidual: CGFloat?
    var originResidual: CGFloat?
    var legalClamp: Bool?
    var witnessError: String?
    if let witness = rotationWitness {
      if let placement = layout.placement(for: witness.row),
         let cell = list.cell(for: witness.row) as? PhoneLabTextCell,
         let localY = cell.localGlyphY(witness.character),
         let nativeY = cell.glyphY(witness.character, in: list) {
        let documentY = placement.frame.minY + localY
        let targetY: CGFloat = witness.edge == .top
          ? layout.viewport.topInset + witness.edgeDistance
          : layout.viewport.height - layout.viewport.bottomInset - witness.edgeDistance
        let desiredOrigin = documentY - targetY
        let legalOrigin = min(layout.maximumOrigin, max(0, desiredOrigin))
        legalClamp = abs(desiredOrigin - legalOrigin) > tolerance
        nativeGlyphY = nativeY
        expectedGlyphY = documentY - legalOrigin
        glyphResidual = nativeY - (documentY - legalOrigin)
        originResidual = layout.originY - legalOrigin
        if let glyphResidual {
          rotationEvidence.maxAbsoluteGlyphResidual = max(
            rotationEvidence.maxAbsoluteGlyphResidual, Double(abs(glyphResidual))
          )
        }
      } else {
        witnessError = "retained native glyph unavailable for row \(witness.row), character \(witness.character)"
      }
    } else {
      witnessError = "no visible glyph before rotation"
    }
    let mixed = widthMismatch || originMismatch || cellMismatches > 0 || visibleCells == 0
      || witnessError != nil || abs(glyphResidual ?? 0) > 2 || abs(originResidual ?? 0) > 2
    return .init(
      transition: rotationEvidence.transitions.count, stage: stage,
      uptime: ProcessInfo.processInfo.systemUptime,
      rootWidth: Double(view.bounds.width), listWidth: Double(list.bounds.width),
      nativeViewportWidth: Double(nativeWidth), nativeCanvasWidth: Double(canvasWidth),
      installedSnapshotWidth: snapshotWidth.map { Double($0) },
      publishedLayoutWidth: Double(layout.viewport.width),
      requestedContextWidth: Double(requestedWidth), preparationPending: pending,
      nativeVisibleCells: visibleCells, cellFrameMismatches: cellMismatches,
      mixedGeometry: mixed, witnessRow: rotationWitness?.row,
      witnessCharacter: rotationWitness?.character,
      nativeGlyphViewportY: nativeGlyphY.map { Double($0) },
      expectedGlyphViewportY: expectedGlyphY.map { Double($0) },
      glyphResidual: glyphResidual.map { Double($0) },
      originResidual: originResidual.map { Double($0) }, legalClamp: legalClamp,
      witnessError: witnessError, intent: String(describing: session.timeline.intent),
      isUserScrolling: session.isUserScrolling
    )
  }

  private func rotationRectMatches(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat) -> Bool {
    abs(actual.minX - expected.minX) <= tolerance
      && abs(actual.minY - expected.minY) <= tolerance
      && abs(actual.width - expected.width) <= tolerance
      && abs(actual.height - expected.height) <= tolerance
  }

  private func updateRotationLabels() {
    guard rotationFixtureRequested else { return }
    let layouts = rotationEvidence.transitions.filter { $0.firstLayout != nil }.count
    let displays = rotationEvidence.transitions.filter { $0.firstDisplayLinkSample != nil }.count
    rotationFirstFrameLabel.text = "first layouts \(layouts); mismatches \(rotationEvidence.firstLayoutMismatches)"
    rotationFirstDisplayLabel.text = "first displays \(displays); mismatches \(rotationEvidence.firstDisplayMismatches)"
    rotationGlyphLabel.text = String(
      format: "max glyph drift %.2f pt", rotationEvidence.maxAbsoluteGlyphResidual
    )
  }

  private func writeRotationEvidence() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(rotationEvidence).write(to: rotationReportURL, options: .atomic)
      NSLog("ChatListPhoneLab rotation report: %@", rotationReportURL.path)
    } catch {
      status.text = "Rotation report write failed: \(error)"
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard ownershipFixtureRequested, gestureRecognizer === ownershipPressRecognizer else { return true }
    let point = touch.location(in: list.scrollView)
    // UIScrollView.bounds.origin is its contentOffset, so the touch's local Y
    // is in the scrolled content coordinate system rather than 0...height.
    return StationaryTouchRegion.contains(point, in: list.scrollView.bounds)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }

  @objc private func ownershipPress(_ recognizer: UILongPressGestureRecognizer) {
    switch recognizer.state {
    case .began:
      guard !ownershipDidApplyInset else { return }
      ownershipPressActive = true
      ownershipEvidence.pressCount += 1
      updateOwnershipLabels()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard let self, self.ownershipPressActive, !self.ownershipDidApplyInset else { return }
        self.performOwnershipStationaryInset()
      }
    case .ended, .cancelled, .failed:
      ownershipPressActive = false
      if ownershipDidApplyInset { recognizer.isEnabled = false }
    default:
      break
    }
  }

  private func recordOwnershipPublicationIfNeeded() {
    guard ownershipFixtureRequested, session.snapshot != nil else { return }
    if ownershipEvidence.initialPublication == nil {
      ownershipWitness = witness(edge: .bottom)
      let sample = ownershipFrame(stage: "initial-publication")
      ownershipEvidence.initialPublication = sample
      inspectOwnershipInitialSample(sample)
    } else if ownershipInsetSubmitting, ownershipEvidence.firstInsetPublication == nil {
      let sample = ownershipFrame(stage: "stationary-inset-publication")
      ownershipEvidence.firstInsetPublication = sample
      inspectOwnershipInsetSample(sample)
    } else {
      return
    }
    updateOwnershipLabels()
    writeOwnershipEvidence()
  }

  @objc private func ownershipTick(_ link: CADisplayLink) {
    guard ownershipFixtureRequested, ownershipEvidence.initialPublication != nil else { return }
    if ownershipEvidence.initialDisplay == nil {
      let sample = ownershipFrame(stage: "initial-display-link-callback")
      ownershipEvidence.initialDisplay = sample
      inspectOwnershipInitialSample(sample)
      updateOwnershipLabels()
      writeOwnershipEvidence()
      return
    }
    if ownershipAwaitingInsetDisplay {
      ownershipAwaitingInsetDisplay = false
      let sample = ownershipFrame(stage: "stationary-inset-display-link-callback")
      ownershipEvidence.firstInsetDisplay = sample
      inspectOwnershipInsetSample(sample)
      updateOwnershipLabels()
      writeOwnershipEvidence()
    }
    let dragging = ownershipDidApplyInset && list.scrollView.isDragging
    if dragging {
      let firstDrag = ownershipEvidence.firstUserDrag == nil
      if ownershipEvidence.firstUserDrag == nil {
        ownershipEvidence.firstUserDrag = ownershipFrame(stage: "first-native-drag")
        ownershipEvidence.dragCount += 1
        ownershipDragStartOrigin = ownershipEvidence.firstInsetDisplay
          .map { CGFloat($0.nativeOrigin) } ?? list.scrollView.contentOffset.y
      }
      if let start = ownershipDragStartOrigin {
        ownershipEvidence.maximumDragOriginDelta = max(
          ownershipEvidence.maximumDragOriginDelta,
          Double(abs(list.scrollView.contentOffset.y - start))
        )
      }
      updateOwnershipLabels()
      if firstDrag { writeOwnershipEvidence() }
    } else if ownershipWasDragging {
      writeOwnershipEvidence()
    }
    ownershipWasDragging = dragging
  }

  private func performOwnershipStationaryInset() {
    guard ownershipFixtureRequested, !ownershipDidApplyInset else { return }
    ownershipWitness = ownershipWitness ?? witness(edge: .bottom)
    let before = ownershipFrame(stage: "stationary-press-before-inset")
    ownershipEvidence.beforeStationaryInset = before
    ownershipPreInsetOrigin = list.scrollView.contentOffset.y
    ownershipPreMaximumOrigin = session.timeline.layout.maximumOrigin
    guard list.scrollView.isTracking && !list.scrollView.isDragging && !session.isUserScrolling else {
      ownershipEvidence.failures.append(
        "Scheduled inset did not run during stationary native tracking: " +
          "tracking=\(list.scrollView.isTracking), dragging=\(list.scrollView.isDragging), " +
          "userScrolling=\(session.isUserScrolling)"
      )
      updateOwnershipLabels()
      writeOwnershipEvidence()
      return
    }
    ownershipEvidence.validStationaryPressCount += 1
    guard before.nativeGlyphY != nil else {
      ownershipEvidence.failures.append("No native glyph before stationary inset")
      updateOwnershipLabels()
      writeOwnershipEvidence()
      return
    }
    ownershipInsetSubmitting = true
    let time = ProcessInfo.processInfo.systemUptime
    updateViewport(at: time, animation: .none, bottomInsetOverride: 80)
    list.advance(to: time)
    ownershipInsetSubmitting = false
    ownershipDidApplyInset = true
    ownershipAwaitingInsetDisplay = true
    ownershipEvidence.insetCount += 1
    if session.isUserScrolling && !list.scrollView.isDragging {
      ownershipEvidence.spuriousUserScrollingCount += 1
      ownershipEvidence.failures.append("No-touch inset entered user-scrolling phase")
    }
    if ownershipEvidence.firstInsetPublication == nil {
      ownershipEvidence.failures.append("No host publication during stationary inset")
    }
    status.text = "Stationary inset published"
    updateOwnershipLabels()
    writeOwnershipEvidence()
  }

  private func ownershipFrame(stage: String) -> OwnershipFrameEvidence {
    let layout = session.timeline.layout
    let witness = ownershipWitness
    let glyphY = witness.flatMap { token in
      (list.cell(for: token.row) as? PhoneLabTextCell)?.glyphY(token.character, in: view)
    }
    var expectedGlyphY: CGFloat?
    var glyphResidual: CGFloat?
    var originResidual: CGFloat?
    var nativeOriginResidual: CGFloat?
    var legalClamp: Bool?
    if let before = ownershipEvidence.beforeStationaryInset,
       let preGlyphY = before.nativeGlyphY,
       let preOrigin = ownershipPreInsetOrigin,
       let preMaximum = ownershipPreMaximumOrigin,
       let witness,
       let placement = layout.placement(for: witness.row),
       let cell = list.cell(for: witness.row) as? PhoneLabTextCell,
       let localY = cell.localGlyphY(witness.character) {
      let documentY = placement.frame.minY + localY
      let preDistance = CGFloat(before.usableBottomY - preGlyphY)
      let targetLocalY = layout.viewport.height - layout.viewport.bottomInset - preDistance
      let desiredOrigin = documentY - targetLocalY
      let legalOrigin = min(layout.maximumOrigin, max(0, desiredOrigin))
      let preBounce = preOrigin - min(preMaximum, max(0, preOrigin))
      let expectedOrigin: CGFloat = if preBounce < -0.01 {
        preBounce
      } else if preBounce > 0.01 {
        layout.maximumOrigin + preBounce
      } else {
        legalOrigin
      }
      legalClamp = abs(desiredOrigin - legalOrigin) > 0.5
      expectedGlyphY = list.frame.minY + documentY - expectedOrigin
      if let glyphY, let expectedGlyphY { glyphResidual = glyphY - expectedGlyphY }
      originResidual = layout.originY - expectedOrigin
      nativeOriginResidual = list.scrollView.contentOffset.y - expectedOrigin
    } else if ownershipEvidence.beforeStationaryInset == nil,
              let placement = layout.placement(for: 352),
              let witness,
              let glyphPlacement = layout.placement(for: witness.row),
              let cell = list.cell(for: witness.row) as? PhoneLabTextCell,
              let localY = cell.localGlyphY(witness.character) {
      // This requested reading point was supplied with the first snapshot.
      let targetY = layout.viewport.height - layout.viewport.bottomInset - 20
      let desiredOrigin = placement.frame.minY + 140 - targetY
      let legalOrigin = min(layout.maximumOrigin, max(0, desiredOrigin))
      legalClamp = abs(desiredOrigin - legalOrigin) > 0.5
      let glyphDocumentY = glyphPlacement.frame.minY + localY
      expectedGlyphY = list.frame.minY + glyphDocumentY - legalOrigin
      if let glyphY, let expectedGlyphY { glyphResidual = glyphY - expectedGlyphY }
      originResidual = layout.originY - legalOrigin
      nativeOriginResidual = list.scrollView.contentOffset.y - legalOrigin
    }
    return .init(
      stage: stage, uptime: ProcessInfo.processInfo.systemUptime,
      row: witness?.row, character: witness?.character,
      nativeGlyphY: glyphY.map { Double($0) },
      usableBottomY: Double(list.frame.maxY - layout.viewport.bottomInset),
      nativeOrigin: Double(list.scrollView.contentOffset.y),
      packageOrigin: Double(layout.originY),
      expectedGlyphY: expectedGlyphY.map { Double($0) },
      glyphResidual: glyphResidual.map { Double($0) },
      originResidual: originResidual.map { Double($0) },
      nativeOriginResidual: nativeOriginResidual.map { Double($0) },
      legalClamp: legalClamp,
      intent: String(describing: session.timeline.intent),
      isUserScrolling: session.isUserScrolling,
      nativeDragging: list.scrollView.isDragging
    )
  }

  private func inspectOwnershipInsetSample(_ sample: OwnershipFrameEvidence) {
    guard let glyphResidual = sample.glyphResidual,
          let originResidual = sample.originResidual,
          let nativeOriginResidual = sample.nativeOriginResidual else {
      ownershipEvidence.failures.append("\(sample.stage): retained native glyph unavailable")
      return
    }
    ownershipEvidence.maxAbsoluteFirstFrameGlyphResidual = max(
      ownershipEvidence.maxAbsoluteFirstFrameGlyphResidual, abs(glyphResidual)
    )
    if abs(glyphResidual) > 2 || abs(originResidual) > 2
      || abs(nativeOriginResidual) > 2 || sample.isUserScrolling {
      ownershipEvidence.failures.append(
        "\(sample.stage): glyph=\(glyphResidual), origin=\(originResidual), " +
          "nativeOrigin=\(nativeOriginResidual), " +
          "userScrolling=\(sample.isUserScrolling)"
      )
      if sample.isUserScrolling { ownershipEvidence.spuriousUserScrollingCount += 1 }
    }
  }

  private func inspectOwnershipInitialSample(_ sample: OwnershipFrameEvidence) {
    guard let glyphResidual = sample.glyphResidual,
          let originResidual = sample.originResidual,
          let nativeOriginResidual = sample.nativeOriginResidual,
          sample.intent.contains("reading") else {
      ownershipEvidence.failures.append("\(sample.stage): first snapshot reading glyph unavailable")
      return
    }
    ownershipEvidence.maxAbsoluteFirstFrameGlyphResidual = max(
      ownershipEvidence.maxAbsoluteFirstFrameGlyphResidual, abs(glyphResidual)
    )
    if abs(glyphResidual) > 2 || abs(originResidual) > 2
      || abs(nativeOriginResidual) > 2 || sample.isUserScrolling {
      ownershipEvidence.failures.append(
        "\(sample.stage): glyph=\(glyphResidual), origin=\(originResidual), " +
          "nativeOrigin=\(nativeOriginResidual), " +
          "userScrolling=\(sample.isUserScrolling)"
      )
    }
  }

  private func updateOwnershipLabels() {
    guard ownershipFixtureRequested else { return }
    ownershipPublicationLabel.text = "publication \(ownershipEvidence.initialPublication == nil ? 0 : 1); " +
      "inset \(ownershipEvidence.firstInsetPublication == nil ? 0 : 1)"
    ownershipDisplayLabel.text = "display \(ownershipEvidence.initialDisplay == nil ? 0 : 1); " +
      "inset \(ownershipEvidence.firstInsetDisplay == nil ? 0 : 1)"
    ownershipPhaseLabel.text = "press \(ownershipEvidence.pressCount); " +
      "valid \(ownershipEvidence.validStationaryPressCount); " +
      "update \(ownershipEvidence.insetCount); drag \(ownershipEvidence.dragCount); " +
      "spurious \(ownershipEvidence.spuriousUserScrollingCount); " +
      String(format: "delta %.2f", ownershipEvidence.maximumDragOriginDelta)
    ownershipGlyphLabel.text = String(
      format: "max drift %.2f pt; failures %d",
      ownershipEvidence.maxAbsoluteFirstFrameGlyphResidual,
      ownershipEvidence.failures.count
    )
  }

  private func writeOwnershipEvidence() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(ownershipEvidence).write(to: ownershipReportURL, options: .atomic)
      NSLog("ChatListPhoneLab ownership report: %@", ownershipReportURL.path)
    } catch {
      status.text = "Ownership report write failed: \(error)"
    }
  }

  private func nextTime() -> Double {
    guard let manualClock else { return ProcessInfo.processInfo.systemUptime }
    let next = manualClock + 0.5
    self.manualClock = next
    return next
  }

  private func resizeList(at time: Double) {
    widthReduction = widthReduction >= 96 ? 0 : widthReduction + 48
    transactionTime = time
    view.setNeedsLayout()
    view.layoutIfNeeded()
    transactionTime = nil
  }

  private func inspectNative(label: String) {
    let layout = session.timeline.layout
    let scale = view.window?.screen.scale ?? 1
    probe.inspect(layout, label: label)
    probe.inspectNativeOrigin(list.scrollView.contentOffset.y, expected: layout.originY,
                              scale: scale, label: label)
    for (id, view) in list.materializedCells {
      guard let cell = view as? PhoneLabTextCell,
            let placement = layout.placement(for: id),
            let item = session.item(for: id) else {
        probe.recordMissingGlyph(label: "\(label): unresolved native row \(id)")
        continue
      }
      probe.inspectNativeCell(
        id: id, slot: cell.superview?.frame, cell: cell.frame, body: cell.text.frame,
        placement: placement, expectedCellHeight: item.height, scale: scale, label: label
      )
    }
    for placement in session.decorationPlacements {
      probe.inspectDecoration(decorations.frame(for: placement.id), placement: placement,
                              scale: scale, label: label)
    }
    probe.inspectOcclusions(top: topOcclusion.frame, bottom: bottomOcclusion.frame,
                            viewport: layout.viewport, scale: scale, label: label)
    let indicator = list.scrollView.verticalScrollIndicatorInsets
    let content = list.scrollView.contentInset
    probe.inspectIndicatorInsets(
      top: indicator.top, bottom: indicator.bottom,
      contentTop: content.top, contentBottom: content.bottom,
      viewport: layout.viewport, scale: scale, label: label
    )
  }

  private func runNegativeControl() {
    guard let witness = witness(), let cell = list.cell(for: witness.row) as? PhoneLabTextCell else {
      probe.recordMissingGlyph(label: "negative control")
      return
    }
    let origin = session.timeline.layout.originY
    let original = cell.text.frame
    cell.text.frame.origin.y += 6
    let shifted = cell.screenGlyphY(witness.character)
    cell.text.frame = original
    if let shifted {
      probe.inspectNegativeControl(
        originBefore: origin, originAfter: session.timeline.layout.originY,
        glyphBefore: witness.y, glyphAfter: shifted
      )
    } else {
      probe.recordMissingGlyph(label: "negative control")
    }
  }

  private func witness(edge requestedEdge: TimelineAnchorEdge? = nil) -> GlyphWitness? {
    let layout = session.timeline.layout
    let edge = requestedEdge ?? currentReadingEdge
    let visible = layout.visibleRows(in: layout.readingRect)
    let indices = edge == .top ? Array(visible) : Array(visible.reversed())
    for index in indices {
      let placement = layout.rows[index]
      guard !placement.isExiting, placement.row.canAnchor else { continue }
      guard let cell = list.cell(for: placement.row.id) as? PhoneLabTextCell else { continue }
      let local = layout.readingRect.intersection(placement.frame).offsetBy(
        dx: -placement.frame.minX, dy: -placement.frame.minY
      )
      guard let anchor = cell.capture(local),
            let token = anchor.token.base as? PhoneGlyphToken,
            let y = cell.screenGlyphY(token.character) else { continue }
      let viewportPoint = placement.frame.minY + anchor.localY - layout.originY
      let edgeDistance: CGFloat = switch edge {
      case .top: viewportPoint - layout.viewport.topInset
      case .bottom: layout.viewport.height - layout.viewport.bottomInset - viewportPoint
      }
      return .init(
        row: token.row, character: token.character, y: y,
        edge: edge, viewportPoint: viewportPoint, edgeDistance: edgeDistance,
        rowFrame: placement.frame, localY: anchor.localY,
        bodyFrame: cell.text.frame, textOffset: cell.text.contentOffset.y
      )
    }
    return nil
  }

  private var currentReadingEdge: TimelineAnchorEdge {
    if case let .reading(anchor) = session.timeline.intent { return anchor.edge }
    return .bottom
  }

  private func witnessEdge(for operation: LabOperation) -> TimelineAnchorEdge {
    switch operation {
    case .bottomInset, .heightAndInset: .bottom
    case .topInset:
      session.timeline.layout.viewport.bottomInset != session.timeline.targetViewport.bottomInset
        ? .bottom : .top
    default: currentReadingEdge
    }
  }

  private func inspectWitness(_ before: GlyphWitness?, preIntent: String, label: String) {
    guard let before else {
      probe.recordMissingGlyph(label: label)
      return
    }
    guard let record = scenario.records.first(where: { $0.id == before.row }) else {
      probe.recordRetiredWitness()
      probe.inspectReadingFallback(session.timeline.layout, intent: session.timeline.intent, label: label)
      return
    }
    guard before.character < record.content.text.utf16.count else {
      probe.recordChangedGlyphContent()
      return
    }
    let layout = session.timeline.layout
    guard let placement = layout.placement(for: before.row) else {
      probe.recordMissingGlyph(label: "\(label): retained row has no package placement")
      return
    }
    guard let cell = list.cell(for: before.row) as? PhoneLabTextCell else {
      probe.recordMissingGlyph(label: "\(label): pinned retained native cell unavailable, row \(before.row)")
      return
    }
    guard let y = cell.screenGlyphY(before.character),
          let localY = cell.localGlyphY(before.character) else {
      probe.recordMissingGlyph(
        label: "\(label): pinned retained glyph unavailable, row \(before.row), character \(before.character)"
      )
      return
    }
    guard localY >= -1, localY <= placement.frame.height + 1 else {
      probe.recordUnrepresentableWitness()
      probe.inspectReadingFallback(layout, intent: session.timeline.intent, label: label)
      return
    }
    guard let body = placement.row.elements["body"],
          localY >= body.minY - 1, localY <= body.maxY + 1 else {
      probe.recordUnrepresentableWitness()
      probe.inspectReadingFallback(layout, intent: session.timeline.intent, label: label)
      return
    }
    probe.inspectGlyph(
      screenDrift: y - before.y,
      afterDocumentY: placement.frame.minY + localY,
      beforeViewportPoint: before.viewportPoint,
      beforeEdgeDistance: before.edgeDistance,
      edge: before.edge, viewport: layout.viewport,
      actualOrigin: layout.originY,
      maximumOrigin: layout.maximumOrigin,
      rowID: before.row, rowFrame: placement.frame, localY: localY,
      intent: String(describing: session.timeline.intent),
      preIntent: preIntent, isUserScrolling: session.isUserScrolling,
      contextWidth: session.layoutContext.width,
      nativeViewportWidth: list.scrollView.bounds.width,
      beforeRowFrame: before.rowFrame, beforeLocalY: before.localY,
      beforeBodyFrame: before.bodyFrame, afterBodyFrame: cell.text.frame,
      textOffsetDelta: cell.text.contentOffset.y - before.textOffset,
      macScreenYUp: false, label: label,
      scale: view.window?.screen.scale ?? 1
    )
  }

  private func runEvent(
    _ operation: LabOperation, at time: Double, label: String, offsets: [Double]
  ) -> Bool {
    let baselineStarted = ProcessInfo.processInfo.systemUptime
    list.advance(to: time)
    probe.recordAdvanceDuration((ProcessInfo.processInfo.systemUptime - baselineStarted) * 1_000)
    let before = witness(edge: witnessEdge(for: operation))
    if let before { list.pinCell(for: before.row) }
    defer { if let before { list.unpinCell(for: before.row) } }
    let preIntent = String(describing: session.timeline.intent)
    scenario.perform(operation, visibleID: session.timeline.layout.anchor()?.id)
    if operation == .resizeWidth { resizeList(at: time) }
    let generation = session.generation
    if operation.changesViewport { updateViewport(at: time, animation: .animated) }
    if session.generation == generation, !applyCurrent(at: time) { return false }
    for (sample, offset) in offsets.enumerated() {
      let started = ProcessInfo.processInfo.systemUptime
      list.advance(to: time + offset)
      probe.recordAdvanceDuration((ProcessInfo.processInfo.systemUptime - started) * 1_000)
      let sampleLabel = "\(label) frame \(sample) \(operation)"
      inspectNative(label: sampleLabel)
      inspectWitness(before, preIntent: preIntent, label: sampleLabel)
    }
    return true
  }

  private func startReplay() {
    guard !replayRunning, session.snapshot != nil else { return }
    replayRunning = true
    status.text = "Replay starting · 0/\(requestedReplayEvents)"
    writeReplayProgress(state: "started", completedEvents: 0, focusedEventsCompleted: 0)
    NSLog("ChatListPhoneLab replay started: %@", replayProgressURL.path)
    list.configuration.usesAutomaticDisplayClock = false
    var time = ProcessInfo.processInfo.systemUptime + 1
    manualClock = time
    scenario = LabScenario(includeLongPassage: true)
    guard applyCurrent(at: time, animation: .none) else { replayRunning = false
      writeReplayProgress(state: "failed-initial-apply", completedEvents: 0, focusedEventsCompleted: 0)
      return
    }
    session.navigate(to: .reading(.init(id: 180, localY: 2_500, viewportY: 20)),
                     animation: .none, at: time)
    runNegativeControl()
    Task { @MainActor in
      let offsets: [Double] = [1 / 120, 1 / 60, 1 / 30, 1 / 20, 1 / 12, 1 / 8, 1 / 4, 0.4]
      var focusedEvents = 0
      for operation in [LabOperation.toggleHeight, .topInset, .resizeWidth, .prepend, .heightAndInset] {
        time += 0.5
        manualClock = time
        guard runEvent(operation, at: time, label: "long passage \(focusedEvents)", offsets: offsets) else { break }
        focusedEvents += 1
      }
      writeReplayProgress(state: "focused-complete", completedEvents: 0,
                          focusedEventsCompleted: focusedEvents)
      scenario = LabScenario()
      widthReduction = 0
      time += 0.5
      manualClock = time
      transactionTime = time
      view.setNeedsLayout()
      view.layoutIfNeeded()
      transactionTime = nil
      let resetGeneration = session.generation
      updateViewport(at: time, animation: .none)
      if session.generation == resetGeneration { _ = applyCurrent(at: time, animation: .none) }
      session.navigate(to: .reading(.init(id: 180, viewportY: 20)), animation: .none, at: time)
      var completedEvents = 0
      for event in 0 ..< requestedReplayEvents {
        time += 0.5
        manualClock = time
        let operation = replay.next()
        guard runEvent(operation, at: time, label: "event \(event)", offsets: offsets) else { break }
        completedEvents += 1
        if event % 16 == 0 {
          status.text = "Replay \(completedEvents)/\(requestedReplayEvents) · " +
            "\(probe.sampledFrames) samples · \(probe.failureCount) failures"
          writeReplayProgress(state: "running", completedEvents: completedEvents,
                              focusedEventsCompleted: focusedEvents)
          await Task.yield()
        }
      }
      status.text = "Replay complete · \(probe.report)"
      NSLog("ChatListPhoneLab: %@", probe.report)
      do {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = try LabRunReport(
          platform: "iOS", requestedEvents: requestedReplayEvents,
          completedEvents: completedEvents,
          focusedEventsCompleted: focusedEvents, probe: probe
        )
          .write(to: directory)
        NSLog("ChatListPhoneLab report: %@", path.path)
      } catch {
        status.text = "Report write failed: \(error)"
      }
      writeReplayProgress(
        state: completedEvents == requestedReplayEvents ? "complete" : "stopped",
        completedEvents: completedEvents, focusedEventsCompleted: focusedEvents
      )
      replayRunning = false
    }
  }

  private func writeReplayProgress(
    state: String, completedEvents: Int, focusedEventsCompleted: Int
  ) {
    let progress = ReplayProgress(
      state: state, requestedEvents: requestedReplayEvents,
      completedEvents: completedEvents, focusedEventsCompleted: focusedEventsCompleted,
      virtualPresentationSamples: probe.sampledFrames, failureCount: probe.failureCount,
      uptime: ProcessInfo.processInfo.systemUptime
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(progress).write(to: replayProgressURL, options: .atomic)
    } catch {
      NSLog("ChatListPhoneLab replay progress write failed: %@", String(describing: error))
    }
  }
}

private extension LabOperation {
  var changesViewport: Bool {
    switch self {
    case .topInset, .bottomInset, .heightAndInset, .resizeWidth: true
    default: false
    }
  }
}
