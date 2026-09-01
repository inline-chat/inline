import Foundation
import InlineAudioPlayback

/// The document-audio formats verified against Inline's local AVAudioPlayer engine.
public enum AudioDocumentSupport {
  private static let supportedMimeTypes: Set<String> = [
    "audio/mpeg",
    "audio/mp3",
    "audio/mp4",
    "audio/x-m4a",
    "audio/wav",
    "audio/x-wav",
  ]

  private static let supportedFileExtensions: Set<String> = [
    "m4a",
    "mp3",
    "wav",
  ]

  public static func isPlayableAudio(document: DocumentInfo) -> Bool {
    isPlayableAudio(
      mimeType: document.document.mimeType,
      fileName: document.document.fileName
    )
  }

  public static func isPlayableAudio(mimeType: String?, fileName: String?) -> Bool {
    if let mimeType = normalizedMimeType(mimeType), supportedMimeTypes.contains(mimeType) {
      return true
    }

    guard let fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !fileName.isEmpty
    else {
      return false
    }
    let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    return supportedFileExtensions.contains(fileExtension)
  }

  public static func localURL(for document: DocumentInfo) -> URL? {
    guard let localPath = document.document.localPath?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !localPath.isEmpty
    else {
      return nil
    }

    return FileCache.getUrl(for: .documents, localPath: localPath)
  }

  public static func playbackItem(
    for message: Message,
    document: DocumentInfo
  ) -> AudioPlaybackItem? {
    guard isPlayableAudio(document: document) else { return nil }
    return AudioPlaybackItem(
      kind: .audioFile,
      chatId: message.chatId,
      messageId: message.messageId,
      mediaId: document.id
    )
  }

  private static func normalizedMimeType(_ mimeType: String?) -> String? {
    guard let mimeType else { return nil }
    let normalized = mimeType
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized?.isEmpty == false ? normalized : nil
  }
}

public extension MessagePreviewText {
  static func document(
    fileName: String?,
    mimeType: String?,
    includesEmoji: Bool = true
  ) -> String {
    guard AudioDocumentSupport.isPlayableAudio(mimeType: mimeType, fileName: fileName) else {
      return document(fileName: fileName, includesEmoji: includesEmoji)
    }

    let normalizedName = fileName?
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let label: String = if let normalizedName, !normalizedName.isEmpty {
      normalizedName
    } else {
      "Audio"
    }
    return includesEmoji ? "🎵 \(label)" : label
  }
}
