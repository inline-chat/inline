import InlineKit
import QuartzCore
import UIKit

/// Paces the reveal of messages that stream by appending to their text.
///
/// Bots stream by editing a message with ever-longer snapshots. Each append becomes the new
/// target, and a display link advances the revealed character count toward it at a speed
/// estimated from the gaps between edits, so text flows at the rate it arrives instead of
/// jumping a chunk per edit. When edits go idle, the pacer catches up quickly and the message
/// finishes: its time appears.
@MainActor
final class MessageStreamPacer {
  static let shared = MessageStreamPacer()

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

  private var streams: [Int64: Stream] = [:]
  private var views: [Int64: WeakView] = [:]
  private var displayLink: CADisplayLink?
  private var lastTick: CFTimeInterval = 0

  private struct WeakView {
    weak var view: MessageView?
  }

  /// Characters to show for `messageID`, or nil when it isn't streaming.
  func revealedLength(for messageID: Int64) -> Int? {
    streams[messageID].map { Int($0.revealed) }
  }

  func isStreaming(_ messageID: Int64) -> Bool {
    streams[messageID] != nil
  }

  /// A new version of a message arrived. An append that extends the shown text starts or feeds
  /// a stream; any other edit ends one.
  func messageChanged(_ messageID: Int64, from oldText: String?, to newText: String?) {
    // Reactions, status and replans leave the text as it was; the stream goes on.
    guard oldText != newText else { return }
    let now = CACurrentMediaTime()
    guard let oldText, let newText, newText.count > oldText.count, newText.hasPrefix(oldText) else {
      streams[messageID] = nil
      return
    }
    let newLength = (newText as NSString).length
    if var stream = streams[messageID] {
      let gap = now - stream.lastArrival
      stream.arrivalGap = stream.arrivalGap * 0.6 + min(gap, 2) * 0.4
      stream.lastArrival = now
      stream.target = newLength
      streams[messageID] = stream
    } else {
      // The first append reveals from what was already on screen.
      streams[messageID] = Stream(
        revealed: Double((oldText as NSString).length),
        target: newLength,
        lastArrival: now,
        arrivalGap: 0.25
      )
    }
    startTicking()
  }

  /// The view showing `messageID` gets each frame's reveal.
  func attach(_ view: MessageView, to messageID: Int64) {
    views[messageID] = WeakView(view: view)
  }

  // MARK: - Ticking

  private func startTicking() {
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
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
    for (id, var stream) in streams {
      let remaining = Double(stream.target) - stream.revealed
      let idle = now - stream.lastArrival
      if remaining > 0 {
        // Spread what's left over the expected wait for the next edit, or catch up once idle.
        let window = idle > stream.arrivalGap * 1.5 ? Self.catchUpDuration : max(0.12, stream.arrivalGap)
        let speed = max(Self.minimumCharactersPerSecond, remaining / window)
        stream.revealed = min(Double(stream.target), stream.revealed + speed * elapsed)
        streams[id] = stream
      }
      // A reused cell may show another message by now.
      let view = views[id]?.view.flatMap { $0.content?.message.id == id ? $0 : nil }
      if stream.revealed >= Double(stream.target), idle >= Self.idleInterval {
        finished.append(id)
      } else {
        view?.reveal(Int(stream.revealed))
      }
    }
    for id in finished {
      streams[id] = nil
      if let view = views[id]?.view, view.content?.message.id == id {
        view.finishStreaming()
      }
      views[id] = nil
    }
    if streams.isEmpty {
      stopTicking()
    }
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
