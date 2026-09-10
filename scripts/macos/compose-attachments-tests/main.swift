final class Owner: ComposeAttachmentOwner {
  weak var strip: ComposeAttachments?
  func removeImage(_ id: String) { strip?.removeImageView(id: id) }
  func removeVideo(_ id: String) { strip?.removeVideoView(id: id) }
  func removeFile(_ id: String) { strip?.removeDocumentView(id: id) }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()
let window = NSWindow(
  contentRect: NSRect(x: 120, y: 160, width: 680, height: 330),
  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
)
window.title = "Inline attachment animation checks — production views"
let root = window.contentView!
root.wantsLayer = true
let heading = NSTextField(labelWithString: "Shared attachment strip · rapid lifecycle checks")
heading.font = .systemFont(ofSize: 18, weight: .semibold)
heading.frame = NSRect(x: 20, y: 275, width: 620, height: 26)
root.addSubview(heading)
let status = NSTextField(labelWithString: "Starting")
status.frame = NSRect(x: 20, y: 245, width: 620, height: 24)
root.addSubview(status)
let input = NSTextField(labelWithString: "+     Attachment animation fixture")
input.font = .systemFont(ofSize: 17)
input.frame = NSRect(x: 20, y: 15, width: 500, height: 24)
root.addSubview(input)
let owner = Owner()
let strip = ComposeAttachments(frame: .zero, compose: owner)
owner.strip = strip
strip.wantsLayer = true
strip.translatesAutoresizingMaskIntoConstraints = false
root.addSubview(strip)
NSLayoutConstraint.activate([
  strip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
  strip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
  strip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -48),
])
func pump(_ seconds: TimeInterval = 0.025) {
  root.layoutSubtreeIfNeeded()
  CATransaction.flush()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  root.layoutSubtreeIfNeeded()
}
func media() -> NSCollectionView { (strip.subviews[0] as! NSScrollView).documentView as! NSCollectionView }
func check(_ count: Int) {
  pump(0.22)
  let collection = media()
  precondition(collection.numberOfItems(inSection: 0) == count, "Incorrect item count")
  if count > 0 {
    precondition(collection.bounds.height >= 80, "Collapsed collection content")
    if collection.visibleItems().isEmpty {
      let scroll = strip.subviews[0] as! NSScrollView
      FileHandle.standardError.write(Data("EMPTY: strip=\(strip.frame) scroll=\(scroll.frame) clip=\(scroll.contentView.bounds) collection=\(collection.frame) items=\(collection.numberOfItems(inSection: 0)) hidden=\(scroll.isHidden) layout=\(collection.collectionViewLayout!)\n".utf8))
    }
    precondition(!collection.visibleItems().isEmpty, "No visible thumbnails")
    for item in collection.visibleItems() {
      precondition(item.view.alphaValue == 1, "Hidden model opacity")
      precondition(item.view.bounds.height >= 80 && !item.view.subviews.isEmpty, "Empty item")
      precondition(item.view.subviews[0].bounds.height >= 80, "Collapsed thumbnail")
    }
  }
}
func fixture(_ color: NSColor, _ text: String) -> NSImage {
  NSImage(size: NSSize(width: 160, height: 120), flipped: false) { rect in
    color.setFill()
    rect.fill()
    let path = NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 60, height: 60))
    NSColor.white.withAlphaComponent(0.3).setFill()
    path.fill()
    (text as NSString).draw(at: NSPoint(x: 12, y: 10), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white])
    return true
  }
}
let photo = fixture(.systemBlue, "PHOTO")
let video = fixture(.systemPurple, "VIDEO")
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
pump(0.2)
for cycle in 0..<10 {
  status.stringValue = "Rapid cycle \(cycle + 1) / 10"
  strip.addImageView(photo, id: "photo")
  pump(0.035)
  // Cancel before the 0.2-second fade ends, rather than after check() settles it.
  let insertedItem = media().visibleItems().first!
  precondition(insertedItem.view.alphaValue == 1, "Insertion hid model opacity")
  if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    precondition(insertedItem.view.layer?.animation(forKey: "composeAttachmentInsertion") != nil,
                 "Expected an active insertion fade before cancellation")
  }
  insertedItem.view.layer?.removeAnimation(forKey: "composeAttachmentInsertion")
  check(1)
  strip.removeImageView(id: "photo")
  strip.addImageView(photo, id: "photo")
  strip.addPendingAttachment(id: "pending")
  strip.removeDocumentView(id: "pending")
  strip.addVideoView(thumbnail: video, videoURL: nil, id: "video")
  check(2)
  strip.setExternallyCollapsed(true)
  strip.setExternallyCollapsed(false)
  check(2)
  strip.clearViews(animated: true)
  check(0)
}
print("PASS: 10 rapid insertion/cancellation/replacement/pending-conversion/collapse/clear cycles")
for _ in 0..<100 {
  strip.addImageView(photo, id: "burst")
  strip.removeImageView(id: "burst")
  strip.addImageView(photo, id: "burst")
  strip.clearViews(animated: true)
}
strip.addImageView(photo, id: "burst-final")
check(1)
strip.clearViews()
print("PASS: 100 same-turn replacement/clear bursts")
// Exercise a pending row, same-ID ready row, mixed media/documents, and scroll reuse.
strip.addPendingAttachment(id: "document")
pump(0.25)
strip.addDocumentView(DocumentInfo(), id: "document")
pump(0.25)
let documents = (strip.subviews[1] as! NSScrollView).documentView as! NSCollectionView
precondition(documents.numberOfItems(inSection: 0) == 1 && !documents.visibleItems().isEmpty)
strip.addImageView(photo, id: "mixed")
check(1)
precondition(!documents.visibleItems().isEmpty)
strip.clearViews()
for index in 0..<15 { strip.addImageView(photo, id: "scroll-\(index)") }
check(15)
media().scrollToItems(at: [IndexPath(item: 14, section: 0)], scrollPosition: .right)
check(15)
strip.clearViews()
strip.addImageView(photo, id: "after-scroll")
check(1)
strip.clearViews()
print("PASS: pending/ready documents, mixed content, scroll/reuse/reset")
// Add while detached, then attach and resize. AppKit must realize the items.
strip.removeFromSuperview()
strip.addImageView(photo, id: "detached")
root.addSubview(strip)
NSLayoutConstraint.activate([
  strip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
  strip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
  strip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -48),
])
for width in [360.0, 900.0, 680.0] {
  window.setContentSize(NSSize(width: width, height: 330))
  check(1)
}
strip.clearViews()
pump(0.25)
status.stringValue = "Visual sequence: fade in → hide → rapid replacement → dark mode"
func captureSnapshot(_ name: String) throws {
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
  try capture.run()
  while capture.isRunning { pump(0.005) }
  precondition(capture.terminationStatus == 0, "Visual capture failed")
}
try captureSnapshot("01-empty")
strip.addImageView(photo, id: "fade")
pump(0.045)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
  let item = media().visibleItems().first!
  let opacity = item.view.layer?.presentation()?.opacity ?? 1
  print("Fade sample opacity: \(opacity)")
  precondition(opacity > 0 && opacity < 1, "Insertion fade did not animate")
}
try captureSnapshot("02-fading-in")
pump(0.4)
strip.addVideoView(thumbnail: video, videoURL: nil, id: "video")
pump(0.6)
try captureSnapshot("03-visible-light")
let heightBefore = strip.layer!.presentation()!.bounds.height
strip.clearViews(animated: true)
pump(0.045)
let hideHeight = strip.layer!.presentation()!.bounds.height
print("Hide sample height: \(heightBefore) → \(hideHeight)")
precondition(hideHeight > 0 && hideHeight < heightBefore, "Hide did not animate")
try captureSnapshot("04-hiding")
pump(0.5)
try captureSnapshot("05-hidden")
strip.addImageView(photo, id: "replacement")
strip.removeImageView(id: "replacement")
strip.addImageView(photo, id: "replacement")
strip.addVideoView(thumbnail: video, videoURL: nil, id: "video")
pump(0.6)
window.appearance = NSAppearance(named: .darkAqua)
pump(0.6)
strip.clearViews(animated: true)
pump(0.4)
strip.addImageView(photo, id: "final")
strip.addVideoView(thumbnail: video, videoURL: nil, id: "final-video")
pump(0.6)
check(2)
try captureSnapshot("06-visible-dark")
print("PASS: live fade, animated hide, detached insertion, narrow/wide resize, light/dark appearance")
window.orderOut(nil)
