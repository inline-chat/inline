import Foundation
import InlineKit
import Logger
import QuartzCore

/// One chat open, from the router being asked for it to the first frame the message list drew: the
/// `ChatOpen` signpost (category `MessageList`), ending with how long the window read took, the push and
/// building the chat up to the list's opening layout, and the frame that drew it. `HomeChatOpen` ends when the chat view appears, before its list is laid
/// out; this one ends where the reader sees messages. Slow opens leave a breadcrumb.
@MainActor
enum ChatOpenTrace {
  private struct Open {
    let peer: Peer
    let span: PerformanceTrace.Span
    let startedAt: CFTimeInterval
    var preparedAt: CFTimeInterval?
    var list: String?
  }

  private static var open: Open?

  /// The router was asked to show the chat (a row released, a link followed).
  static func begin(peer: Peer) {
    open?.span.end("result=replaced")
    open = Open(peer: peer, span: PerformanceTrace.begin("ChatOpen", category: .messages), startedAt: CACurrentMediaTime())
  }

  /// The chat's first window was read; the push is applied right after.
  static func prepared(peer: Peer) {
    guard open?.peer == peer, open?.preparedAt == nil else { return }
    open?.preparedAt = CACurrentMediaTime()
  }

  /// The message list placed its opening rows. The open ends with the frame that draws them: the commit
  /// at the end of this run loop pass, so the next one.
  static func listOpened(peer: Peer, list: String) {
    guard open?.peer == peer, open?.list == nil, let started = open?.startedAt else { return }
    // An open that never reached a list (superseded, or the chat was already showing) is not finished by
    // a later list of the same chat.
    guard CACurrentMediaTime() - started < 5 else {
      open?.span.end("result=stale")
      open = nil
      return
    }
    open?.list = list
    let laidOutAt = CACurrentMediaTime()
    DispatchQueue.main.async {
      guard let finished = open, finished.peer == peer, finished.list == list else { return }
      open = nil
      let end = CACurrentMediaTime()
      func ms(_ a: CFTimeInterval?, _ b: CFTimeInterval?) -> Int {
        guard let a, let b else { return -1 }
        return Int(((b - a) * 1000).rounded())
      }
      let total = ms(finished.startedAt, end)
      #if DEBUG
      NSLog("TIMELINE_DEBUG chat-open list=%@ read_ms=%d build_ms=%d frame_ms=%d duration_ms=%d", list,
            ms(finished.startedAt, finished.preparedAt), ms(finished.preparedAt ?? finished.startedAt, laidOutAt),
            ms(laidOutAt, end), total)
      #endif
      finished.span.end(
        "list=\(list) read_ms=\(ms(finished.startedAt, finished.preparedAt)) build_ms=\(ms(finished.preparedAt ?? finished.startedAt, laidOutAt)) frame_ms=\(ms(laidOutAt, end)) duration_ms=\(total)"
      )
      PerformanceTrace.slowBreadcrumb(
        "iOS chat open was slow",
        category: "messages.ios",
        durationMs: total,
        thresholdMs: 400,
        data: [
          "list": list,
          "read_ms": ms(finished.startedAt, finished.preparedAt),
          "build_ms": ms(finished.preparedAt ?? finished.startedAt, laidOutAt),
        ]
      )
    }
  }
}
