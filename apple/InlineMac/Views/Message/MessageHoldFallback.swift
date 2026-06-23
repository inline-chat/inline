import AppKit

final class MessageHoldFallback {
  private enum Hold {
    static let duration: TimeInterval = 0.5
    static let movement: CGFloat = 10
  }

  private weak var view: NSView?
  private let name: String
  private var timer: Timer?
  private var monitor: Any?
  private var startPoint: NSPoint?
  private var action: ((NSPoint) -> Void)?
  private var fired = false

  init(view: NSView, name: String) {
    self.view = view
    self.name = name
  }

  deinit {
    cancel(reason: "deinit")
  }

  func start(at point: NSPoint, event: NSEvent, action: @escaping (NSPoint) -> Void) {
    guard event.type == .leftMouseDown, event.clickCount == 1 else { return }

    cancel(reason: "restart")

    startPoint = point
    self.action = action
    fired = false

    let timer = Timer(timeInterval: Hold.duration, repeats: false) { [weak self] _ in
      self?.fire()
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .eventTracking)
    RunLoop.main.add(timer, forMode: .default)

    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
      self?.handle(event)
      return event
    }

    MessageGestureTrace.debug("\(name).holdFallback action=start point=\(MessageGestureTrace.point(point)) eventNumber=\(event.eventNumber)")
  }

  func cancel(reason: String) {
    if timer != nil || monitor != nil || startPoint != nil {
      MessageGestureTrace.debug("\(name).holdFallback action=cancel reason=\(reason)")
    }

    timer?.invalidate()
    timer = nil

    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    startPoint = nil
    action = nil
    fired = false
  }

  private func handle(_ event: NSEvent) {
    guard let view, let startPoint else { return }

    switch event.type {
    case .leftMouseDragged:
      guard !fired else { return }
      let point = view.convert(event.locationInWindow, from: nil)
      if hypot(point.x - startPoint.x, point.y - startPoint.y) > Hold.movement {
        cancel(reason: "movement")
      }
    case .leftMouseUp:
      cancel(reason: "mouseUp")
    default:
      break
    }
  }

  private func fire() {
    timer?.invalidate()
    timer = nil

    guard let startPoint, !fired else { return }
    fired = true

    MessageGestureTrace.debug("\(name).holdFallback action=fire point=\(MessageGestureTrace.point(startPoint))")
    action?(startPoint)
  }
}
