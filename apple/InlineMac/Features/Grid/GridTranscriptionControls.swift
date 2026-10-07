import InlineKit
import InlineProtocol
import SwiftUI

/// Room snapshots own capture state. View state is limited to an open picker
/// and presentation of a failed request.
struct GridTranscriptionControls: View {
  let room: GridRoom
  let isBusy: Bool
  let onSetTranscription: (Bool, GridTranscriptionRequest.Destination) async throws -> Void
  let onOpenRoomThread: () async throws -> Void
  let onOpenTranscript: () -> Void
  let onListTranscripts: () async throws -> [GridTranscriptDestinationInfo]

  @State private var showsPicker = false
  @State private var isOpeningRoomThread = false
  @State private var errorText: String?

  var body: some View {
    VStack(spacing: 6) {
      if let errorText {
        Text(errorText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if room.hasTranscription, room.transcription.state == .gridTranscriptionStarting {
        Text("Starting transcription…").font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if room.transcriptionAvailable || room.transcriptionIsRunning {
          Button {
            setTranscription(enabled: !room.transcriptionIsRunning, destination: .last)
          } label: {
            Label(
              room.transcriptionControlTitle,
              systemImage: room.transcriptionIsRunning ? "stop.circle" : "text.bubble"
            )
          }
          .disabled(isBusy || !canControl)
          .help(room.transcriptionControlTitle)
        }

        if room.hasTranscription, room.transcription.state == .gridTranscriptionActive {
          Circle().fill(.green).frame(width: 6, height: 6)
            .accessibilityLabel("Transcription is active")
        }

        if room.transcriptionAvailable {
          Menu {
            Button("Start a new transcript") {
              setTranscription(enabled: true, destination: .new)
            }
            Button("Continue earlier transcript…") { showsPicker = true }
          } label: {
            Label("Transcript options", systemImage: "ellipsis")
              .labelStyle(.iconOnly)
          }
          .menuIndicator(.hidden)
          .disabled(isBusy || !canControl || !room.canStartTranscription)
          .help("Transcript options")
          .popover(isPresented: $showsPicker) {
            GridTranscriptPicker(
              isBusy: isBusy,
              onLoad: onListTranscripts,
              onSelect: { chatID in
                try await onSetTranscription(true, .existing(chatID))
                showsPicker = false
              }
            )
            .id(room.id)
          }
        }

        Divider().frame(height: 16)

        if room.transcriptChatID != nil {
          Button("Open transcript", action: onOpenTranscript)
        }
        Button {
          isOpeningRoomThread = true
          errorText = nil
          Task {
            defer { isOpeningRoomThread = false }
            do { try await onOpenRoomThread() }
            catch { errorText = "Couldn’t open the room thread. Try again." }
          }
        } label: {
          Label("Room thread", systemImage: "bubble.left.and.bubble.right")
        }
        .disabled(isOpeningRoomThread || !ownsMembership)
      }
      .buttonStyle(.plain)
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(.regularMaterial, in: Capsule())

      if room.hasTranscription, room.transcription.state == .gridTranscriptionInterrupted {
        Text("Transcription was interrupted. Start again to continue.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onChange(of: room.id) {
      showsPicker = false
      errorText = nil
    }
  }

  private var ownsMembership: Bool {
    room.avatars.contains { $0.ownedByCurrentSession && !$0.membershipID.isEmpty }
  }

  private var canControl: Bool {
    ownsMembership && room.hasConnection && room.connection.generation > 0 && room.transcriptionCanChange
  }

  private func setTranscription(enabled: Bool, destination: GridTranscriptionRequest.Destination) {
    errorText = nil
    Task {
      do { try await onSetTranscription(enabled, destination) }
      catch { errorText = "Couldn’t confirm the change. Check transcription and try again." }
    }
  }
}

private struct GridTranscriptPicker: View {
  let isBusy: Bool
  let onLoad: () async throws -> [GridTranscriptDestinationInfo]
  let onSelect: (Int64) async throws -> Void

  @State private var transcripts: [GridTranscriptDestinationInfo] = []
  @State private var isLoading = true
  @State private var errorText: String?
  @State private var loadRevision = 0
  @State private var selectedChatID: Int64?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Continue earlier transcript").font(.headline)
      Text("Current and future participants get access to the earlier room’s full thread history.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if isLoading {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 18)
      } else if transcripts.isEmpty, errorText == nil {
        Text("No earlier transcripts are available to share.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(transcripts, id: \.transcriptChatID) { transcript in
              Button {
                selectedChatID = transcript.transcriptChatID
                errorText = nil
                Task {
                  defer { selectedChatID = nil }
                  do { try await onSelect(transcript.transcriptChatID) }
                  catch { errorText = "Couldn’t continue this transcript. Try again." }
                }
              } label: {
                HStack {
                  Text(transcript.title.isEmpty ? "Transcript" : transcript.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                  Spacer(minLength: 8)
                  if transcript.busy {
                    Text("In use").font(.caption).foregroundStyle(.secondary)
                  } else if selectedChatID == transcript.transcriptChatID {
                    ProgressView().controlSize(.small)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(transcript.busy || isBusy || selectedChatID != nil)
            }
          }
        }
        .frame(maxHeight: 270)
      }
      if let errorText {
        Text(errorText).font(.caption).foregroundStyle(.secondary)
        if selectedChatID == nil {
          Button("Refresh") { loadRevision += 1 }
        }
      }
    }
    .padding(16)
    .frame(width: 330)
    .task(id: loadRevision) {
      isLoading = true
      errorText = nil
      do {
        let result = try await onLoad()
        guard !Task.isCancelled else { return }
        transcripts = Array(result.prefix(20))
      } catch {
        guard !Task.isCancelled else { return }
        errorText = "Couldn’t load earlier transcripts."
      }
      isLoading = false
    }
  }
}
