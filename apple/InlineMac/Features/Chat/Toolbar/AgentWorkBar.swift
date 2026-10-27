import Auth
import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI

/// Presentation of one agent's run state, shared by the work bar and the
/// sidebar badge.
struct AgentWorkPresentation: Equatable {
  enum Tone: Equatable {
    case active
    case attention
    case quiet
    case problem
  }

  let title: String
  let symbolName: String
  let tone: Tone
  let isAnimated: Bool

  init(_ state: AgentWorkState, viewerUserID: Int64?) {
    switch state.runState {
    case .working:
      title = String(localized: "Working")
      symbolName = "circle.dotted"
      tone = .active
      isAnimated = true
    case let .waiting(kind):
      let forViewer = state.isWaiting(for: viewerUserID)
      title = switch kind {
      case .approval?: forViewer ? String(localized: "Needs your approval") : String(localized: "Waiting for approval")
      case .question?: forViewer ? String(localized: "Has a question") : String(localized: "Waiting for an answer")
      case .limit?: state.detail ?? String(localized: "Usage limit reached")
      case .setup?: state.detail ?? String(localized: "Needs setup")
      case .dialog?, nil: forViewer ? String(localized: "Waiting for you") : String(localized: "Waiting")
      }
      symbolName = kind == .limit || kind == .setup ? "exclamationmark.triangle.fill" : "hand.raised.fill"
      tone = forViewer || kind == .limit || kind == .setup ? .attention : .quiet
      isAnimated = false
    case .stopping:
      title = String(localized: "Stopping…")
      symbolName = "stop.circle"
      tone = .quiet
      isAnimated = false
    case .paused:
      title = String(localized: "Paused")
      symbolName = "pause.circle.fill"
      tone = .quiet
      isAnimated = false
    case let .heldElsewhere(label):
      title = label.map { String(localized: "Active in \($0)") } ?? String(localized: "Active elsewhere")
      symbolName = "macwindow.on.rectangle"
      tone = .quiet
      isAnimated = false
    case .releasing:
      title = String(localized: "Releasing…")
      symbolName = "arrow.uturn.right.circle"
      tone = .quiet
      isAnimated = true
    case .released:
      title = String(localized: "Released to terminal or app")
      symbolName = "arrow.uturn.right.circle.fill"
      tone = .quiet
      isAnimated = false
    case .offline:
      title = String(localized: "Offline")
      symbolName = "bolt.horizontal.circle"
      tone = .problem
      isAnimated = false
    case .idle:
      title = String(localized: "Idle")
      symbolName = "circle"
      tone = .quiet
      isAnimated = false
    case .unknown:
      title = String(localized: "Unknown")
      symbolName = "questionmark.circle"
      tone = .quiet
      isAnimated = false
    }
  }

  var color: Color {
    switch tone {
    case .active: .accentColor
    case .attention: .orange
    case .quiet: .secondary
    case .problem: .red
    }
  }
}

/// The agent work bar (spec §6) for a chat: one chip per agent with work in
/// it — run state, elapsed time and queue count — with stop and pause or
/// resume. It renders the cached state on its first frame.
struct AgentWorkBar: View {
  let peer: InlineKit.Peer
  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared

  var body: some View {
    let states = store.states(peer: peer).filter { $0.runState != .idle }
    if !states.isEmpty {
      HStack(spacing: 6) {
        ForEach(states) { state in
          AgentWorkChip(state: state, access: grants.access(botUserID: state.key.botUserID))
        }
      }
      .task(id: peer.toString()) {
        for state in states { grants.ensureLoaded(botUserID: state.key.botUserID) }
      }
    }
  }
}

private struct AgentWorkChip: View {
  let state: AgentWorkState
  let access: AgentGrantAccess?
  @State private var isShowingDetails = false
  @State private var pendingControl: InlineProtocol.AgentSessionControl?

  private var presentation: AgentWorkPresentation {
    AgentWorkPresentation(state, viewerUserID: Auth.shared.getCurrentUserId())
  }

  private var botName: String {
    ObjectCache.shared.getCachedUser(id: state.key.botUserID)?.user.firstName ?? String(localized: "Agent")
  }

  /// Nil when the viewer may steer; grants not loaded yet render enabled and
  /// the server decides.
  private var steerDisabledReason: String? {
    MessageActionPresentation.disabledReason(
      requirement: .steer,
      access: access,
      ownerName: access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user.firstName },
      botName: botName
    )
  }

  var body: some View {
    HStack(spacing: 2) {
      Button {
        isShowingDetails.toggle()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: presentation.symbolName)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: presentation.isAnimated)
            .foregroundStyle(presentation.color)
            .font(.system(size: 11, weight: .semibold))
          Text(presentation.title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
          if state.runState == .working, let startedAt = state.startedAt {
            Text(startedAt, style: .timer)
              .font(.system(size: 11).monospacedDigit())
              .foregroundStyle(.secondary)
          }
          if state.queueCount > 0 {
            Text("· \(state.queueCount) queued")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.leading, 8)
        .padding(.trailing, canControl ? 2 : 8)
        .frame(height: 22)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("\(botName): \(presentation.title)")
      .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
        details
      }

      if state.runState.isActive {
        controlButton(.stop, symbol: "stop.fill", help: String(localized: "Stop \(botName)"))
      }
    }
    .background(Capsule().fill(.quaternary.opacity(0.6)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(botName): \(presentation.title)")
  }

  private var canControl: Bool { state.runState.isActive }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        if let user = ObjectCache.shared.getCachedUser(id: state.key.botUserID) {
          UserAvatar(userInfo: user, size: 20)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(botName).font(.headline)
          Text(presentation.title).font(.caption).foregroundStyle(presentation.color)
        }
      }
      if let detail = state.detail, state.runState != .working {
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      if state.queueCount > 0 {
        Label("\(state.queueCount) messages queued", systemImage: "tray.full")
          .font(.callout)
      }
      HStack(spacing: 8) {
        if state.runState.isActive {
          controlButton(.stop, title: String(localized: "Stop"))
          controlButton(.pause, title: String(localized: "Pause"))
        } else if state.runState == .paused {
          controlButton(.resume, title: String(localized: "Resume"))
        }
      }
      if let steerDisabledReason {
        Label(steerDisabledReason, systemImage: "lock")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(14)
    .frame(width: 260, alignment: .leading)
  }

  @ViewBuilder
  private func controlButton(
    _ op: InlineProtocol.AgentSessionControl,
    symbol: String? = nil,
    title: String? = nil,
    help: String? = nil
  ) -> some View {
    let button = Button {
      perform(op)
    } label: {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 9, weight: .bold))
          .frame(width: 20, height: 20)
          .contentShape(Circle())
      } else if let title {
        Text(title)
      }
    }
    .disabled(steerDisabledReason != nil || pendingControl != nil)
    .help(steerDisabledReason ?? help ?? title ?? "")
    if symbol != nil {
      button.buttonStyle(.plain).foregroundStyle(.secondary)
    } else {
      button.controlSize(.small)
    }
  }

  private func perform(_ op: InlineProtocol.AgentSessionControl) {
    guard pendingControl == nil else { return }
    pendingControl = op
    Task { @MainActor in
      defer { pendingControl = nil }
      do {
        _ = try await Api.realtime.callRpcDirect(
          method: .controlAgentSession,
          input: .controlAgentSession(.with {
            $0.agentSessionID = state.sessionID
            $0.op = op
          })
        )
      } catch {
        ToastCenter.shared.showError(error.localizedDescription)
      }
    }
  }
}
