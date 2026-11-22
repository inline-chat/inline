import InlineKit
import InlineUI
import Logger
import SwiftUI

@available(iOS 17.0, *)
extension DocumentRow {
  // MARK: - UI Components

  /// The file's thumbnail when it has one, else its type symbol on a tinted tile.
  /// A download arrow, or a progress ring while downloading, sits on top until it's on disk.
  @ViewBuilder
  var fileTile: some View {
    let size = ChatInfoResourceMetrics.tileSize
    let shape = RoundedRectangle(cornerRadius: ChatInfoResourceMetrics.tileCornerRadius, style: .continuous)
    let thumbnail = thumbnailContent
    ZStack {
      if let thumbnail {
        ChatInfoResourceThumbnail(
          id: documentInfo.id,
          content: thumbnail,
          cornerRadius: ChatInfoResourceMetrics.tileCornerRadius
        )
        if documentState != .locallyAvailable {
          shape.fill(.black.opacity(0.35))
        }
      } else {
        shape.fill(ChatInfoResourceFileStyle.tint(mimeType: document.mimeType, fileName: document.fileName).gradient)
      }

      switch documentState {
        case .locallyAvailable:
          if thumbnail == nil {
            Image(systemName: fileTypeIconName)
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(.white)
          }
        case .needsDownload:
          Image(systemName: "arrow.down")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
        case let .downloading(bytesReceived, totalBytes):
          let progress = totalBytes > 0 ? min(max(Double(bytesReceived) / Double(totalBytes), 0), 1) : 0
          Circle()
            .stroke(.white.opacity(0.3), lineWidth: 2)
            .frame(width: 26, height: 26)
          Circle()
            .trim(from: 0, to: max(progress, 0.04))
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 26, height: 26)
            .animation(.linear(duration: 0.15), value: progress)
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  var fileData: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(document.fileName ?? String(localized: "Unknown File"))
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(detailText)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Computed Properties

  /// A thumbnail tile only for files that carry one, so plain documents stay one shape layer.
  var thumbnailContent: ChatInfoResourceThumbnailContent? {
    guard let thumbnail = documentInfo.thumbnail,
          thumbnail.hasDisplayablePreview || InlineTinyThumbnailDecoder.strippedBytes(from: thumbnail) != nil
    else { return nil }
    return ChatInfoResourceThumbnailContent(photo: thumbnail)
  }

  var fileTypeIconName: String {
    DocumentIconResolver.symbolName(
      mimeType: document.mimeType,
      fileName: document.fileName,
      style: .filled
    )
  }

  /// "2.4 MB · Nov 3", or "1.1 MB of 2.4 MB" while downloading.
  var detailText: String {
    switch documentState {
      case let .downloading(bytesReceived, totalBytes) where totalBytes > 0:
        let received = ChatInfoResourceFormat.fileSize(Int(bytesReceived))
        let total = ChatInfoResourceFormat.fileSize(Int(totalBytes))
        return String(localized: "\(received) of \(total)")
      default:
        let date = ChatInfoResourceFormat.rowDate(documentMessage.message.date)
        guard let size = document.size, size > 0 else { return date }
        return "\(ChatInfoResourceFormat.fileSize(size)) · \(date)"
    }
  }

  var accessibilityTitle: String {
    [document.fileName ?? String(localized: "Unknown File"), detailText].joined(separator: ", ")
  }

  var accessibilityActionHint: String {
    switch documentState {
      case .needsDownload: String(localized: "Downloads the file")
      case .downloading: String(localized: "Cancels the download")
      case .locallyAvailable: String(localized: "Opens the file")
    }
  }
}

/// Tile colors by file kind, as Files and Telegram tint documents.
@available(iOS 17.0, *)
enum ChatInfoResourceFileStyle {
  static func tint(mimeType: String?, fileName: String?) -> Color {
    let mime = mimeType?.lowercased() ?? ""
    let ext = fileName.flatMap { name -> String? in
      guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else { return nil }
      return name[name.index(after: dot)...].lowercased()
    } ?? ""

    if mime == "application/pdf" || ext == "pdf" { return Color(uiColor: .systemRed) }
    if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "svg", "psd"].contains(ext) {
      return Color(uiColor: .systemPurple)
    }
    if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext) {
      return Color(uiColor: .systemPink)
    }
    if mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "caf"].contains(ext) {
      return Color(uiColor: .systemIndigo)
    }
    if ["xls", "xlsx", "csv", "tsv", "numbers", "ods"].contains(ext) || mime.contains("spreadsheet") || mime.contains("excel") {
      return Color(uiColor: .systemGreen)
    }
    if ["ppt", "pptx", "key", "keynote", "odp"].contains(ext) || mime.contains("presentation") || mime.contains("powerpoint") {
      return Color(uiColor: .systemOrange)
    }
    if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso"].contains(ext) || mime.contains("zip") || mime.contains("compressed") {
      return Color(uiColor: .systemBrown)
    }
    if ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "sh", "json", "yaml", "yml", "xml", "html", "css", "sql"].contains(ext) {
      return Color(uiColor: .systemTeal)
    }
    if ["doc", "docx", "pages", "rtf", "txt", "md", "odt"].contains(ext) || mime.contains("word") || mime.hasPrefix("text/") {
      return Color(uiColor: .systemBlue)
    }
    return Color(uiColor: .systemGray)
  }
}
