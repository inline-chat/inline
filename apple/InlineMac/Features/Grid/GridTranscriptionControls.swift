import InlineKit
import InlineProtocol
import SwiftUI

/// Transcription as one split control in the Grid media pill: the icon (or
/// ⌥T) starts or stops capture, and the chevron holds the less frequent
/// actions. Each start opens a new transcript thread; continuing an earlier one
/// is explicit. Room snapshots own capture state; this view only presents it.
/// Place it with `.id(room.id)` so the earlier-transcript list never outlives
/// its room.
struct GridTranscriptionControl: View {
  let room: GridRoom
  let isBusy: Bool
  let onSetTranscription: (Bool, GridTranscriptionRequest.Destination) -> Void
  let onOpenTranscript: () -> Void
  let onListTranscripts: () async throws -> [GridTranscriptDestinationInfo]

  @State private var earlierTranscripts: EarlierTranscripts = .loading
  @State private var earlierTranscriptsAttempt = 0

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      controls
        .glassEffect(.regular.interactive(), in: Capsule())
    } else {
      controls
        .background(.ultraThinMaterial, in: Capsule())
    }
  }

  private var controls: some View {
    HStack(spacing: 0) {
      Button(action: toggle) {
        icon
      }
      .buttonStyle(.plain)
      .disabled(!canToggle)
      .keyboardShortcut("t", modifiers: .option)
      .help("\(toggleHelp) (⌥T)")
      .accessibilityLabel(toggleHelp)

      Rectangle()
        .fill(Color.primary.opacity(0.1))
        .frame(width: 1, height: 17)

      Menu {
        menuContent
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 23, height: 34)
          .contentShape(Rectangle())
      }
      // A plain button-style menu keeps the label's own size and tint, matching
      // the other chevrons in the pill.
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Transcript options")
      .accessibilityLabel("Transcript options")
    }
    .fixedSize()
    .task(id: earlierTranscriptsKey) { await loadEarlierTranscripts() }
  }

  @ViewBuilder
  private var icon: some View {
    switch room.hasTranscription ? room.transcription.state : nil {
      case .gridTranscriptionStarting?, .gridTranscriptionStopping?:
        GridScreenShareActivityIndicator(tint: accent)
          .frame(width: 34, height: 34)
          .contentShape(Rectangle())
      case .gridTranscriptionActive?:
        GridTintedControlIcon(systemName: "captions.bubble.fill", isActive: true, tint: accent)
      case .gridTranscriptionInterrupted?:
        GridTintedControlIcon(systemName: "captions.bubble", isActive: false)
          .overlay(alignment: .topTrailing) {
            Circle()
              .fill(.orange)
              .frame(width: 7, height: 7)
              .padding(7)
          }
      default:
        GridTintedControlIcon(systemName: "captions.bubble", isActive: false)
    }
  }

  @ViewBuilder
  private var menuContent: some View {
    Button("Open Transcript", systemImage: "doc.text", action: onOpenTranscript)
      .disabled(room.transcriptChatID == nil)
    Divider()
    Button(room.transcriptionControlTitle, systemImage: room.canStopTranscription ? "stop.fill" : "plus", action: toggle)
      .disabled(!canToggle)
    Menu {
      earlierTranscriptsMenuContent
    } label: {
      Label("Continue Earlier Transcript", systemImage: "clock.arrow.circlepath")
    }
    .disabled(!canStart)
  }

  @ViewBuilder
  private var earlierTranscriptsMenuContent: some View {
    switch earlierTranscripts {
      case .loading:
        Text("Loading…")
      case .failed:
        Text("Couldn’t Load Earlier Transcripts")
        Button("Try Again") { earlierTranscriptsAttempt += 1 }
      case let .loaded(transcripts):
        if transcripts.isEmpty {
          Text("No Earlier Transcripts")
        } else {
          Section("Everyone here gets that thread’s history") {
            ForEach(transcripts, id: \.transcriptChatID) { transcript in
              Button(transcript.busy ? "\(transcript.displayTitle) (In Use)" : transcript.displayTitle) {
                onSetTranscription(true, .existing(transcript.transcriptChatID))
              }
              .disabled(transcript.busy)
            }
          }
        }
    }
  }

  /// A start always opens a new thread, so each run reads as its own transcript.
  private func toggle() {
    onSetTranscription(!room.canStopTranscription, .new)
  }

  private var accent: Color {
    Color(nsColor: Theme.accentColor)
  }

  private var ownsMembership: Bool {
    room.avatars.contains { $0.ownedByCurrentSession && !$0.membershipID.isEmpty }
  }

  private var canControl: Bool {
    !isBusy && ownsMembership && room.hasConnection && room.connection.generation > 0 && room.transcriptionCanChange
  }

  private var canStart: Bool {
    canControl && room.canStartTranscription
  }

  private var canToggle: Bool {
    room.canStopTranscription ? canControl : canStart
  }

  private var toggleHelp: String {
    switch room.hasTranscription ? room.transcription.state : nil {
      case nil, .gridTranscriptionStopped?:
        return startHelp
      case .gridTranscriptionInterrupted?:
        return canStart ? "Transcription was interrupted. Start again" : "Transcription was interrupted"
      default:
        return room.transcriptionControlTitle
    }
  }

  private var startHelp: String {
    if room.transcriptionAvailable { return room.transcriptionControlTitle }
    return room.avatars.count < 2 ? "Transcription needs two people in the room" : "Transcription isn’t available right now"
  }

  /// A run that ends is what adds a transcript, so the list loads once per room
  /// and run. It skips while capture runs, when continuing isn't possible.
  private var earlierTranscriptsKey: EarlierTranscriptsKey {
    EarlierTranscriptsKey(
      roomID: room.id,
      runID: room.hasTranscription ? room.transcription.runID : "",
      isNeeded: !room.transcriptionIsRunning,
      attempt: earlierTranscriptsAttempt
    )
  }

  private func loadEarlierTranscripts() async {
    guard earlierTranscriptsKey.isNeeded else { return }
    earlierTranscripts = .loading
    do {
      let transcripts = try await onListTranscripts()
      guard !Task.isCancelled else { return }
      earlierTranscripts = .loaded(Array(transcripts.prefix(20)))
    } catch {
      guard !Task.isCancelled else { return }
      earlierTranscripts = .failed
    }
  }
}

private enum EarlierTranscripts {
  case loading
  case loaded([GridTranscriptDestinationInfo])
  case failed
}

private struct EarlierTranscriptsKey: Equatable {
  let roomID: Int64
  let runID: String
  let isNeeded: Bool
  let attempt: Int
}

private extension GridTranscriptDestinationInfo {
  var displayTitle: String {
    title.isEmpty ? "Transcript" : title
  }
}

/// A failed transcription request, shown in the media pill's notice row. It
/// keeps the intent rather than a room snapshot: requests fence on the run,
/// revision and generation, so a retry reads the room again when tapped.
struct GridTranscriptionNotice: Equatable {
  enum Retry: Equatable {
    case setTranscription(enabled: Bool, destination: GridTranscriptionRequest.Destination)
  }

  let retry: Retry
  /// The room and capture state the failure belongs to. Once the room moves
  /// on, the notice no longer describes it.
  let capture: GridTranscriptionCapture

  var roomID: Int64 {
    capture.roomID
  }

  var title: String {
    switch retry {
      case .setTranscription(enabled: true, destination: _): "Transcription couldn’t start"
      case .setTranscription(enabled: false, destination: _): "Transcription couldn’t stop"
    }
  }

  var actionTitle: String {
    "Try Again"
  }
}

/// The parts of a room that a transcription notice depends on.
struct GridTranscriptionCapture: Equatable {
  let roomID: Int64
  let runID: String
  let state: GridTranscriptionState

  init(room: GridRoom) {
    roomID = room.id
    runID = room.hasTranscription ? room.transcription.runID : ""
    state = room.hasTranscription ? room.transcription.state : .gridTranscriptionUnspecified
  }
}
