import AppKit
import QuartzCore
import Synchronization

/// Paces the reveal of messages that stream by appending to their text, as the iOS pacer does.
///
/// Bots and agents stream by editing a message with ever-longer snapshots. Each append becomes the new target, and a
/// display link advances the revealed character count toward it at a speed estimated from the gaps between edits, so
/// text flows at the rate it arrives instead of jumping a chunk per edit (Telegram reveals the same way). When edits
/// go idle, the pacer catches up quickly and the message finishes.
///
/// Rows are planned at the revealed count (`MessageSizeCalculator` caps a streaming text at the line holding it), so
/// the list grows a row a line at a time; the list re-plans the row when the count enters a new line.
@MainActor
final class MessageStreamPacer {
  nonisolated static let shared = MessageStreamPacer()

  nonisolated init() {}

  /// Slowest reveal, so a long gap never stalls visible text.
  static let minimumCharactersPerSecond: Double = 40
  /// How long after the last edit a message counts as finished.
  static let idleInterval: CFTimeInterval = 1.6
  /// How quickly the remaining text appears once edits stop.
  static let catchUpDuration: CFTimeInterval = 0.3

  private struct Stream {
    var revealed: Double
    var target: Int
    var lastArrival: CFTimeInterval
    /// Smoothed time between edits.
    var arrivalGap: CFTimeInterval
  }

  private struct Listener {
    weak var owner: AnyObject?
    var reveal: @MainActor (Int) -> Void
    var finish: @MainActor () -> Void
  }

  private var streams: [Int64: Stream] = [:]
  /// Every list showing the message hears it (a chat and its reply thread's parent row, two windows), by owner.
  private var listeners: [Int64: [ObjectIdentifier: Listener]] = [:]
  /// The revealed counts, readable from the size calculator wherever it runs.
  private let revealed = Mutex<[Int64: Int]>([:])
  private var displayLink: CADisplayLink?
  /// The view the running link came from (nil for a screen's link).
  private weak var linkView: NSView?
  private var lastTick: CFTimeInterval = 0

  /// Diagnostics (harness): 0 no link, 1 a link on a view in a window or a screen's, 2 a link whose view left.
  var linkState: Int {
    guard displayLink != nil else { return 0 }
    return linkFromScreen || linkView?.window != nil ? 1 : 2
  }

  private var linkFromScreen = false
  /// The view whose display paces the reveal (a list showing a stream), so it ticks at that display's rate. A link
  /// from a view stops when the view leaves its window, so a running link moves to each new list that shows a stream:
  /// kept on the first one, a chat switch mid-stream froze every later stream at its first chunk (harness,
  /// 2026-11-27: a rich stream after a plain one stayed at its first word for good).
  weak var displayView: NSView? {
    didSet {
      guard displayView !== oldValue, displayLink != nil else { return }
      stopTicking()
      startTicking()
    }
  }

  /// Characters to show for `messageID`, or nil when it isn't streaming.
  nonisolated func revealedLength(for messageID: Int64) -> Int? {
    revealed.withLock { $0[messageID] }
  }

  nonisolated func isStreaming(_ messageID: Int64) -> Bool {
    revealedLength(for: messageID) != nil
  }

  /// A new version of a message arrived. An append that extends the shown text starts or feeds a stream; any other
  /// edit ends one (its listener hears the finish, so the row shows the whole text).
  func messageChanged(_ messageID: Int64, from oldText: String?, to newText: String?) {
    // Reactions, status and re-plans leave the text as it was; the stream goes on.
    guard oldText != newText else { return }
    let now = CACurrentMediaTime()
    guard let oldText, let newText, newText.count > oldText.count, newText.hasPrefix(oldText) else {
      end(messageID)
      return
    }
    let newLength = (newText as NSString).length
    if var stream = streams[messageID] {
      // A second list showing the message reports the same edit: not a new arrival.
      guard newLength > stream.target else { return }
      let gap = now - stream.lastArrival
      stream.arrivalGap = stream.arrivalGap * 0.6 + min(gap, 2) * 0.4
      stream.lastArrival = now
      stream.target = newLength
      streams[messageID] = stream
    } else {
      // The first append reveals from what was already on screen.
      let start = (oldText as NSString).length
      streams[messageID] = Stream(revealed: Double(start), target: newLength, lastArrival: now, arrivalGap: 0.25)
      revealed.withLock { $0[messageID] = start }
    }
    startTicking()
  }

  /// `owner` (a list showing the message) hears each frame's count and the stream's end, while it lives. Each list
  /// showing the message is a listener: with one a message, a reply thread's parent row or a second window took it
  /// from the chat's row, and both stayed at the revealed prefix.
  func attach(
    _ messageID: Int64, owner: AnyObject, reveal: @escaping @MainActor (Int) -> Void,
    finish: @escaping @MainActor () -> Void
  ) {
    listeners[messageID, default: [:]][ObjectIdentifier(owner)] = Listener(owner: owner, reveal: reveal, finish: finish)
  }

  /// A list going away (`view`, the list's own view, so the reveal stops ticking on a view leaving its window). Streams
  /// no other live list shows end now, silently (a list showing the message later shows it whole, and its next append
  /// starts a new stream), so no stream outlives the lists that tick and finish it: left running, a stream whose list
  /// left kept its revealed count, and a list opening the chat later drew that prefix.
  func detach(owner: AnyObject, view: NSView?) {
    let key = ObjectIdentifier(owner)
    for id in Array(listeners.keys) {
      listeners[id]?[key] = nil
      listeners[id] = listeners[id]?.filter { $0.value.owner != nil }
      if listeners[id]?.isEmpty == true { listeners[id] = nil }
    }
    for id in Array(streams.keys) where listeners[id] == nil {
      streams[id] = nil
      revealed.withLock { $0[id] = nil }
    }
    if let view, displayView === view { displayView = nil }
    if streams.isEmpty { stopTicking() }
  }

  private func end(_ messageID: Int64) {
    guard streams.removeValue(forKey: messageID) != nil else { return }
    revealed.withLock { $0[messageID] = nil }
    let heard = listeners.removeValue(forKey: messageID)?.values.filter { $0.owner != nil } ?? []
    for listener in heard { listener.finish() }
  }

  // MARK: - Ticking

  private func startTicking() {
    guard displayLink == nil else { return }
    let target = DisplayLinkTarget(self)
    let selector = #selector(DisplayLinkTarget.tick(_:))
    let view = displayView
    guard let link = view?.displayLink(target: target, selector: selector)
      ?? (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: target, selector: selector)
    else { return }
    link.add(to: .main, forMode: .common)
    displayLink = link
    linkView = view
    linkFromScreen = view == nil
    lastTick = CACurrentMediaTime()
  }

  private func stopTicking() {
    displayLink?.invalidate()
    displayLink = nil
  }

  fileprivate func tick(_ link: CADisplayLink) {
    let now = link.timestamp
    let elapsed = min(max(now - lastTick, 0), 0.1)
    lastTick = now
    var finished: [Int64] = []
    // By id, reading each stream afresh: a listener's reveal can attach, detach or end streams.
    for id in Array(streams.keys) {
      guard var stream = streams[id] else { continue }
      let remaining = Double(stream.target) - stream.revealed
      let idle = now - stream.lastArrival
      if remaining > 0 {
        // Spread what's left over the expected wait for the next edit, or catch up once idle.
        let window = idle > stream.arrivalGap * 1.5 ? Self.catchUpDuration : max(0.12, stream.arrivalGap)
        let speed = max(Self.minimumCharactersPerSecond, remaining / window)
        stream.revealed = min(Double(stream.target), stream.revealed + speed * elapsed)
        streams[id] = stream
        let count = Int(stream.revealed)
        revealed.withLock { $0[id] = count }
      }
      if stream.revealed >= Double(stream.target), idle >= Self.idleInterval {
        finished.append(id)
      } else if let heard = listeners[id]?.values.filter({ $0.owner != nil }) {
        for listener in heard { listener.reveal(Int(stream.revealed)) }
      }
    }
    for id in finished { end(id) }
    for id in Array(listeners.keys) {
      let live = listeners[id]?.filter { $0.value.owner != nil } ?? [:]
      listeners[id] = live.isEmpty ? nil : live
    }
    if streams.isEmpty { stopTicking() }
  }
}

/// Keeps the display link from retaining the pacer.
private final class DisplayLinkTarget: NSObject {
  weak var pacer: MessageStreamPacer?

  init(_ pacer: MessageStreamPacer) {
    self.pacer = pacer
    super.init()
  }

  @MainActor @objc func tick(_ link: CADisplayLink) {
    pacer?.tick(link)
  }
}
