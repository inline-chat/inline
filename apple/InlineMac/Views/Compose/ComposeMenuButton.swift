import AppKit
import AVFoundation
import InlineKit
import UniformTypeIdentifiers

class ComposeMenuButton: NSView {
  private let size: CGFloat = Theme.composeButtonSize
  private let button: NSButton
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

  weak var delegate: ComposeMenuButtonDelegate?
  private var cameraWindow: NSWindow?
  private var cameraViewController: CameraViewController?

  // MARK: - Initialization

  init() {
    button = NSButton(frame: .zero)
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false

    // let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
    let image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: size * 0.6, weight: .semibold))
    button.image = image
    button.contentTintColor = .tertiaryLabelColor

    super.init(frame: .zero)
    setupView()
    setupMenu()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = size / 2

    addSubview(button)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),

      button.centerXAnchor.constraint(equalTo: centerXAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: size),
      button.heightAnchor.constraint(equalToConstant: size),
    ])

    button.target = self
    button.action = #selector(handleClick)
  }

  private func setupMenu() {
    let menu = NSMenu()

    // Photo Library Item
    let photoItem = NSMenuItem(
      title: "Photo or Video",
      action: #selector(openMediaPicker),
      keyEquivalent: ""
    )
    photoItem.target = self
    photoItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
    menu.addItem(photoItem)

    // Camera Item
    let cameraItem = NSMenuItem(
      title: "Camera",
      action: #selector(openCamera),
      keyEquivalent: ""
    )
    cameraItem.target = self
    cameraItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
    menu.addItem(cameraItem)

    // Files Item
    let fileItem = NSMenuItem(
      title: "Files",
      action: #selector(openFilePicker),
      keyEquivalent: ""
    )
    fileItem.target = self
    fileItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    menu.addItem(fileItem)

    button.menu = menu
  }

  // MARK: - Actions

  @objc private func handleClick() {
    // Show menu
    if let menu = button.menu {
      let point = NSPoint(x: 0, y: bounds.height)
      menu.popUp(positioning: nil, at: point, in: self)
    }
  }

  @objc private func openMediaPicker() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [
      UTType.image,
      UTType.movie,
      UTType.video,
    ]

    panel.beginSheetModal(for: window!) { [weak self] response in
      guard let self,
            response == .OK,
            !panel.urls.isEmpty else { return }

      for url in panel.urls {
        if let image = NSImage(contentsOf: url) {
          delegate?.composeMenuButton(self, didSelectImage: image, url: url)
        }
      }
    }
  }

  @objc private func openFilePicker() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    panel.beginSheetModal(for: window!) { [weak self] response in
      guard let self,
            response == .OK,
            !panel.urls.isEmpty else { return }

      delegate?.composeMenuButton(self, didSelectFiles: panel.urls)
    }
  }

  // MARK: - Mouse Tracking

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let existingTrackingArea = trackingArea {
      removeTrackingArea(existingTrackingArea)
    }

    let options: NSTrackingArea.Options = [
      .mouseEnteredAndExited,
      .activeAlways,
    ]

    trackingArea = NSTrackingArea(
      rect: bounds,
      options: options,
      owner: self,
      userInfo: nil
    )

    if let trackingArea {
      addTrackingArea(trackingArea)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    updateBackgroundColor()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

      if isHovering {
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.1).cgColor
      } else {
        layer?.backgroundColor = .clear
      }
    }
  }

  @objc private func openCamera() {
    // Close existing window if present
    if let existingWindow = cameraWindow {
      existingWindow.close()
      cameraWindow = nil
      cameraViewController = nil
    }

    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      guard granted else {
        DispatchQueue.main.async {
          self?.showCameraPermissionAlert()
        }
        return
      }

      DispatchQueue.main.async {
        self?.showCameraWindow()
      }
    }
  }

  private func showCameraPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = "Camera Access Required"
    alert.informativeText = "Please enable camera access in System Settings to use this feature."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Cancel")

    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
  }

  private func showCameraWindow() {
    // Calculate window size based on 16:9 aspect ratio
    let aspectRatio: CGFloat = 16.0 / 9.0
    let defaultWidth: CGFloat = 640 // Standard HD width
    let windowHeight = defaultWidth / aspectRatio

    // Get screen size for max bounds
    guard let screen = NSScreen.main else { return }
    let screenSize = screen.visibleFrame.size

    // Limit size to 70% of screen height
    let maxHeight = screenSize.height * 0.7
    let finalHeight = min(windowHeight, maxHeight)
    let finalWidth = finalHeight * aspectRatio

    // Use native window controls with transparent titlebar
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true // Allow dragging window by content
    window.title = "Camera"
    window.center()
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 200, height: 200 / aspectRatio) // Minimum reasonable size
    window.maxSize = NSSize(width: screenSize.width, height: screenSize.height)
    // Set background color to black for better camera preview
    window.backgroundColor = .black

    let cameraVC = CameraViewController()
    cameraVC.delegate = delegate
    window.contentViewController = cameraVC

    // Animation setup
    window.alphaValue = 0.0
    window.setFrame(NSRect(
      x: window.frame.origin.x,
      y: window.frame.origin.y - 20, // Start slightly below final position
      width: window.frame.width,
      height: window.frame.height
    ), display: false)

    window.makeKeyAndOrderFront(nil)

    // Animate window appearance
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)

      window.animator().alphaValue = 1.0
      window.animator().setFrame(NSRect(
        x: window.frame.origin.x,
        y: window.frame.origin.y + 20, // Move up to final position
        width: window.frame.width,
        height: window.frame.height
      ), display: true)
    }

    window.delegate = self
    cameraWindow = window
    cameraViewController = cameraVC
  }
}

// MARK: - Camera View Controller

class CameraViewController: NSViewController {
  var captureSession: AVCaptureSession?
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var photoOutput: AVCapturePhotoOutput?

  weak var delegate: ComposeMenuButtonDelegate?

  override func loadView() {
    // Create view with 16:9 aspect ratio
    view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupCameraSession()
    setupUI()
  }

  deinit {
    captureSession?.stopRunning()
    NotificationCenter.default.removeObserver(self)
  }

  private func setupCameraSession() {
    captureSession = AVCaptureSession()
    captureSession?.sessionPreset = .photo

    guard let captureSession,
          let camera = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: camera) else { return }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    photoOutput = AVCapturePhotoOutput()
    if let photoOutput, captureSession.canAddOutput(photoOutput) {
      captureSession.addOutput(photoOutput)
    }

    previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer?.videoGravity = .resizeAspect
    view.layer = previewLayer

    DispatchQueue.global(qos: .userInitiated).async {
      captureSession.startRunning()
    }
  }

  private func setupUI() {
    let captureButton = NSButton(frame: .zero)
    captureButton.bezelStyle = .regularSquare // Using regularSquare as base for custom styling
    captureButton.title = "Capture"
    captureButton.font = .systemFont(ofSize: 13, weight: .medium)
    captureButton.wantsLayer = true
    captureButton.isBordered = false // Remove default border

    // Capsule styling
    captureButton.layer?.backgroundColor = NSColor.white.cgColor
    captureButton.layer?.cornerRadius = 16 // Half of height for capsule shape
    captureButton.contentTintColor = .black // Black text on white background

    // Add subtle shadow
    captureButton.layer?.shadowColor = NSColor.black.cgColor
    captureButton.layer?.shadowOpacity = 0.2
    captureButton.layer?.shadowOffset = CGSize(width: 0, height: 1)
    captureButton.layer?.shadowRadius = 2
    captureButton.focusRingType = .none
    captureButton.target = self
    captureButton.action = #selector(capturePhoto)
    captureButton.translatesAutoresizingMaskIntoConstraints = false

    // Add hover effect
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: ["button": captureButton]
    )
    captureButton.addTrackingArea(trackingArea)

    view.addSubview(captureButton)

    NSLayoutConstraint.activate([
      captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      captureButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
      captureButton.widthAnchor.constraint(equalToConstant: 100),
      captureButton.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  private func addCaptureFlash() {
    let flashView = NSView(frame: view.bounds)
    flashView.wantsLayer = true
    flashView.layer?.backgroundColor = NSColor.white.cgColor
    flashView.layer?.opacity = 0
    view.addSubview(flashView)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      flashView.layer?.opacity = 0.8
    } completionHandler: {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        flashView.layer?.opacity = 0
      } completionHandler: {
        flashView.removeFromSuperview()
      }
    }
  }

  @objc private func capturePhoto() {
    guard let photoOutput else { return }
    addCaptureFlash()

    let settings = AVCapturePhotoSettings()
    photoOutput.capturePhoto(with: settings, delegate: self)
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    captureSession?.stopRunning()
  }

  func animateClose(completion: (() -> Void)? = nil) {
    guard let window = view.window else {
      completion?()
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)

      window.animator().alphaValue = 0.0
      window.animator().setFrame(NSRect(
        x: window.frame.origin.x,
        y: window.frame.origin.y - 20, // Move down while fading
        width: window.frame.width,
        height: window.frame.height
      ), display: true)
    } completionHandler: {
      window.close()
      completion?()
    }
  }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {
  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard let imageData = photo.fileDataRepresentation(),
          let image = NSImage(data: imageData) else { return }

    delegate?.composeMenuButton(didCaptureImage: image)
    animateClose()
  }
}

// MARK: - Delegate Protocol

protocol ComposeMenuButtonDelegate: AnyObject {
  func composeMenuButton(_ button: ComposeMenuButton, didSelectImage image: NSImage, url: URL)
  func composeMenuButton(_ button: ComposeMenuButton, didSelectFiles urls: [URL])
  func composeMenuButton(didCaptureImage image: NSImage)
}

extension ComposeMenuButton: NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window == cameraWindow {
      cameraViewController?.captureSession?.stopRunning()
      cameraWindow = nil
      cameraViewController = nil
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let cameraVC = cameraViewController {
      cameraVC.animateClose { [weak self] in
        self?.cameraViewController?.captureSession?.stopRunning()
        self?.cameraWindow = nil
        self?.cameraViewController = nil
      }
      return false // We'll close the window after animation
    }
    return true
  }
}
