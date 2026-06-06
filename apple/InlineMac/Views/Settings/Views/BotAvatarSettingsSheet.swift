import AppKit
import InlineKit
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeV2
import SwiftUI
import UniformTypeIdentifiers

private enum BotAvatarSettingsError: LocalizedError {
  case permissionDenied(String)
  case invalidArchive(String)
  case uploadFailed
  case updateFailed

  var errorDescription: String? {
    switch self {
      case let .permissionDenied(filename):
        "Cannot access '\(filename)'. Make sure you have permission to view this file."
      case let .invalidArchive(message):
        message
      case .uploadFailed:
        "Failed to upload the bot avatar."
      case .updateFailed:
        "Failed to update the bot avatar."
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .permissionDenied:
        "Try selecting a different file or check the file permissions in Finder."
      case .invalidArchive:
        "Choose a zip exported in the Codex pet format."
      case .uploadFailed, .updateFailed:
        "Please try again."
    }
  }
}

private struct CodexAvatarMetadata: Decodable, Sendable {
  let id: String?
  let displayName: String
  let description: String?
  let spritesheetPath: String
}

private struct PendingBotAvatar: Sendable {
  let metadata: CodexAvatarMetadata
  let spritesheet: Data
}

private enum BotAvatarArchiveLoader {
  private static let maxManifestBytes = 64_000
  private static let maxSpritesheetBytes = 40_000_000
  private static let readChunkBytes = 64 * 1024

  static func load(from url: URL) async throws -> PendingBotAvatar {
    try await Task.detached(priority: .userInitiated) {
      try readArchive(from: url)
    }.value
  }

  private static func readArchive(from url: URL) throws -> PendingBotAvatar {
    guard url.startAccessingSecurityScopedResource() else {
      throw BotAvatarSettingsError.permissionDenied(url.lastPathComponent)
    }
    defer { url.stopAccessingSecurityScopedResource() }

    let metadataData = try zipEntryData(zipURL: url, entry: "pet.json", maxBytes: maxManifestBytes)
    let metadata: CodexAvatarMetadata
    do {
      metadata = try JSONDecoder().decode(CodexAvatarMetadata.self, from: metadataData)
    } catch {
      throw BotAvatarSettingsError.invalidArchive("pet.json is missing or invalid.")
    }

    let trimmedName = metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let spritesheetPath = metadata.spritesheetPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, isSafeZipEntry(spritesheetPath), spritesheetExtension(spritesheetPath) != nil else {
      throw BotAvatarSettingsError.invalidArchive("pet.json does not describe a valid spritesheet.")
    }

    let spritesheet = try zipEntryData(zipURL: url, entry: spritesheetPath, maxBytes: maxSpritesheetBytes)
    guard !spritesheet.isEmpty else {
      throw BotAvatarSettingsError.invalidArchive("The spritesheet is empty.")
    }

    return PendingBotAvatar(
      metadata: CodexAvatarMetadata(
        id: metadata.id,
        displayName: trimmedName,
        description: metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines),
        spritesheetPath: spritesheetPath
      ),
      spritesheet: spritesheet
    )
  }

  private static func zipEntryData(zipURL: URL, entry: String, maxBytes: Int) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", zipURL.path, entry]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw BotAvatarSettingsError.invalidArchive("Unable to read the selected zip.")
    }

    do {
      let data = try readBoundedData(
        from: output.fileHandleForReading,
        process: process,
        entry: entry,
        maxBytes: maxBytes
      )
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        throw BotAvatarSettingsError.invalidArchive("The selected zip is missing '\(entry)'.")
      }

      return data
    } catch {
      process.terminate()
      process.waitUntilExit()
      throw error
    }
  }

  private static func readBoundedData(
    from handle: FileHandle,
    process: Process,
    entry: String,
    maxBytes: Int
  ) throws -> Data {
    var data = Data()

    while true {
      let remainingBytes = maxBytes - data.count
      guard remainingBytes >= 0 else {
        throw BotAvatarSettingsError.invalidArchive("The zip entry '\(entry)' is too large.")
      }

      let chunkLimit = min(readChunkBytes, remainingBytes + 1)
      let chunk = try handle.read(upToCount: chunkLimit) ?? Data()
      if chunk.isEmpty {
        break
      }

      guard data.count + chunk.count <= maxBytes else {
        process.terminate()
        throw BotAvatarSettingsError.invalidArchive("The zip entry '\(entry)' is too large.")
      }

      data.append(chunk)
    }

    return data
  }

  static func spritesheetExtension(_ path: String) -> String? {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
      case "png", "webp":
        return ext
      default:
        return nil
    }
  }

  private static func isSafeZipEntry(_ entry: String) -> Bool {
    !entry.isEmpty && !entry.hasPrefix("/") && !entry.split(separator: "/").contains("..")
  }
}

@MainActor
private final class BotAvatarSettingsViewModel: ObservableObject {
  @Published var isSaving = false
  @Published var errorState: ErrorState?

  struct ErrorState {
    let message: String
    let suggestion: String?
  }

  func install(from url: URL, bot: InlineProtocol.User, realtimeV2: RealtimeV2) async -> InlineProtocol.User? {
    guard !isSaving else { return nil }
    isSaving = true
    errorState = nil
    defer { isSaving = false }

    do {
      let pending = try await BotAvatarArchiveLoader.load(from: url)
      let upload = try await uploadSpritesheet(pending)
      let result = try await realtimeV2.send(.setBotAvatar(
        botUserId: bot.id,
        kind: .codexAtlas,
        displayName: pending.metadata.displayName,
        description: pending.metadata.description,
        fileUniqueId: upload
      ))

      guard case let .setBotAvatar(response) = result else {
        throw BotAvatarSettingsError.updateFailed
      }

      await save(response.bot)
      return response.bot
    } catch let error as BotAvatarSettingsError {
      showError(error)
      return nil
    } catch {
      Log.shared.error("Failed to install bot avatar", error: error)
      showError(.updateFailed)
      return nil
    }
  }

  func clear(bot: InlineProtocol.User, realtimeV2: RealtimeV2) async -> InlineProtocol.User? {
    guard !isSaving else { return nil }
    isSaving = true
    errorState = nil
    defer { isSaving = false }

    do {
      let result = try await realtimeV2.send(.clearBotAvatar(botUserId: bot.id))
      guard case let .clearBotAvatar_p(response) = result else {
        throw BotAvatarSettingsError.updateFailed
      }

      await save(response.bot)
      return response.bot
    } catch let error as BotAvatarSettingsError {
      showError(error)
      return nil
    } catch {
      Log.shared.error("Failed to clear bot avatar", error: error)
      showError(.updateFailed)
      return nil
    }
  }

  private func uploadSpritesheet(_ pending: PendingBotAvatar) async throws -> String {
    guard let fileExtension = BotAvatarArchiveLoader.spritesheetExtension(pending.metadata.spritesheetPath) else {
      throw BotAvatarSettingsError.invalidArchive("The spritesheet must be PNG or WebP.")
    }

    let filename: String
    if let id = pending.metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      filename = "\(safeFilenameStem(id)).\(fileExtension)"
    } else {
      filename = URL(fileURLWithPath: pending.metadata.spritesheetPath).lastPathComponent
    }
    let mimeType = fileExtension == "png" ? "image/png" : "image/webp"

    do {
      let result = try await ApiClient.shared.uploadFile(
        type: .photo,
        data: pending.spritesheet,
        filename: filename,
        mimeType: MIMEType(text: mimeType),
        progress: { _ in }
      )
      return result.fileUniqueId
    } catch {
      throw BotAvatarSettingsError.uploadFailed
    }
  }

  private func safeFilenameStem(_ value: String) -> String {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "/")
    let leaf = URL(fileURLWithPath: normalized).lastPathComponent
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitized = String(leaf.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
      .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    return sanitized.isEmpty ? "bot-avatar" : sanitized
  }

  private func showError(_ error: BotAvatarSettingsError) {
    errorState = ErrorState(
      message: error.errorDescription ?? "Failed to update the bot avatar.",
      suggestion: error.recoverySuggestion
    )
  }

  private func save(_ bot: InlineProtocol.User) async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try User.save(db, user: bot)
      }
    } catch {
      Log.shared.error("Failed to save bot avatar locally", error: error)
    }
  }
}

struct BotAvatarSettingsSheet: View {
  let onUpdated: (InlineProtocol.User) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var viewModel = BotAvatarSettingsViewModel()
  @State private var currentBot: InlineProtocol.User
  @State private var showImporter = false

  init(bot: InlineProtocol.User, onUpdated: @escaping (InlineProtocol.User) -> Void) {
    self.onUpdated = onUpdated
    _currentBot = State(initialValue: bot)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Bot Avatar")
          .font(.title3.weight(.semibold))
        Text("Supports Codex pets exported as .zip.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(currentAvatarTitle)
          .font(.body)
        if let description = currentAvatarDescription {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let error = viewModel.errorState {
        VStack(alignment: .leading, spacing: 2) {
          Text(error.message)
            .font(.caption)
            .foregroundStyle(.red)
          if let suggestion = error.suggestion {
            Text(suggestion)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      HStack {
        Button("Choose Zip...") {
          showImporter = true
        }
        .disabled(viewModel.isSaving)

        Button("Clear") {
          Task {
            if let updated = await viewModel.clear(bot: currentBot, realtimeV2: realtimeV2) {
              currentBot = updated
              onUpdated(updated)
            }
          }
        }
        .disabled(viewModel.isSaving || !currentBot.hasBotAvatar)

        if viewModel.isSaving {
          ProgressView()
            .controlSize(.small)
        }

        Spacer()

        Button("Done") {
          dismiss()
        }
      }
    }
    .padding(20)
    .frame(width: 420)
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.zip],
      allowsMultipleSelection: false
    ) { result in
      switch result {
        case let .success(urls):
          guard let url = urls.first else { return }
          Task {
            if let updated = await viewModel.install(from: url, bot: currentBot, realtimeV2: realtimeV2) {
              currentBot = updated
              onUpdated(updated)
            }
          }
        case let .failure(error):
          Log.shared.error("Failed to select bot avatar archive", error: error)
      }
    }
  }

  private var currentAvatarTitle: String {
    guard currentBot.hasBotAvatar else { return "No avatar configured." }
    return currentBot.botAvatar.displayName.isEmpty ? "Avatar configured." : currentBot.botAvatar.displayName
  }

  private var currentAvatarDescription: String? {
    guard currentBot.hasBotAvatar, currentBot.botAvatar.hasDescription_p, !currentBot.botAvatar.description_p.isEmpty else {
      return nil
    }
    return currentBot.botAvatar.description_p
  }
}
