import AppKit
import InlineKit
import InlineProtocol
import Logger
import UniformTypeIdentifiers

enum VoiceMessageAudioSaver {
  static func canSave(_ message: InlineKit.Message) -> Bool {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return false }
    guard message.hasVoice, let sourceURL = message.voiceLocalURL else { return false }
    return FileManager.default.fileExists(atPath: sourceURL.path)
  }

  @MainActor
  static func save(message: InlineKit.Message, window: NSWindow?) {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled, message.hasVoice else { return }
    guard let window else { return }

    let fileManager = FileManager.default
    guard let sourceURL = message.voiceLocalURL else {
      ToastCenter.shared.showError("Audio isn't available")
      return
    }

    guard fileManager.fileExists(atPath: sourceURL.path) else {
      ToastCenter.shared.showError("Audio isn't downloaded yet")
      return
    }

    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = allowedContentTypes(for: message.voiceContent, sourceURL: sourceURL)
    savePanel.nameFieldStringValue = defaultFileName(for: message, sourceURL: sourceURL)
    savePanel.directoryURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
    savePanel.canCreateDirectories = true

    savePanel.beginSheetModal(for: window) { response in
      guard response == .OK, let destinationURL = savePanel.url else { return }
      copyAudio(from: sourceURL, to: destinationURL)
    }
  }

  private static func defaultFileName(for message: InlineKit.Message, sourceURL: URL) -> String {
    let ext = fileExtension(for: message.voiceContent, sourceURL: sourceURL)
    let id = message.voiceRemoteId ?? message.messageId
    return "voice_\(id).\(ext)"
  }

  private static func fileExtension(for voice: Client_MessageVoiceContent?, sourceURL: URL) -> String {
    let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    if !sourceExtension.isEmpty {
      return sourceExtension.lowercased()
    }

    switch voice?.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "audio/mp4", "audio/x-m4a":
      return "m4a"
    case "audio/ogg":
      return "ogg"
    default:
      return "m4a"
    }
  }

  private static func allowedContentTypes(
    for voice: Client_MessageVoiceContent?,
    sourceURL: URL
  ) -> [UTType] {
    let ext = fileExtension(for: voice, sourceURL: sourceURL)
    if let type = UTType(filenameExtension: ext) {
      return [type, .audio]
    }
    return [.audio]
  }

  private static func copyAudio(from sourceURL: URL, to destinationURL: URL) {
    let fileManager = FileManager.default
    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }

      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      Task { @MainActor in
        ToastCenter.shared.showSuccess("Audio saved")
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
      }
    } catch {
      Log.shared.error("Failed to save audio", error: error)
      Task { @MainActor in
        ToastCenter.shared.showError("Failed to save audio")
      }
    }
  }
}
