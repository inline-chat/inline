import Foundation
import Logger

@MainActor
public final class ChatOpenRenderTrace {
  public enum Kind: String, Sendable {
    case route
    case preview
  }

  enum InitialWindowSource: String, Sendable {
    case database
    case preparedPayload
  }

  enum ActivationOutcome: String, Equatable, Sendable {
    case reusedInitialWindow
    case reloadedChangedWindow
  }

  enum Milestone: Equatable, Sendable {
    case initialWindow
    case cachedSnapshot
    case firstUIApply
    case activation(ActivationOutcome)
    case translationStarted
    case translationFinished
    case cancelled
  }

  struct State: Equatable, Sendable {
    private(set) var didRecordInitialWindow = false
    private(set) var didBuildCachedSnapshot = false
    private(set) var didApplyFirstSnapshot = false
    private(set) var activationOutcomes: [ActivationOutcome] = []
    private(set) var didStartTranslation = false
    private(set) var didFinishTranslation = false
    private(set) var wasCancelled = false

    @discardableResult
    mutating func record(_ milestone: Milestone) -> Bool {
      switch milestone {
      case .initialWindow:
        guard !didRecordInitialWindow, !wasCancelled else { return false }
        didRecordInitialWindow = true
      case .cachedSnapshot:
        guard didRecordInitialWindow, !didBuildCachedSnapshot, !wasCancelled else { return false }
        didBuildCachedSnapshot = true
      case .firstUIApply:
        guard didRecordInitialWindow,
              didBuildCachedSnapshot,
              !didApplyFirstSnapshot,
              !wasCancelled
        else { return false }
        didApplyFirstSnapshot = true
      case let .activation(outcome):
        guard !wasCancelled else { return false }
        activationOutcomes.append(outcome)
      case .translationStarted:
        guard !didStartTranslation, !wasCancelled else { return false }
        didStartTranslation = true
      case .translationFinished:
        guard didStartTranslation, !didFinishTranslation, !wasCancelled else { return false }
        didFinishTranslation = true
      case .cancelled:
        guard !didApplyFirstSnapshot, !wasCancelled else { return false }
        wasCancelled = true
      }
      return true
    }
  }

  private(set) var state = State()

  private let traceID = UUID().uuidString
  private let kind: Kind
  private let startedAt = Date()
  private var firstSnapshotSpan: PerformanceTrace.Span?

  public init(kind: Kind) {
    self.kind = kind
    firstSnapshotSpan = PerformanceTrace.begin(
      "IOSChatOpenFirstSnapshot",
      category: .messages,
      "trace_id=\(traceID) kind=\(kind.rawValue)"
    )
  }

  func recordInitialWindow(
    source: InitialWindowSource,
    messageCount: Int,
    succeeded: Bool
  ) {
    guard state.record(.initialWindow) else { return }
    let result = succeeded ? "loaded" : "failed"
    PerformanceTrace.event(
      "IOSChatOpenInitialWindow",
      category: .messages,
      "trace_id=\(traceID) kind=\(kind.rawValue) source=\(source.rawValue) result=\(result) messages=\(messageCount)"
    )
  }

  public func recordCachedSnapshot(sectionCount: Int, itemCount: Int) {
    guard state.record(.cachedSnapshot) else { return }
    PerformanceTrace.event(
      "IOSChatOpenCachedSnapshot",
      category: .messages,
      "trace_id=\(traceID) sections=\(sectionCount) items=\(itemCount)"
    )
  }

  public func recordFirstUIApply() {
    guard state.record(.firstUIApply) else { return }
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
    PerformanceTrace.event(
      "IOSChatOpenFirstUIApply",
      category: .messages,
      "trace_id=\(traceID) duration_ms=\(durationMs)"
    )
    firstSnapshotSpan?.end("trace_id=\(traceID) result=applied duration_ms=\(durationMs)")
    firstSnapshotSpan = nil
  }

  func recordActivation(_ outcome: ActivationOutcome) {
    guard state.record(.activation(outcome)) else { return }
    PerformanceTrace.event(
      "IOSChatOpenActivation",
      category: .messages,
      "trace_id=\(traceID) outcome=\(outcome.rawValue)"
    )
  }

  @discardableResult
  public func recordTranslationStarted(messageCount: Int) -> Bool {
    guard state.record(.translationStarted) else { return false }
    PerformanceTrace.event(
      "IOSChatOpenTranslationFollowUp",
      category: .messages,
      "trace_id=\(traceID) stage=started messages=\(messageCount)"
    )
    return true
  }

  public func recordTranslationFinished(messageCount: Int) {
    guard state.record(.translationFinished) else { return }
    PerformanceTrace.event(
      "IOSChatOpenTranslationFollowUp",
      category: .messages,
      "trace_id=\(traceID) stage=finished messages=\(messageCount)"
    )
  }

  public func cancel() {
    guard state.record(.cancelled) else { return }
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
    firstSnapshotSpan?.end("trace_id=\(traceID) result=cancelled duration_ms=\(durationMs)")
    firstSnapshotSpan = nil
  }
}
