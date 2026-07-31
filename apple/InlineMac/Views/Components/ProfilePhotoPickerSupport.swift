import AppKit
import InlineKit
import InlineUI
import MemojiKit
import MemojiPickerUI
import RealtimeV2
import Security
import SwiftUI
import UniformTypeIdentifiers

struct EditableProfileAvatar<AvatarContent: View>: View {
  private enum PresentedSheet: String, Identifiable {
    case x
    case memoji

    var id: Self { self }
  }

  @State private var presentedSheet: PresentedSheet?
  @State private var showsFileImporter = false
  @State private var selectedMemojiPhoto: MemojiPhoto?
  @State private var isHovering = false
  @State private var isDropTargeted = false

  let size: CGFloat
  let hasPhoto: Bool
  let showsMemoji: Bool
  let isBusy: Bool
  let onPickFile: @MainActor (URL) -> Void
  let onFilePickerFailure: @MainActor (Error) -> Void
  let onUsePhotoData: @MainActor (Data) async -> Bool
  let onMemojiFailure: @MainActor (MemojiError) -> Void
  let onRemove: () -> Void
  @ViewBuilder let avatar: (CGFloat) -> AvatarContent

  var body: some View {
    ZStack {
      ProfileAvatarSurface(
        size: size,
        isBusy: isBusy,
        isDropTargeted: isDropTargeted,
        isHovering: isHovering,
        avatar: avatar
      )

      ProfileAvatarMenuControl(
        isHovering: $isHovering,
        hasPhoto: hasPhoto,
        showsMemoji: showsMemoji,
        isBusy: isBusy,
        onChoosePhoto: presentFileImporter,
        onChooseX: { present(.x) },
        onChooseMemoji: { present(.memoji) },
        onRemove: onRemove
      )
      .frame(width: size, height: size)
    }
    .frame(width: size, height: size)
    .fixedSize()
    .disabled(isBusy)
    .help("Change Profile Photo")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Profile photo")
    .accessibilityHint("Opens photo options")
    .fileImporter(
      isPresented: $showsFileImporter,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false,
      onCompletion: handleFileSelection
    )
    .sheet(item: $presentedSheet) { sheet in
      switch sheet {
      case .x:
        XProfilePhotoPicker(
          isUploading: isBusy,
          onUse: onUsePhotoData
        )
      case .memoji:
        MemojiPicker(
          selection: $selectedMemojiPhoto,
          onFailure: onMemojiFailure
        )
      }
    }
    .onChange(of: selectedMemojiPhoto) { _, photo in
      guard let photo else { return }
      selectedMemojiPhoto = nil
      Task {
        _ = await onUsePhotoData(photo.pngData)
      }
    }
    .dropDestination(for: Data.self) { items, _ in
      guard let data = items.first else { return false }
      Task {
        _ = await onUsePhotoData(data)
      }
      return true
    } isTargeted: { isDropTargeted = $0 }
  }

  private func presentFileImporter() {
    Task { @MainActor in
      await Task.yield()
      showsFileImporter = true
    }
  }

  private func present(_ sheet: PresentedSheet) {
    Task { @MainActor in
      await Task.yield()
      presentedSheet = sheet
    }
  }

  private func handleFileSelection(_ result: Result<[URL], Error>) {
    switch result {
    case let .success(urls):
      guard let url = urls.first else { return }
      onPickFile(url)
    case let .failure(error):
      onFilePickerFailure(error)
    }
  }
}

private struct ProfileAvatarSurface<AvatarContent: View>: View {
  let size: CGFloat
  let isBusy: Bool
  let isDropTargeted: Bool
  let isHovering: Bool
  @ViewBuilder let avatar: (CGFloat) -> AvatarContent

  var body: some View {
    ZStack {
      avatar(size)
        .frame(width: size, height: size)
        .clipped()

      VStack(spacing: 0) {
        Spacer(minLength: 0)
        ZStack(alignment: .bottom) {
          LinearGradient(
            colors: [.clear, .black.opacity(0.72)],
            startPoint: .top,
            endPoint: .bottom
          )
          Text("Edit")
            .font(.system(size: max(9, size * 0.16), weight: .semibold))
            .foregroundStyle(.white)
            .padding(.bottom, max(3, size * 0.055))
        }
        .frame(height: max(22, size * 0.44))
        .frame(maxWidth: .infinity)
      }
      .opacity(isHovering && !isBusy ? 1 : 0)

      if isBusy {
        Color.black.opacity(0.28)
        ProgressView()
          .controlSize(.small)
          .tint(.white)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .contentShape(Circle())
    .overlay {
      Circle().stroke(
        isDropTargeted ? Color.accentColor : .clear,
        lineWidth: 2
      )
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .animation(.easeOut(duration: 0.12), value: isDropTargeted)
  }
}

private struct ProfileAvatarMenuControl: NSViewRepresentable {
  @Binding var isHovering: Bool

  let hasPhoto: Bool
  let showsMemoji: Bool
  let isBusy: Bool
  let onChoosePhoto: @MainActor () -> Void
  let onChooseX: @MainActor () -> Void
  let onChooseMemoji: @MainActor () -> Void
  let onRemove: @MainActor () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> CircularAvatarMenuButton {
    let button = CircularAvatarMenuButton()
    button.focusRingType = .none
    button.setAccessibilityLabel("Profile photo")
    button.setAccessibilityHelp("Opens photo options")
    button.onHover = { [weak coordinator = context.coordinator] isHovering in
      coordinator?.parent.isHovering = isHovering
    }
    context.coordinator.updateMenu(for: button)
    return button
  }

  func updateNSView(_ button: CircularAvatarMenuButton, context: Context) {
    context.coordinator.parent = self
    button.isEnabled = !isBusy
    context.coordinator.updateMenu(for: button)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: ProfileAvatarMenuControl
    private var menuSignature = ""

    init(parent: ProfileAvatarMenuControl) {
      self.parent = parent
    }

    func updateMenu(for button: CircularAvatarMenuButton) {
      let signature = "\(parent.showsMemoji):\(parent.hasPhoto)"
      guard signature != menuSignature else { return }
      menuSignature = signature

      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.minimumWidth = 240
      menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
      menu.addItem(item(
        "Choose Photo…",
        subtitle: "Select an image from your Mac.",
        symbol: "photo",
        action: #selector(choosePhoto)
      ))
      menu.addItem(item(
        "From X…",
        subtitle: "Find your public X profile photo.",
        symbol: "at",
        action: #selector(chooseX)
      ))
      if parent.showsMemoji {
        menu.addItem(item(
          "Memoji",
          subtitle: "Choose from your saved Memoji.",
          symbol: "face.smiling",
          action: #selector(chooseMemoji)
        ))
      }
      if parent.hasPhoto {
        menu.addItem(.separator())
        menu.addItem(item(
          "Remove Photo",
          subtitle: "Use your initials instead.",
          symbol: "trash",
          action: #selector(removePhoto)
        ))
      }
      button.menu = menu
    }

    private func item(
      _ title: String,
      subtitle: String,
      symbol: String,
      action: Selector
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.subtitle = subtitle
      if let image = NSImage(
        systemSymbolName: symbol,
        accessibilityDescription: title
      )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
        image.isTemplate = true
        item.image = image
      }
      return item
    }

    @objc private func choosePhoto() {
      parent.onChoosePhoto()
    }

    @objc private func chooseX() {
      parent.onChooseX()
    }

    @objc private func chooseMemoji() {
      parent.onChooseMemoji()
    }

    @objc private func removePhoto() {
      parent.onRemove()
    }
  }
}

@MainActor
private final class CircularAvatarMenuButton: NSPopUpButton {
  var onHover: ((Bool) -> Void)?
  private var hoverTrackingArea: NSTrackingArea?

  init() {
    super.init(frame: .zero, pullsDown: true)
    isBordered = false
    title = ""
    bezelStyle = .shadowlessSquare
    (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
      owner: self
    )
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    onHover?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHover?(false)
  }

}

enum MemojiBetaRollout {
  private static let avatarServiceNames = [
    "com.apple.avatar.service",
    "com.apple.avatar.support",
  ]

  @MainActor
  static func isEnabled(dependencies: AppDependencies?) -> Bool {
    guard hostCanReachAvatarServices else { return false }

    #if DEBUG || DEBUG_BUILD
    return true
    #elseif SPARKLE
    return isBetaDistribution || dependencies?.updates.channel == .beta
    #else
    return false
    #endif
  }

  private static var isBetaDistribution: Bool {
    let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    return feedURL?.contains("/beta/") == true
  }

  private static let hostCanReachAvatarServices: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let sandboxValue = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.security.app-sandbox" as CFString,
      nil
    )
    let isSandboxed = sandboxValue as? Bool ?? false
    guard isSandboxed else { return true }

    let exceptionValue = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.security.temporary-exception.mach-lookup.global-name" as CFString,
      nil
    )
    let allowedServices = Set(exceptionValue as? [String] ?? [])
    return avatarServiceNames.allSatisfy(allowedServices.contains)
  }()
}

struct MemojiBetaDiagnosticError: LocalizedError {
  let code: MemojiFailureCode
  let summary: String

  var errorDescription: String? {
    "\(code.rawValue): \(summary)"
  }
}

struct XProfilePhotoPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2
  @FocusState private var isHandleFocused: Bool
  @State private var handle = ""
  @State private var lookupState = XAvatarLookupState.idle
  @State private var lastAttemptedHandle: String?

  let isUploading: Bool
  let onUse: (Data) async -> Bool

  var body: some View {
    VStack(spacing: 16) {
      Text("Photo from X")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)

      XProfilePhotoPreview(
        image: lookupState.image,
        isLoading: lookupState.isLoading || isUploading
      )

      GrayTextField("username", text: $handle, prefix: "@", size: .small)
        .textContentType(.username)
        .focused($isHandleFocused)
        .frame(maxWidth: .infinity)
        .onSubmit(loadPhotoManually)

      if let message = lookupState.errorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      HStack(spacing: 10) {
        Spacer()

        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Use Photo") {
          guard let data = lookupState.imageData else { return }
          usePhoto(data)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(lookupState.imageData == nil || isUploading)
      }
    }
    .frame(width: 320, alignment: .topLeading)
    .padding(20)
    .onAppear { isHandleFocused = true }
    .onChange(of: handle) {
      lookupState = .idle
      lastAttemptedHandle = nil
    }
    .task(id: handle) {
      guard XProfileHandle.normalize(handle) != nil else { return }
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await findPhoto()
    }
  }

  private func loadPhotoManually() {
    Task { await findPhoto(force: true) }
  }

  private func usePhoto(_ data: Data) {
    Task {
      if await onUse(data) {
        dismiss()
      }
    }
  }

  private func findPhoto(force: Bool = false) async {
    guard let normalizedHandle = XProfileHandle.normalize(handle) else {
      lookupState = .failed("Enter a valid X username.")
      return
    }
    guard force || lastAttemptedHandle != normalizedHandle else { return }

    lastAttemptedHandle = normalizedHandle
    lookupState = .loading
    do {
      let result = try await realtimeV2.getExternalProfilePhoto(provider: .x, username: normalizedHandle)
      guard XProfileHandle.normalize(handle) == normalizedHandle, !Task.isCancelled else { return }
      lookupState = switch result.status {
      case .externalProfilePhotoFound where !result.photo.isEmpty:
        .found(result.photo)
      case .externalProfilePhotoNotFound:
        .failed("No public profile photo was found for that username.")
      case .externalProfilePhotoUnavailable:
        .failed("X photo lookup is temporarily unavailable. Try again later.")
      case .unspecified, .externalProfilePhotoFound, .UNRECOGNIZED:
        .failed("That profile photo could not be loaded.")
      }
    } catch {
      guard !Task.isCancelled else { return }
      lookupState = .failed(error.localizedDescription)
    }
  }
}

private struct XProfilePhotoPreview: View {
  private let size: CGFloat = 72

  let image: NSImage?
  let isLoading: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(.primary.opacity(0.07))

      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      }

      if isLoading {
        Circle().fill(.black.opacity(0.18))
        ProgressView().controlSize(.mini).tint(.white)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .fixedSize()
    .overlay { Circle().stroke(.primary.opacity(0.10), lineWidth: 1) }
  }
}

private enum XAvatarLookupState {
  case idle
  case loading
  case found(Data)
  case failed(String)

  var imageData: Data? {
    guard case let .found(data) = self else { return nil }
    return data
  }

  var image: NSImage? {
    imageData.flatMap(NSImage.init(data:))
  }

  var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }

  var errorMessage: String? {
    guard case let .failed(message) = self else { return nil }
    return message
  }
}

private enum XProfileHandle {
  static func normalize(_ input: String) -> String? {
    var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)

    if let url = URL(string: candidate),
       let host = url.host?.lowercased(),
       ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host),
       let pathHandle = url.pathComponents.dropFirst().first {
      candidate = pathHandle
    }

    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    guard 1 ... 15 ~= candidate.utf8.count,
          candidate.utf8.allSatisfy(isAllowedHandleByte)
    else { return nil }
    return candidate
  }

  private static func isAllowedHandleByte(_ byte: UInt8) -> Bool {
    byte == 95 || (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
  }
}

enum ProfilePhotoProcessor {
  enum ProcessingError: LocalizedError {
    case invalidImage

    var errorDescription: String? { "That image could not be used." }
  }

  nonisolated static func prepare(_ data: Data) throws -> Data {
    guard data.count <= 10 * 1_024 * 1_024,
          let image = NSImage(data: data)
    else { throw ProcessingError.invalidImage }

    var sourceRect = NSRect(origin: .zero, size: image.size)
    guard let source = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else {
      throw ProcessingError.invalidImage
    }

    let side = min(source.width, source.height)
    let cropRect = CGRect(
      x: (source.width - side) / 2,
      y: (source.height - side) / 2,
      width: side,
      height: side
    )
    guard let cropped = source.cropping(to: cropRect) else { throw ProcessingError.invalidImage }

    let outputSide = min(side, 1_024)
    guard let context = CGContext(
      data: nil,
      width: outputSide,
      height: outputSide,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ProcessingError.invalidImage }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
    guard let output = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    else { throw ProcessingError.invalidImage }
    return png
  }
}
