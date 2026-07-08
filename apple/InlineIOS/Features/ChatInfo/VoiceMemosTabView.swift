import Foundation
import InlineKit
import InlineUI
import SwiftUI

struct VoiceMemosTabView: View {
  @ObservedObject var voiceMemosViewModel: ChatVoiceMemosViewModel
  let onShowInChat: (Message) -> Void

  var body: some View {
    VStack(spacing: 16) {
      if voiceMemosViewModel.voiceMemoMessages.isEmpty {
        VStack(spacing: 8) {
          Text("No voice memos found in this chat.")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(voiceMemosViewModel.groupedVoiceMemoMessages, id: \.date) { group in
            Section {
              ForEach(group.messages) { voiceMemo in
                VoiceMemoRow(
                  voiceMemo: voiceMemo,
                  onShowInChat: {
                    onShowInChat(voiceMemo.message)
                  }
                )
                .padding(.bottom, 4)
                .onAppear {
                  Task {
                    await voiceMemosViewModel.loadMoreIfNeeded(currentMessageId: voiceMemo.message.messageId)
                  }
                }
              }
            } header: {
              HStack {
                Text(formatDate(group.date))
                  .font(.subheadline)
                  .fontWeight(.medium)
                  .foregroundColor(.secondary)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color(.systemBackground).opacity(0.95))
                  )
                  .padding(.leading, 16)
                Spacer()
              }
              .padding(.top, 16)
              .padding(.bottom, 8)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      await voiceMemosViewModel.loadInitial()
    }
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }
}

private struct VoiceMemoRow: View {
  let voiceMemo: VoiceMemoMessage
  let onShowInChat: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color(ThemeManager.shared.selected.accent))
        .frame(width: 42, height: 42)
        .background(Circle().fill(.primary.opacity(0.04)))

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text("Voice memo")
            .font(.body)
            .foregroundStyle(.primary)

          Spacer(minLength: 8)

          if let duration = formatDuration(voiceMemo.voice.duration) {
            Text(duration)
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }

        VoiceMessageBubble(
          message: voiceMemo.message,
          outgoing: false,
          maxWidth: 300,
          mode: .minimal
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 14)
    .padding(.horizontal, 14)
    .background {
      RoundedRectangle(cornerRadius: 18)
        .fill(fileBackgroundColor)
    }
    .padding(.horizontal, 16)
    .contextMenu {
      Button {
        onShowInChat()
      } label: {
        Label("Show in Chat", systemImage: "text.bubble")
      }
    }
  }

  private var fileBackgroundColor: Color {
    Color(UIColor { traitCollection in
      if traitCollection.userInterfaceStyle == .dark {
        UIColor(hex: "#141414") ?? UIColor.systemGray6
      } else {
        UIColor(hex: "#F8F8F8") ?? UIColor.systemGray6
      }
    })
  }

  private func formatDuration(_ duration: Int32) -> String? {
    guard duration > 0 else { return nil }
    let clamped = Int(duration)
    let minutes = clamped / 60
    let seconds = clamped % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
