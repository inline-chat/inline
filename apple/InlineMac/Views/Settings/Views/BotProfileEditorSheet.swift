import AppKit
import InlineKit
import InlineUI
import InlineProtocol
import Logger
import MemojiKit
import MultipartFormDataKit
import RealtimeV2
import SwiftUI
import UniformTypeIdentifiers

private enum BotProfileEditorError: LocalizedError {
  case permissionDenied(String)
  case invalidFile(String)
  case invalidName
  case uploadFailed
  case updateFailed

  var errorDescription: String? {
    switch self {
    case let .permissionDenied(filename):
      "Cannot access '\(filename)'. Make sure you have permission to view this file."
    case let .invalidFile(message):
      message
    case .invalidName:
      "Name cannot be empty."
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
    case .invalidName:
      "Enter a name for this bot."
    case .uploadFailed:
      "Please try again or select a different image."
    case .updateFailed:
      "Please try again."
    }
  }
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

  func saveName(
    bot: InlineProtocol.User,
    originalName: String?,
    name: String,
    realtimeV2: RealtimeV2
  ) async -> InlineProtocol.User? {
    guard !isSaving else { return nil }
    isSaving = true
    errorState = nil
    defer { isSaving = false }

    do {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedName.isEmpty {
        throw BotProfileEditorError.invalidName
      }

      let nameToSend: String? = (originalName == trimmedName) ? nil : trimmedName
      if nameToSend == nil {
        return bot
      }

      return try await update(
        bot: bot,
        name: nameToSend,
        photoFileUniqueId: nil,
        realtimeV2: realtimeV2
      )
    } catch let error as BotProfileEditorError {
      Log.shared.error("Failed to save bot profile", error: error)
      showError(error)
      return nil
    } catch {
      Log.shared.error("Failed to save bot profile", error: error)
      showError(BotProfileEditorError.updateFailed)
      return nil
    }
  }

  func uploadImage(
    from url: URL,
    bot: InlineProtocol.User,
    realtimeV2: RealtimeV2
  ) async -> InlineProtocol.User? {
    do {
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
      return await uploadImage(data: data, bot: bot, realtimeV2: realtimeV2)
    } catch let error as BotProfileEditorError {
      Log.shared.error("Failed to load bot profile photo", error: error)
      showError(error)
      return nil
    } catch {
      Log.shared.error("Failed to load bot profile photo", error: error)
      showError(.invalidFile("The selected image could not be opened."))
      return nil
    }
  }

  func uploadImage(
    data: Data,
    bot: InlineProtocol.User,
    realtimeV2: RealtimeV2
  ) async -> InlineProtocol.User? {
    guard !isSaving else { return nil }
    isSaving = true
    errorState = nil
    defer { isSaving = false }

    let prepared: Data
    do {
      prepared = try await Task.detached(priority: .userInitiated) {
        try ProfilePhotoProcessor.prepare(data)
      }.value
    } catch {
      Log.shared.error("Failed to prepare bot profile photo", error: error)
      showError(.invalidFile("That image could not be used."))
      return nil
    }

    let upload: UploadFileResult
    do {
      upload = try await ApiClient.shared.uploadFile(
        type: .photo,
        data: prepared,
        filename: "bot-profile-photo.png",
        mimeType: .imagePng,
        progress: { _ in }
      )
    } catch {
      Log.shared.error("Failed to upload bot profile photo", error: error)
      showError(.uploadFailed)
      return nil
    }

    do {
      return try await update(
        bot: bot,
        name: nil,
        photoFileUniqueId: upload.fileUniqueId,
        realtimeV2: realtimeV2
      )
    } catch {
      Log.shared.error("Failed to set bot profile photo", error: error)
      showError(.updateFailed)
      return nil
    }
  }

  func removePhoto(
    bot: InlineProtocol.User,
    realtimeV2: RealtimeV2
  ) async -> InlineProtocol.User? {
    guard !isSaving else { return nil }
    isSaving = true
    errorState = nil
    defer { isSaving = false }

    do {
      return try await update(
        bot: bot,
        name: nil,
        photoFileUniqueId: "",
        realtimeV2: realtimeV2
      )
    } catch {
      Log.shared.error("Failed to remove bot profile photo", error: error)
      showError(.updateFailed)
      return nil
    }
  }

  func showFilePickerError(_ error: Error) {
    if error is CancellationError { return }
    let cocoaError = error as NSError
    if cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSUserCancelledError { return }

    errorState = ErrorState(
      title: "Selection Error",
      message: "Could not select the image file.",
      suggestion: "Please try selecting a different image."
    )
  }

  private func update(
    bot: InlineProtocol.User,
    name: String?,
    photoFileUniqueId: String?,
    realtimeV2: RealtimeV2
  ) async throws -> InlineProtocol.User {
    let result = try await realtimeV2.send(.updateBotProfile(
      botUserId: bot.id,
      name: name,
      photoFileUniqueId: photoFileUniqueId
    ))

    guard case let .updateBotProfile(response) = result else {
      throw BotProfileEditorError.updateFailed
    }

    _ = try await AppDatabase.shared.dbWriter.write { db in
      try User.save(db, user: response.bot)
    }
    return response.bot
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
  let onUpdated: (InlineProtocol.User) -> Void

  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var viewModel = BotProfileEditorViewModel()
  @State private var currentBot: InlineProtocol.User
  @State private var name: String

  private let memojiLog = Log.scoped("BotsSettings.Memoji")

  init(bot: InlineProtocol.User, onUpdated: @escaping (InlineProtocol.User) -> Void) {
    self.onUpdated = onUpdated

    let initial = bot.hasFirstName ? bot.firstName : ""
    _currentBot = State(initialValue: bot)
    _name = State(initialValue: initial)
  }

  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        EditableProfileAvatar(
          size: 56,
          hasPhoto: currentBot.hasProfilePhoto,
          showsMemoji: MemojiBetaRollout.isEnabled(dependencies: dependencies),
          isBusy: viewModel.isSaving,
          onPickFile: usePhotoFile,
          onFilePickerFailure: viewModel.showFilePickerError,
          onUsePhotoData: usePhotoData,
          onMemojiFailure: handleMemojiFailure,
          onRemove: removePhoto,
          avatar: { size in
            UserAvatar(user: User(from: currentBot), size: size)
          }
        )

        VStack(alignment: .leading, spacing: 6) {
          TextField("Bot Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .disabled(viewModel.isSaving)

          if currentBot.hasUsername, !currentBot.username.isEmpty {
            Text("@\(currentBot.username)")
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
            let originalName = currentBot.hasFirstName ? currentBot.firstName : nil
            if let updated = await viewModel.saveName(
              bot: currentBot,
              originalName: originalName,
              name: name,
              realtimeV2: realtimeV2
            ) {
              currentBot = updated
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
    .interactiveDismissDisabled(viewModel.isSaving)
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
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func usePhotoFile(_ url: URL) {
    Task {
      if let updated = await viewModel.uploadImage(from: url, bot: currentBot, realtimeV2: realtimeV2) {
        apply(updated)
      }
    }
  }

  private func usePhotoData(_ data: Data) async -> Bool {
    guard let updated = await viewModel.uploadImage(data: data, bot: currentBot, realtimeV2: realtimeV2) else {
      return false
    }
    apply(updated)
    return true
  }

  private func removePhoto() {
    Task {
      if let updated = await viewModel.removePhoto(bot: currentBot, realtimeV2: realtimeV2) {
        apply(updated)
      }
    }
  }

  private func apply(_ updated: InlineProtocol.User) {
    currentBot = updated
    onUpdated(updated)
  }

  private func handleMemojiFailure(_ error: MemojiError) {
    let message = "Memoji beta failure [\(error.diagnosticCode.rawValue)]: \(error.diagnosticSummary)"
    if error.diagnosticCode == .noSavedMemoji {
      memojiLog.info(message)
    } else {
      memojiLog.error(
        message,
        error: MemojiBetaDiagnosticError(
          code: error.diagnosticCode,
          summary: error.diagnosticSummary
        )
      )
    }
  }
}
