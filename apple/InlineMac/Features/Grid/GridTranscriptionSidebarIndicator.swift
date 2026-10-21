import InlineKit
import InlineProtocol
import SwiftUI

/// Persistent one-row disclosure in the sidebar footer, including while the
/// participant reads another chat. Click opens the transcript; the trailing
/// button stops capture. It projects the shared room snapshot.
struct GridTranscriptionSidebarIndicator: View {
  let room: GridRoom
  let isBusy: Bool
  let onOpenGrid: () -> Void
  let onOpenTranscript: () -> Void
  let onStop: () async throws -> Void

  @Environment(\.appearsActive) private var appearsActive

  private static let cornerRadius: CGFloat = 13

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

    HStack(spacing: 8) {
      Button(action: room.transcriptChatID == nil ? onOpenGrid : onOpenTranscript) {
        HStack(spacing: 8) {
          statusIcon
          Text(statusTitle)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .help(room.transcriptChatID == nil ? "Return to Grid" : "Open transcript")

      Button {
        Task {
          do { try await onStop() }
          catch { ToastCenter.shared.showError("Couldn’t stop transcription. Try again.") }
        }
      } label: {
        Image(systemName: "stop.fill")
          .font(.system(size: 9, weight: .semibold))
          .frame(width: 20, height: 20)
          .background(Color.primary.opacity(0.08), in: Circle())
          .contentShape(Circle())
      }
      .disabled(isBusy || !room.canStopTranscription)
      .help(room.transcriptionControlTitle)
      .accessibilityLabel(room.transcriptionControlTitle)
    }
    .buttonStyle(.plain)
    .font(.system(size: 12, weight: .medium))
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(background(shape: shape))
    .overlay(shape.stroke(Color.primary.opacity(appearsActive ? 0.12 : 0.07), lineWidth: 0.7))
  }

  @ViewBuilder
  private var statusIcon: some View {
    if room.transcription.state == .gridTranscriptionActive {
      Image(systemName: "captions.bubble.fill")
        .foregroundStyle(Color(nsColor: Theme.accentColor))
    } else {
      GridScreenShareActivityIndicator(tint: Color(nsColor: Theme.accentColor), size: 11)
        .frame(width: 15)
    }
  }

  private var statusTitle: String {
    switch room.transcription.state {
      case .gridTranscriptionStarting: "Starting transcription…"
      case .gridTranscriptionStopping: "Stopping transcription…"
      default: "Transcribing"
    }
  }

  @ViewBuilder
  private func background(shape: RoundedRectangle) -> some View {
    if #available(macOS 26.0, *) {
      shape
        .fill(.clear)
        .glassEffect(.regular.interactive(), in: shape)
    } else {
      shape.fill(.ultraThinMaterial)
    }
  }
}
