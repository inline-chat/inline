import InlineKit
import InlineProtocol
import SwiftUI

/// Persistent disclosure in the existing sidebar footer, including while the
/// participant reads another chat. It projects the shared room snapshot.
struct GridTranscriptionSidebarIndicator: View {
  let room: GridRoom
  let isBusy: Bool
  let onOpenGrid: () -> Void
  let onOpenTranscript: () -> Void
  let onStop: () async throws -> Void

  @State private var errorText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button(action: onOpenGrid) {
        Label(statusTitle, systemImage: "text.bubble")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.system(size: 12, weight: .medium))
      .help("Return to Grid")

      HStack(spacing: 10) {
        if room.transcriptChatID != nil {
          Button("Open transcript", action: onOpenTranscript)
        }
        Button(room.transcription.state == .gridTranscriptionStarting ? "Cancel" : "Stop") {
          errorText = nil
          Task {
            do { try await onStop() }
            catch { errorText = "Couldn’t confirm the stop. Check transcription and try again." }
          }
        }
        .disabled(isBusy || !room.canStopTranscription)
        .accessibilityLabel("Stop transcription")
      }
      .font(.system(size: 11))

      if let errorText {
        Text(errorText).font(.caption).foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var statusTitle: String {
    switch room.transcription.state {
      case .gridTranscriptionStarting: "Starting transcription…"
      case .gridTranscriptionStopping: "Stopping transcription…"
      default: "Transcribing"
    }
  }
}
