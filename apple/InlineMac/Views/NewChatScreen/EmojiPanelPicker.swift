import AppKit
import SwiftUI

struct EmojiPanelPicker: NSViewRepresentable {
  @Binding var presentationRequest: Int
  var onEmojiSelected: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onEmojiSelected: onEmojiSelected)
  }

  func makeNSView(context: Context) -> EmojiPanelPickerView {
    EmojiPanelPickerView(onEmojiSelected: onEmojiSelected)
  }

  func updateNSView(_ nsView: EmojiPanelPickerView, context: Context) {
    nsView.onEmojiSelected = onEmojiSelected
    if context.coordinator.lastRequest != presentationRequest {
      context.coordinator.lastRequest = presentationRequest
      nsView.showEmojiPanel()
    }
  }
}

extension EmojiPanelPicker {
  final class Coordinator {
    var lastRequest: Int = 0
    var onEmojiSelected: (String) -> Void

    init(onEmojiSelected: @escaping (String) -> Void) {
      self.onEmojiSelected = onEmojiSelected
    }
  }
}

final class EmojiPanelPickerView: NSView, NSTextViewDelegate {
  var onEmojiSelected: (String) -> Void
  private let textView: NSTextView
  private let scrollView: NSScrollView
  private var isHandlingChange = false
  private weak var paletteWindow: NSWindow?

  init(onEmojiSelected: @escaping (String) -> Void) {
    self.onEmojiSelected = onEmojiSelected
    textView = NSTextView(frame: .zero)
    scrollView = NSScrollView(frame: .zero)
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = false
    textView.textColor = NSColor.clear
    textView.insertionPointColor = NSColor.clear
    textView.importsGraphics = true
    textView.alignment = .center
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.delegate = self

    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func showEmojiPanel() {
    focusWindowIfNeeded()
    _ = window?.makeFirstResponder(textView)
    let showSelector = Selector(("showEmojiAndSymbols:"))
    if NSApplication.shared.sendAction(showSelector, to: nil, from: textView) == false {
      NSApplication.shared.orderFrontCharacterPalette(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.repositionCharacterPalette()
    }
  }

  private func focusWindowIfNeeded() {
    guard let window else { return }
    if !NSApplication.shared.isActive {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
    }
  }

  func textDidChange(_ notification: Notification) {
    guard isHandlingChange == false else { return }
    let attributedString = textView.attributedString()
    let text = filteredPlainText(from: attributedString)
    guard text.isEmpty == false else { return }

    let firstEmoji = String(text.prefix(1))
    isHandlingChange = true
    onEmojiSelected(firstEmoji)
    textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    isHandlingChange = false
  }

  private func repositionCharacterPalette() {
    guard let palette = locateCharacterPaletteWindow() else { return }
    guard let window else { return }

    let anchorRect = convert(bounds, to: nil)
    let screenRect = window.convertToScreen(anchorRect)
    guard let screen = window.screen ?? NSScreen.main else { return }

    let paletteSize = palette.frame.size
    let padding: CGFloat = 8
    var origin = CGPoint(
      x: screenRect.midX - paletteSize.width / 2,
      y: screenRect.minY - paletteSize.height - padding
    )

    let visible = screen.visibleFrame
    if origin.y < visible.minY {
      origin.y = min(visible.maxY - paletteSize.height, screenRect.maxY + padding)
    }
    origin.x = min(max(origin.x, visible.minX), visible.maxX - paletteSize.width)

    palette.setFrameOrigin(origin)
  }

  private func locateCharacterPaletteWindow() -> NSWindow? {
    if let paletteWindow, paletteWindow.isVisible {
      return paletteWindow
    }

    let windows = NSApplication.shared.windows.filter { $0.isVisible && $0 !== window }
    let classNameMatch = windows.first { candidate in
      let className = String(describing: type(of: candidate))
      return className.contains("CharacterPalette")
        || className.contains("CharacterPicker")
        || className.contains("Emoji")
    }

    if let classNameMatch {
      paletteWindow = classNameMatch
      return classNameMatch
    }

    if let keyFloating = windows.first(where: { $0.level == .floating && $0.isKeyWindow }) {
      paletteWindow = keyFloating
      return keyFloating
    }

    if let floating = windows.first(where: { $0.level == .floating }) {
      paletteWindow = floating
      return floating
    }

    return nil
  }

  private func filteredPlainText(from attributedString: NSAttributedString) -> String {
    let placeholder = "\u{FFFC}"
    let raw = attributedString.string
    let cleaned = raw
      .replacingOccurrences(of: placeholder, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = cleaned.filter { character in
      character.unicodeScalars.contains { !$0.isASCII }
    }
    return String(filtered)
  }
}
