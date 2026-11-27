import AppKit
import TimelineAppKit
import TimelineCore

/// `--play [--count N] [--groups N] [--no-native]`: the lab chat in a window to try by hand with a real trackpad,
/// mouse wheel and keys, next to a plain NSScrollView (stripes) for comparing the feel. Buttons in the top band make
/// the changes the suite makes: arrivals, a streamed reply, sending, deleting, a history page, the composer growing, a
/// far jump.
@MainActor
final class Playground: NSObject {
  let window: NSWindow
  let chat: LabChat
  let view: LabChatView
  private var native: (window: NSWindow, reference: NativeReference)?
  private var composerStep = 0
  private var timers: [Timer] = []

  init(count: Int, groupRun: Int, showsNative: Bool) {
    let size = NSSize(width: 760, height: 820)
    window = NSWindow(
      contentRect: NSRect(origin: LabPlacement.origin, size: size),
      styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Timeline lab: \(count) messages"
    window.isReleasedWhenClosed = false
    chat = LabChat(count: count, groupRun: groupRun)
    view = LabChatView(chat: chat)
    super.init()
    view.frame = window.contentView!.bounds
    view.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(view)
    addButtons()
    window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    view.start()
    window.makeFirstResponder(view.list)

    if showsNative {
      let frame = NSRect(x: 0, y: 0, width: 360, height: size.height)
      let reference = NativeReference(frame: frame)
      let nativeWindow = NSWindow(
        contentRect: NSRect(origin: LabPlacement.origin(dx: size.width + 16), size: frame.size),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
      )
      nativeWindow.title = "NSScrollView (reference feel)"
      nativeWindow.isReleasedWhenClosed = false
      reference.scrollView.frame = nativeWindow.contentView!.bounds
      reference.scrollView.autoresizingMask = [.width, .height]
      nativeWindow.contentView!.addSubview(reference.scrollView)
      reference.scroll(to: reference.maxOrigin / 2)
      nativeWindow.orderFront(nil)
      native = (nativeWindow, reference)
    }
  }

  private func addButtons() {
    let actions: [(String, Selector)] = [
      ("Arrive", #selector(arrive)), ("Burst", #selector(burst)), ("Stream", #selector(stream)),
      ("Send", #selector(send)), ("Delete newest", #selector(deleteNewest)), ("Page above", #selector(pageAbove)),
      ("Composer", #selector(composer)), ("Jump far", #selector(jumpFar)), ("Newest", #selector(newest)),
    ]
    let stack = NSStackView(views: actions.map { title, action in
      let button = NSButton(title: title, target: self, action: action)
      button.controlSize = .small
      button.bezelStyle = .push
      button.refusesFirstResponder = true
      return button
    })
    stack.orientation = .horizontal
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.band.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.band.leadingAnchor, constant: 8),
      stack.centerYAnchor.constraint(equalTo: view.band.centerYAnchor),
    ])
  }

  private var list: TimelineListView<Int> { view.list }

  private func words(_ count: Int) -> String {
    (0 ..< count).map { _ in String(LabChat.words.randomElement()!) }.joined(separator: " ")
  }

  @objc func arrive() {
    _ = chat.append(words(Int.random(in: 3 ... 30)), sender: Int.random(in: 1 ... 3))
    list.apply(TimelineTransaction(rows: chat.ids, timing: .standard))
  }

  @objc func burst() {
    for i in 0 ..< 8 {
      timers.append(Timer.scheduledTimer(withTimeInterval: Double(i) * 0.03, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.arrive() }
      })
    }
  }

  @objc func stream() {
    let id = chat.append("…", sender: 2)
    list.apply(TimelineTransaction(rows: chat.ids, timing: .standard))
    for i in 1 ... 24 {
      timers.append(Timer.scheduledTimer(withTimeInterval: Double(i) * 0.08, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let text = self.chat.row(id)?.text else { return }
          self.chat.setText(id, (i == 1 ? "" : text + " ") + self.words(4))
          self.list.apply(TimelineTransaction(changed: [id], timing: .streamingLine))
        }
      })
    }
  }

  @objc func send() {
    _ = chat.append(words(Int.random(in: 2 ... 16)), outgoing: true)
    list.apply(TimelineTransaction(rows: chat.ids, scroll: .latest, timing: .standard, towards: .newer))
  }

  @objc func deleteNewest() {
    guard let last = chat.ids.last else { return }
    chat.delete(last)
    list.apply(TimelineTransaction(rows: chat.ids, timing: .standard))
  }

  @objc func pageAbove() {
    _ = chat.prepend(50)
    list.apply(TimelineTransaction(rows: chat.ids, arrives: false))
  }

  @objc func composer() {
    let steps = [2, 5, 1]
    view.setComposerLines(steps[composerStep % steps.count])
    composerStep += 1
  }

  @objc func jumpFar() {
    let ids = chat.ids
    guard ids.count > 20 else { return }
    list.apply(TimelineTransaction(scroll: .to(ids[ids.count / 10], .center), timing: .standard, towards: .older))
  }

  @objc func newest() {
    list.apply(TimelineTransaction(scroll: .latest, timing: .standard, towards: .newer))
  }
}
