import AppKit
import InlineContextMenu

@MainActor
final class LabWindowController: NSObject {
  let lab = LabController()
  let window: NSWindow
  private(set) var bubbles: [NSView] = []
  private let logView = NSTextView()
  private let modePopup = NSPopUpButton()

  override init() {
    window = NSWindow(
      contentRect: NSRect(x: 120, y: 160, width: 1040, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init()
    window.title = "Context Menu Lab"
    window.isReleasedWhenClosed = false
    build()
  }

  private func build() {
    let messages = [
      LabMessage(id: 1, text: "Morning! Did the build go out?", outgoing: false),
      LabMessage(id: 2, text: "Yes, 0.9.4 is on TestFlight. Right-click any message.", outgoing: true),
      LabMessage(id: 3, text: "Reactions should be one gesture away, not two.", outgoing: false, reactions: ["👍"]),
      LabMessage(id: 4, text: "This one was edited.", outgoing: true, edited: true),
    ]
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 60, left: 24, bottom: 24, right: 24)
    stack.alignment = .leading
    for message in messages {
      let bubble = BubbleView(message: message, lab: lab)
      bubbles.append(bubble)
      stack.addArrangedSubview(bubble)
      if message.outgoing {
        bubble.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -24).isActive = true
      }
    }
    let textBubble = TextBubbleView(message: LabMessage(id: 5, text: "Select some of this text, then right-click: Look Up and Translate come from the text view.", outgoing: false), lab: lab)
    bubbles.append(textBubble)
    stack.addArrangedSubview(textBubble)

    let chat = NSView()
    chat.wantsLayer = true
    chat.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    stack.translatesAutoresizingMaskIntoConstraints = false
    chat.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: chat.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: chat.trailingAnchor),
      stack.topAnchor.constraint(equalTo: chat.topAnchor),
    ])

    let controls = NSStackView()
    controls.orientation = .vertical
    controls.alignment = .leading
    controls.spacing = 8
    controls.edgeInsets = NSEdgeInsets(top: 60, left: 16, bottom: 16, right: 16)

    modePopup.addItems(withTitles: LabMode.allCases.map(\.title))
    modePopup.target = self
    modePopup.action = #selector(modeChanged)
    let animationPopup = NSPopUpButton()
    animationPopup.addItems(withTitles: ["Pop", "Fade", "None"])
    animationPopup.target = self
    animationPopup.action = #selector(animationChanged(_:))
    let materialPopup = NSPopUpButton()
    materialPopup.addItems(withTitles: ["Automatic", "Glass", "Vibrancy"])
    materialPopup.target = self
    materialPopup.action = #selector(materialChanged(_:))
    let clear = NSButton(title: "Clear Log", target: self, action: #selector(clearLog))

    logView.isEditable = false
    logView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
    let logScroll = NSScrollView()
    logScroll.documentView = logView
    logScroll.hasVerticalScroller = true
    logView.autoresizingMask = [.width]
    logScroll.translatesAutoresizingMaskIntoConstraints = false
    logScroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
    logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

    for view in [label("Approach"), modePopup, label("Animation (custom)"), animationPopup, label("Material (custom)"), materialPopup, clear, logScroll] {
      controls.addArrangedSubview(view)
    }

    let split = NSStackView(views: [chat, controls])
    split.orientation = .horizontal
    split.spacing = 0
    split.distribution = .fill
    chat.setContentHuggingPriority(.defaultLow, for: .horizontal)
    controls.setContentHuggingPriority(.required, for: .horizontal)
    window.contentView = split

    lab.onLog = { [weak self] line in
      guard let self else { return }
      self.logView.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [.font: self.logView.font!, .foregroundColor: NSColor.labelColor]))
      self.logView.scrollToEndOfDocument(nil)
    }
  }

  private func label(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 11, weight: .semibold)
    field.textColor = .secondaryLabelColor
    return field
  }

  func setMode(_ mode: LabMode) {
    lab.mode = mode
    modePopup.selectItem(at: LabMode.allCases.firstIndex(of: mode) ?? 0)
  }

  @objc private func modeChanged() {
    lab.mode = LabMode.allCases[modePopup.indexOfSelectedItem]
    lab.log("mode \(lab.mode.rawValue)")
  }

  @objc private func animationChanged(_ sender: NSPopUpButton) {
    lab.animation = [.pop, .fade, .none][sender.indexOfSelectedItem]
  }

  @objc private func materialChanged(_ sender: NSPopUpButton) {
    lab.material = [.automatic, .glass, .vibrancy][sender.indexOfSelectedItem]
  }

  @objc private func clearLog() {
    logView.string = ""
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var controller: LabWindowController!
  let arguments = CommandLine.arguments

  func applicationDidFinishLaunching(_ notification: Notification) {
    controller = LabWindowController()
    controller.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let out = value(after: "--out")
    if arguments.contains("--selftest") {
      // A run-loop timer, not a main-queue block: main-queue work cannot run inside a nested run loop
      // started from another main-queue block, and the checks spin the run loop.
      let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
        MainActor.assumeIsolated { SelfTest(controller: self.controller).run(out: out) }
      }
      RunLoop.main.add(timer, forMode: .common)
    } else if let path = value(after: "--record") {
      let index = value(after: "--bubble").flatMap(Int.init) ?? 1
      let dark = arguments.contains("--dark")
      let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
        MainActor.assumeIsolated { MenuCompare.record(controller: self.controller, path: path, bubbleIndex: index, dark: dark) }
      }
      RunLoop.main.add(timer, forMode: .common)
    } else if let dir = value(after: "--compare") {
      let index = value(after: "--bubble").flatMap(Int.init) ?? 0
      let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
        MainActor.assumeIsolated { MenuCompare.run(controller: self.controller, dir: dir, bubbleIndex: index) }
      }
      RunLoop.main.add(timer, forMode: .common)
    } else if arguments.contains("--dump-native") {
      let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
        MainActor.assumeIsolated { NativeMenuDump.run(controller: self.controller, out: out, shotDir: self.value(after: "--shots")) }
      }
      RunLoop.main.add(timer, forMode: .common)
    } else if let probe = value(after: "--probe") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        RealEventProbe(controller: self.controller, scenario: probe, out: out).start()
      }
    } else if let mode = value(after: "--mode").flatMap(LabMode.init(rawValue:)) {
      controller.setMode(mode)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  private func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
