import AppKit

// Run: python3 scripts/macos/compose-scroll-tests/run.py
// Text loading must make the document scrollable immediately, before a later
// run-loop pass, a keystroke, or the parent's animated height change repairs it.
func check(_ condition: Bool, _ message: String) {
  guard condition else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

final class ChangeObserver: NSObject, ComposeTextViewDelegate {
  var changes = 0
  func textDidChange(_ notification: Notification) {
    changes += 1
    (notification.object as? NSTextView)?.updateTypingAttributesIfNeeded()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    (notification.object as? NSTextView)?.updateTypingAttributesIfNeeded()
  }
}

let app = NSApplication.shared
let fixtures = [
  ("multiline", String(repeating: "A line of the message being edited.\n", count: 60)),
  ("soft wraps", String(repeating: "This paragraph wraps across the composer. ", count: 100)),
  ("mixed RTL", String(repeating: "سلام دنیا — Inline 123 👩🏽‍💻\n", count: 60)),
  ("trailing blank lines", String(repeating: "Message line\n", count: 40) + "\n\n"),
]

for mode: ComposeControlMode in [.glass, .legacy] {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false
  )
  let root = window.contentView!
  root.wantsLayer = true
  let editor = ComposeTextEditor(mode: mode)
  let observer = ChangeObserver()
  editor.delegate = observer
  editor.translatesAutoresizingMaskIntoConstraints = false
  root.addSubview(editor)
  let height = editor.heightAnchor.constraint(equalToConstant: editor.minHeight)
  NSLayoutConstraint.activate([
    editor.leadingAnchor.constraint(equalTo: root.leadingAnchor),
    editor.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    editor.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    height,
  ])
  root.layoutSubtreeIfNeeded()
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
  window.makeFirstResponder(editor.textView)

  func updateHeight() {
    let contentHeight = ComposeTextEditor.measuredContentHeight(for: editor.textView)
    if mode == .legacy { editor.updateTextViewInsets(contentHeight: contentHeight) }
    let target = min(300, max(editor.minHeight, ceil(contentHeight + editor.textView.textContainerInset.height * 2)))
    editor.setHeight(target)
    height.constant = target
    root.layoutSubtreeIfNeeded()
  }

  func checkScrolling(_ label: String) {
    let textView = editor.textView
    let scroll = editor.scrollView
    let clip = scroll.contentView
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    check(textView.frame.height > clip.bounds.height, "\(label): no scrollable document")
    textView.scroll(NSPoint(x: clip.bounds.minX, y: 0))
    let start = clip.bounds.minY
    let down = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0
    )!
    scroll.scrollWheel(with: NSEvent(cgEvent: down)!)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    check(clip.bounds.minY > start,
          "\(label): scroll wheel cannot move down (start=\(start), clip=\(clip.bounds), document=\(textView.frame))")
    let scrolled = clip.bounds.minY
    let up = CGEvent(
      scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 120, wheel2: 0, wheel3: 0
    )!
    scroll.scrollWheel(with: NSEvent(cgEvent: up)!)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    check(clip.bounds.minY < scrolled, "\(label): scroll wheel cannot move up")
    textView.scrollToVisible(NSRect(x: 0, y: textView.bounds.maxY - 1, width: 1, height: 1))
    check(textView.visibleRect.maxY >= textView.bounds.maxY - 1, "\(label): bottom is unreachable")
  }

  for width: CGFloat in [500, 260] {
    window.setContentSize(NSSize(width: width, height: 600))
    root.layoutSubtreeIfNeeded()
    for (name, text) in fixtures {
      let label = "\(mode), \(Int(width))pt, \(name)"
      editor.clear()
      updateHeight()
      let message = NSMutableAttributedString(attributedString: editor.createAttributedString(text))
      let bold = NSFont.boldSystemFont(ofSize: ComposeTextEditor.font.pointSize)
      message.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 4))
      editor.replaceAttributedString(message)

      // Assert before parent layout can hide the stale document-size regression.
      let measured = ComposeTextEditor.measuredContentHeight(for: editor.textView)
      check(editor.textView.frame.height >= measured, "\(label): loaded text exceeds the document height")
      check(editor.textView.textLayoutManager != nil, "\(label): TextKit 2 was disabled")
      check(editor.string == text, "\(label): text changed")
      check(editor.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == bold,
            "\(label): formatting changed")
      updateHeight()
      checkScrolling(label)

      // Replace an already capped editor with another edit without changing its viewport.
      let selection = NSRange(location: 2, length: 3)
      editor.textView.setSelectedRange(selection)
      editor.textView.setAttributedText(message)
      check(editor.textView.selectedRange() == selection, "\(label): selection changed")
      checkScrolling(label + " repeated edit")
      check(observer.changes == 0, "\(label): loading an edit notified typing/draft observers")
      print("PASS: \(label)")
    }
  }

  editor.clear()
  updateHeight()
  check(editor.textView.frame.height <= editor.minHeight + 1, "\(mode): clear leaves stale scroll area")
  editor.insertText(fixtures[0].1)
  updateHeight()
  checkScrolling("\(mode): normal text insertion")
  check(observer.changes > 0, "\(mode): normal insertion did not notify observers")
  print("PASS: \(mode) clear and normal text insertion")

  let textView = editor.textView
  var linkAttributes = textView.defaultTypingAttributes
  linkAttributes[.link] = "https://example.com"
  linkAttributes[.foregroundColor] = ComposeTextEditor.linkColor
  linkAttributes[.cursor] = NSCursor.pointingHand
  let link = NSAttributedString(string: "Example", attributes: linkAttributes)

  func loadLink(prefix: String = "") {
    let text = NSMutableAttributedString(string: prefix, attributes: textView.defaultTypingAttributes)
    text.append(link)
    editor.replaceAttributedString(text)
    textView.setSelectedRange(NSRange(location: text.length, length: 0))
  }

  func checkPlainTyping(_ label: String) {
    let start = textView.selectedRange().location
    textView.insertText("hello", replacementRange: textView.selectedRange())
    let attributes = textView.attributedString().attributes(at: start, effectiveRange: nil)
    check(attributes[.link] == nil, "\(mode) \(label): new text is still a link")
    check(attributes[.foregroundColor] as? NSColor == ComposeTextEditor.textColor,
          "\(mode) \(label): new text is still blue")
    check(attributes[.cursor] == nil, "\(mode) \(label): new text retains link cursor")
    print("PASS: \(mode) \(label)")
  }

  loadLink()
  for _ in 0..<link.length { textView.deleteBackward(nil) }
  check(textView.string.isEmpty, "\(mode): backspace did not delete link")
  checkPlainTyping("backspace entire link")

  loadLink(prefix: "Before ")
  textView.setSelectedRange(NSRange(location: 7, length: link.length))
  textView.deleteBackward(nil)
  checkPlainTyping("delete selected link after plain text")

  loadLink()
  textView.setSelectedRange(NSRange(location: 0, length: link.length))
  textView.deleteForward(nil)
  checkPlainTyping("forward-delete selected link")

  // AppKit can also leave just the visual attributes after dropping .link.
  editor.clear()
  var staleAttributes = linkAttributes
  staleAttributes.removeValue(forKey: .link)
  let boldFont = NSFont.boldSystemFont(ofSize: ComposeTextEditor.font.pointSize)
  staleAttributes[.font] = boldFont
  staleAttributes[.richTextUnderline] = true
  staleAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
  textView.typingAttributes = staleAttributes
  textView.updateTypingAttributesIfNeeded()
  check(textView.typingAttributes[.font] as? NSFont == boldFont, "link reset lost bold")
  check(textView.typingAttributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue,
        "link reset lost intentional underline")
  checkPlainTyping("stale blue styling with intentional formatting")

  for position in [0, link.length] {
    loadLink()
    textView.setSelectedRange(NSRange(location: position, length: 0))
    textView.typingAttributes = linkAttributes
    textView.updateTypingAttributesIfNeeded()
    checkPlainTyping("typing at link boundary \(position)")
  }

  loadLink()
  textView.setSelectedRange(NSRange(location: 3, length: 0))
  textView.typingAttributes = linkAttributes
  textView.updateTypingAttributesIfNeeded()
  textView.insertText("x", replacementRange: textView.selectedRange())
  check(textView.attributedString().attribute(.link, at: 3, effectiveRange: nil) as? String == "https://example.com",
        "\(mode): editing inside a link lost its target")
  print("PASS: \(mode) editing inside surviving link")
}
