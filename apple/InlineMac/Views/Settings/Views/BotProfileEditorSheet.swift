import AppKit
import InlineKit
import InlineUI
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeV2
import SwiftUI
import UniformTypeIdentifiers

private enum BotProfileEditorError: LocalizedError {
  case permissionDenied(String)
  case invalidFile(String)
  case uploadFailed
  case updateFailed

  var errorDescription: String? {
    switch self {
      case let .permissionDenied(filename):
        "Cannot access '\(filename)'. Make sure you have permission to view this file."
      case let .invalidFile(message):
        message
      case .uploadFailed:
        "Failed to upload the new profile photo."
      case .updateFailed:
        "Failed to update the bot profile."
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .permissionDenied:
        "Try selecting a different file or check the file permissions in Finder."
      case .invalidFile:
        "Please select a valid image file under 10MB."
      case .uploadFailed:
        "Please try again or select a different image."
      case .updateFailed:
        "Please try again."
    }
  }
}

private struct PendingPhoto {
  let data: Data
  let fileType: UTType
  let preview: NSImage?
}

@MainActor
final class BotProfileEditorViewModel: ObservableObject {
  @Published private(set) var isSaving = false
  @Published var errorState: ErrorState?

  private let maxFileSize = 10 * 1_024 * 1_024 // 10MB
  private let supportedImageTypes: Set<UTType> = [.jpeg, .png, .heic]

  struct ErrorState {
    let title: String
    let message: String
    let suggestion: String?
  }

  fileprivate func validateAndLoadPhoto(from url: URL) throws -> PendingPhoto {
    guard url.startAccessingSecurityScopedResource() else {
      throw BotProfileEditorError.permissionDenied(url.lastPathComponent)
    }
    defer { url.stopAccessingSecurityScopedResource() }

    guard let fileType = UTType(filenameExtension: url.pathExtension),
          supportedImageTypes.contains(fileType)
    else {
      throw BotProfileEditorError.invalidFile("'\(url.lastPathComponent)' is not a supported image type.")
    }

    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
    if let fileSize = resourceValues.fileSize, fileSize > maxFileSize {
      throw BotProfileEditorError.invalidFile("'\(url.lastPathComponent)' exceeds maximum size of 10MB.")
    }

    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw BotProfileEditorError.permissionDenied(url.lastPathComponent)
    }

    if data.count > maxFileSize {
      throw BotProfileEditorError.invalidFile("Selected image exceeds maximum size of 10MB.")
    }

    return PendingPhoto(data: data, fileType: fileType, preview: NSImage(data: data))
  }

  fileprivate func save(
    bot: InlineProtocol.User,
    originalName: String?,
    name: String,
    pendingPhoto: PendingPhoto?,
    realtimeV2: RealtimeV2
  ) async -> InlineProtocol.User? {
    guard !isSaving else { return nil }
    isSaving = true
    errorState = nil

    do {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedName.isEmpty {
        throw BotProfileEditorError.invalidFile("Name cannot be empty.")
      }

      let nameToSend: String? = (originalName == trimmedName) ? nil : trimmedName

      var photoFileUniqueId: String? = nil
      if let pendingPhoto {
        photoFileUniqueId = try await uploadPhoto(pendingPhoto)
      }

      if nameToSend == nil, photoFileUniqueId == nil {
        isSaving = false
        return bot
      }

      let result = try await realtimeV2.send(.updateBotProfile(
        botUserId: bot.id,
        name: nameToSend,
        photoFileUniqueId: photoFileUniqueId
      ))

      guard case let .updateBotProfile(response) = result else {
        throw BotProfileEditorError.updateFailed
      }

      let updatedBot = response.bot

      _ = try? await AppDatabase.shared.dbWriter.write { db in
        try User.save(db, user: updatedBot)
      }

      isSaving = false
      return updatedBot
    } catch let error as BotProfileEditorError {
      Log.shared.error("Failed to save bot profile", error: error)
      showError(error)
      isSaving = false
      return nil
    } catch {
      Log.shared.error("Failed to save bot profile", error: error)
      showError(BotProfileEditorError.updateFailed)
      isSaving = false
      return nil
    }
  }

  private func uploadPhoto(_ pendingPhoto: PendingPhoto) async throws -> String {
    let mimeType = switch pendingPhoto.fileType {
      case .jpeg:
        MIMEType.imageJpeg
      case .png:
        MIMEType.imagePng
      default:
        MIMEType.imageJpeg
    }

    let fileName = "bot_profile_photo.\(pendingPhoto.fileType.preferredFilenameExtension ?? "jpg")"

    do {
      let result = try await ApiClient.shared.uploadFile(
        type: .photo,
        data: pendingPhoto.data,
        filename: fileName,
        mimeType: mimeType,
        progress: { _ in }
      )
      return result.fileUniqueId
    } catch {
      throw BotProfileEditorError.uploadFailed
    }
  }

  private func showError(_ error: BotProfileEditorError) {
    errorState = ErrorState(
      title: "Bot Profile Error",
      message: error.errorDescription ?? "An unknown error occurred",
      suggestion: error.recoverySuggestion
    )
  }
}

struct BotProfileEditorSheet: View {
  let bot: InlineProtocol.User
  let onUpdated: (InlineProtocol.User) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var viewModel = BotProfileEditorViewModel()
  @State private var showImagePicker = false
  @State private var pendingPhoto: PendingPhoto?
  @State private var name: String

  init(bot: InlineProtocol.User, onUpdated: @escaping (InlineProtocol.User) -> Void) {
    self.bot = bot
    self.onUpdated = onUpdated

    let initial = bot.hasFirstName ? bot.firstName : ""
    _name = State(initialValue: initial)
  }

  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        Button {
          showImagePicker = true
        } label: {
          avatar
            .overlay(
              Circle()
                .stroke(.primary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSaving)

        VStack(alignment: .leading, spacing: 6) {
          TextField("Bot Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .disabled(viewModel.isSaving)

          if bot.hasUsername, !bot.username.isEmpty {
            Text("@\(bot.username)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }

      HStack(spacing: 12) {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(viewModel.isSaving)

        Spacer()

        Button(viewModel.isSaving ? "Saving..." : "Save") {
          Task {
            let originalName = bot.hasFirstName ? bot.firstName : nil
            if let updated = await viewModel.save(
              bot: bot,
              originalName: originalName,
              name: name,
              pendingPhoto: pendingPhoto,
              realtimeV2: realtimeV2
            ) {
              onUpdated(updated)
              dismiss()
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(viewModel.isSaving)
      }
    }
    .padding(20)
    .frame(minWidth: 460)
    .fileImporter(
      isPresented: $showImagePicker,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      handleImageSelection(result)
    }
    .alert(
      viewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { viewModel.errorState != nil },
        set: { if !$0 { viewModel.errorState = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let errorState = viewModel.errorState {
        VStack(alignment: .leading, spacing: 8) {
          Text(errorState.message)
          if let suggestion = errorState.suggestion {
            Text(suggestion)
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var avatar: some View {
    if let preview = pendingPhoto?.preview {
      Image(nsImage: preview)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    } else {
      UserAvatar(user: User(from: bot), size: 56)
    }
  }

  private func handleImageSelection(_ result: Result<[URL], Error>) {
    do {
      let urls = try result.get()
      guard let url = urls.first else { return }
      pendingPhoto = try viewModel.validateAndLoadPhoto(from: url)
    } catch let error as BotProfileEditorError {
      viewModel.errorState = .init(
        title: "Selection Error",
        message: error.errorDescription ?? "Could not select the image file.",
        suggestion: error.recoverySuggestion
      )
    } catch {
      viewModel.errorState = .init(
        title: "Selection Error",
        message: "Could not select the image file.",
        suggestion: "Please try selecting a different image."
      )
    }
  }
}
