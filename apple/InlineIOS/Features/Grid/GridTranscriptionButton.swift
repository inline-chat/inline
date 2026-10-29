import InlineGrid
import InlineKit
import InlineProtocol
import SwiftUI

/// Transcription on iPhone, as on the Mac: one dock toggle beside the
/// microphone. A tap starts a new transcript thread or stops the run; a long
/// press opens the transcript. The server reports transcription unavailable
/// outside Pro Spaces, so the toggle stays hidden there.
struct GridTranscriptionButton: View {
  let store: GridRoomService
  let room: GridRoom

  @Environment(Router.self) private var router

  private static let diameter: CGFloat = 52

  var body: some View {
    Button(action: toggle) { icon }
      .buttonStyle(.plain)
      .disabled(!canToggle)
      .contextMenu {
        if let chatID = room.transcriptChatID {
          Button("Open Transcript", systemImage: "doc.text") {
            router.push(.chat(peer: .thread(id: chatID)))
          }
        }
      }
      .accessibilityLabel(room.transcriptionControlTitle)
      .animation(.easeOut(duration: 0.15), value: state)
  }

  private var state: GridTranscriptionState? {
    room.hasTranscription ? room.transcription.state : nil
  }

  @ViewBuilder
  private var icon: some View {
    switch state {
      case .gridTranscriptionStarting?, .gridTranscriptionStopping?:
        ProgressView()
          .tint(Color.accentColor)
          .frame(width: Self.diameter, height: Self.diameter)
          .glassCircle()
      case .gridTranscriptionActive?:
        symbol("captions.bubble.fill")
          .foregroundStyle(Color.white)
          .background(Color.accentColor, in: Circle())
      case .gridTranscriptionInterrupted?:
        symbol("captions.bubble")
          .foregroundStyle(Color.primary)
          .glassCircle()
          .overlay(alignment: .topTrailing) {
            Circle()
              .fill(.orange)
              .frame(width: 9, height: 9)
              .padding(9)
          }
      default:
        symbol("captions.bubble")
          .foregroundStyle(Color.primary)
          .glassCircle()
    }
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name)
      .font(.title3.weight(.medium))
      .frame(width: Self.diameter, height: Self.diameter)
      .contentShape(Circle())
  }

  private var ownsMembership: Bool {
    room.avatars.contains { $0.ownedByCurrentSession && !$0.membershipID.isEmpty }
  }

  private var canToggle: Bool {
    guard store.pendingTranscriptionRequestIDs[room.id] == nil, ownsMembership,
          room.hasConnection, room.connection.generation > 0
    else { return false }
    return room.canStopTranscription || room.canStartTranscription
  }

  /// A start always opens a new thread, so each run reads as its own transcript.
  private func toggle() {
    let enabled = !room.canStopTranscription
    Task {
      do {
        try await store.setTranscription(room: room, enabled: enabled, destination: .new)
      } catch {
        let message = enabled
          ? String(localized: "Transcription couldn’t start")
          : String(localized: "Transcription couldn’t stop")
        ToastManager.shared.showToast(message, type: .error)
      }
    }
  }
}

/// While the room you're in is transcribed, Grid's title says so, as the
/// floating call pill does on the Mac.
struct GridTranscriptionSubtitle: ViewModifier {
  let store: GridRoomService

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *), let room = store.activeTranscriptionRoom {
      let title = room.hasTitle && !room.title.isEmpty ? room.title : String(localized: "Room")
      content.navigationSubtitle(String(localized: "Transcribing · \(title)"))
    } else {
      content
    }
  }
}

private extension View {
  @ViewBuilder
  func glassCircle() -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: Circle())
    } else {
      background(.regularMaterial, in: Circle())
    }
  }
}
