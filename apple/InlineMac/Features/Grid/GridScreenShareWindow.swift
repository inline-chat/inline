import AppKit
import Foundation
import InlineKit
import InlineProtocol
import InlineRTC
import InlineUI
import Logger
import Observation
import SwiftUI

@MainActor
final class GridScreenShareWindowCoordinator {
  static let shared = GridScreenShareWindowCoordinator()

  private let log = Log.scoped("GridScreenShareWindow")
  private var controllers: [String: GridScreenShareWindowController] = [:]

  private init() {}

  func closeAll() {
    let openControllers = Array(controllers.values)
    if !openControllers.isEmpty {
      log.info("GRID_SCREEN phase=viewer_close_all count=\(openControllers.count)")
    }
    controllers.removeAll()
    for controller in openControllers {
      controller.close()
    }
  }

  func open(
    user: InlineProtocol.User,
    share: InlineRTCScreenShare,
    store: GridRoomService
  ) {
    let participantIdentity = share.participantIdentity
    if let controller = controllers[participantIdentity] {
      log.info(
        "GRID_SCREEN phase=viewer_open_existing previous_publication=\(controller.publicationID) next_publication=\(share.publicationID)"
      )
      controller.rebind(to: share)
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }

    let controller = GridScreenShareWindowController(
      user: user,
      share: share,
      store: store
    )
    controller.onClose = { [weak self, weak controller] in
      guard self?.controllers[participantIdentity] === controller else { return }
      self?.controllers[participantIdentity] = nil
    }
    controllers[participantIdentity] = controller
    log.info(
      "GRID_SCREEN phase=viewer_open_new publication=\(share.publicationID)"
    )
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}

@MainActor
private final class GridScreenShareWindowController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  var participantIdentity: String { viewerTarget.participantIdentity }
  var publicationID: String { viewerTarget.publicationID }

  private let titlebarAccessoryController: GridScreenShareTitlebarController
  private let viewerTarget: GridScreenShareViewerTarget
  private let log = Log.scoped("GridScreenShareWindow")
  private var didApplyInitialVideoSize = false

  init(
    user: InlineProtocol.User,
    share: InlineRTCScreenShare,
    store: GridRoomService
  ) {
    let inlineUser = InlineKit.User(from: user)
    let viewerTarget = GridScreenShareViewerTarget(share: share)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 450),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    titlebarAccessoryController = GridScreenShareTitlebarController(
      identity: GridScreenShareToolbarIdentity(
        displayName: inlineUser.displayName,
        firstName: inlineUser.firstName,
        lastName: inlineUser.lastName,
        localAvatarURL: inlineUser.getLocalURL(),
        remoteAvatarURL: inlineUser.getRemoteURL()
      )
    )
    self.viewerTarget = viewerTarget
    super.init(window: window)

    let screenTitle = String(
      localized: "\(inlineUser.displayName)’s screen",
      comment: "Screen-share viewer title; the variable is the sharer's display name."
    )
    window.title = screenTitle
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = false
    window.titlebarSeparatorStyle = .none
    window.tabbingMode = .disallowed
    window.animationBehavior = .documentWindow
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
    window.contentMinSize = NSSize(width: 240, height: 135)
    window.backgroundColor = .windowBackgroundColor
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.addTitlebarAccessoryViewController(titlebarAccessoryController)
    window.contentViewController = NSHostingController(
      rootView: GridScreenShareViewer(
        target: viewerTarget,
        initialShare: share,
        store: store,
        onPublicationResolved: { [weak self] publicationID in
          self?.viewerTarget.publicationID = publicationID
        },
        onVideoDimensionsChanged: { [weak self] dimensions in
          self?.applyVideoDimensions(dimensions)
        }
      )
    )
    window.center()
    if let dimensions = share.videoTrack?.dimensions {
      applyVideoDimensions(dimensions)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func windowWillClose(_: Notification) {
    // Do not depend on AppKit releasing a closed window promptly. Disable the
    // renderer synchronously so adaptive streaming can stop remote video even
    // if the window or hosting controller survives the close transaction.
    viewerTarget.isVisible = false
    log.info(
      "GRID_SCREEN phase=viewer_closed publication=\(viewerTarget.publicationID)"
    )
    onClose?()
  }

  func windowDidMiniaturize(_: Notification) {
    updateViewerVisibility()
  }

  func windowDidDeminiaturize(_: Notification) {
    updateViewerVisibility()
  }

  func windowDidChangeOcclusionState(_: Notification) {
    updateViewerVisibility()
  }

  func rebind(to share: InlineRTCScreenShare) {
    let previousPublicationID = viewerTarget.publicationID
    viewerTarget.publicationID = share.publicationID
    log.info(
      "GRID_SCREEN phase=viewer_rebound previous_publication=\(previousPublicationID) next_publication=\(share.publicationID)"
    )
  }

  private func updateViewerVisibility() {
    guard let window else { return }
    let isVisible =
      !window.isMiniaturized && window.occlusionState.contains(.visible)
    guard viewerTarget.isVisible != isVisible else { return }
    viewerTarget.isVisible = isVisible
    log.info(
      "GRID_SCREEN phase=viewer_visibility publication=\(viewerTarget.publicationID) visible=\(isVisible)"
    )
  }

  private func applyVideoDimensions(_ dimensions: InlineRTCVideoDimensions) {
    guard let window,
          dimensions.width > 0,
          dimensions.height > 0
    else { return }

    let screen = window.screen ?? NSScreen.main
    let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    guard let layout = InlineRTCScreenShareWindowSizePolicy.layout(
      videoDimensions: dimensions,
      backingScale: window.backingScaleFactor,
      visibleFrameSize: visibleFrame.size
    ) else { return }

    window.contentAspectRatio = NSSize(width: layout.aspectRatio, height: 1)
    window.contentMinSize = layout.minimumContentSize
    log.info(
      "GRID_SCREEN phase=viewer_dimensions publication=\(viewerTarget.publicationID) width=\(dimensions.width) height=\(dimensions.height)"
    )
    guard !didApplyInitialVideoSize else { return }
    didApplyInitialVideoSize = true

    window.setContentSize(layout.initialContentSize)
    window.center()
    log.info(
      "GRID_SCREEN phase=viewer_initial_size publication=\(viewerTarget.publicationID) width=\(Int(layout.initialContentSize.width.rounded())) height=\(Int(layout.initialContentSize.height.rounded()))"
    )
  }
}

@MainActor
@Observable
private final class GridScreenShareViewerTarget {
  let participantIdentity: String
  var publicationID: String
  var isVisible = true

  init(share: InlineRTCScreenShare) {
    participantIdentity = share.participantIdentity
    publicationID = share.publicationID
  }
}

private struct GridScreenShareViewer: View {
  let target: GridScreenShareViewerTarget
  let store: GridRoomService
  let onPublicationResolved: (String) -> Void
  let onVideoDimensionsChanged: (InlineRTCVideoDimensions) -> Void

  @State private var lastResolvedShare: InlineRTCScreenShare?
  @State private var viewerWaitExpired = false

  init(
    target: GridScreenShareViewerTarget,
    initialShare: InlineRTCScreenShare,
    store: GridRoomService,
    onPublicationResolved: @escaping (String) -> Void,
    onVideoDimensionsChanged: @escaping (InlineRTCVideoDimensions) -> Void
  ) {
    self.target = target
    self.store = store
    self.onPublicationResolved = onPublicationResolved
    self.onVideoDimensionsChanged = onVideoDimensionsChanged
    _lastResolvedShare = State(initialValue: initialShare)
  }

  var body: some View {
    screenContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .onChange(of: resolvedShare, initial: true) { _, share in
        guard let share else { return }
        lastResolvedShare = share
        viewerWaitExpired = false
        onPublicationResolved(share.publicationID)
      }
      .task(id: viewerAvailabilityID) {
        guard resolvedShare?.videoTrack == nil, lastResolvedShare != nil else {
          viewerWaitExpired = false
          return
        }
        viewerWaitExpired = false
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, resolvedShare?.videoTrack == nil else { return }
        viewerWaitExpired = true
      }
  }

  @ViewBuilder
  private var screenContent: some View {
    if let share = resolvedShare, share.videoTrack != nil {
      GridScreenShareVideoRenderer(
        share: share,
        isVideoEnabled: target.isVisible,
        onVideoDimensionsChanged: onVideoDimensionsChanged
      )
    } else if !viewerWaitExpired, lastResolvedShare != nil {
      HStack(spacing: 8) {
        GridScreenShareActivityIndicator(tint: Color.primary.opacity(0.55))
        Text("Waiting for screen…")
          .foregroundStyle(.secondary)
      }
    } else if resolvedShare != nil {
      ContentUnavailableView(
        "Screen unavailable",
        systemImage: "rectangle.slash",
        description: Text("The shared screen couldn’t be received.")
      )
      .foregroundStyle(.secondary)
    } else {
      ContentUnavailableView(
        "Screen sharing ended",
        systemImage: "rectangle.slash",
        description: Text("You can close this window.")
      )
      .foregroundStyle(.secondary)
    }
  }

  private var resolvedShare: InlineRTCScreenShare? {
    InlineRTCScreenShareViewerSelection.resolve(
      publicationID: target.publicationID,
      participantIdentity: target.participantIdentity,
      shares: store.media.screenShares
    )
  }

  private var viewerAvailabilityID: String {
    let publicationID = resolvedShare?.publicationID
      ?? lastResolvedShare?.publicationID
      ?? "none"
    return "\(publicationID):\(resolvedShare?.videoTrack != nil)"
  }
}

private struct GridScreenShareVideoRenderer: NSViewRepresentable {
  let share: InlineRTCScreenShare
  let isVideoEnabled: Bool
  let onVideoDimensionsChanged: (InlineRTCVideoDimensions) -> Void

  func makeNSView(context _: Context) -> InlineRTCVideoView {
    let view = InlineRTCVideoView(frame: .zero)
    view.onVideoDimensionsChanged = onVideoDimensionsChanged
    view.screenShare = share
    view.isVideoEnabled = isVideoEnabled
    return view
  }

  func updateNSView(_ view: InlineRTCVideoView, context _: Context) {
    view.onVideoDimensionsChanged = onVideoDimensionsChanged
    view.screenShare = share
    view.isVideoEnabled = isVideoEnabled
  }

  static func dismantleNSView(_ view: InlineRTCVideoView, coordinator _: ()) {
    view.isVideoEnabled = false
    view.screenShare = nil
    view.onVideoDimensionsChanged = nil
  }
}
