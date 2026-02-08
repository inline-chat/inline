import Auth
import GRDB
import InlineKit
import Logger
import SwiftUI

struct MoveThreadToSpaceSheet: View {
  let chatId: Int64
  let nav2: Nav2?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @State private var spaces: [Space] = []
  @State private var isLoading: Bool = true
  @State private var isMoving: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Move to Space")
        .font(.title3)
        .fontWeight(.semibold)

      if isLoading {
        HStack(spacing: 10) {
          ProgressView()
          Text("Loading spaces…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
      } else if spaces.isEmpty {
        Text("No spaces available.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 16)
      } else {
        List(spaces, id: \.id) { space in
          Button {
            move(to: space)
          } label: {
            HStack {
              Text(space.displayName)
              Spacer()
              if isMoving {
                ProgressView()
                  .controlSize(.small)
              }
            }
          }
          .disabled(isMoving)
        }
        .listStyle(.inset)
        .frame(height: 260)
      }

      HStack {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)

        Spacer()
      }
    }
    .padding(20)
    .frame(width: 420)
    .task {
      await loadSpaces()
    }
  }

  private func loadSpaces() async {
    guard let currentUserId = Auth.shared.getCurrentUserId() else {
      isLoading = false
      spaces = []
      return
    }

    do {
      let loaded = try await AppDatabase.shared.reader.read { db in
        try Space
          .joining(required: Space.members.filter(Member.Columns.userId == currentUserId))
          .order(Space.Columns.name)
          .fetchAll(db)
      }

      await MainActor.run {
        spaces = loaded
        isLoading = false
      }
    } catch {
      Log.shared.error("Failed to load spaces for move thread sheet", error: error)
      await MainActor.run {
        spaces = []
        isLoading = false
      }
    }
  }

  private func move(to space: Space) {
    guard !isMoving else { return }
    isMoving = true

    Task(priority: .userInitiated) {
      await MainActor.run {
        ToastCenter.shared.showLoading("Moving thread…")
      }
      do {
        _ = try await realtimeV2.send(.moveThread(chatID: chatId, spaceID: space.id))
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showSuccess("Moved to \(space.displayName)")
          isMoving = false
          dismiss()
        }
        if let nav2 {
          // Let sheet dismissal + sidebar/DB observations settle before switching tabs.
          Task { @MainActor in
            await Task.yield()
            nav2.openSpace(space)
            nav2.navigate(to: .chat(peer: .thread(id: chatId)))
          }
        }
      } catch {
        Log.shared.error("Failed to move thread to space", error: error)
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("Failed to move thread")
          isMoving = false
        }
      }
    }
  }
}
