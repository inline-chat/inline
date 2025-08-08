import InlineKit
import InlineUI
import Logger
import SwiftUI

extension DocumentRow {
  // MARK: - Theme

  var textColor: Color {
    (ThemeManager.shared.selected.primaryTextColor?.color ?? .primary)
  }

  var labelColor: Color {
    (ThemeManager.shared.selected.secondaryTextColor?.color.opacity(0.4) ?? .secondary)
  }

  var progressBarColor: Color {
    Color(ThemeManager.shared.selected.accent)
  }

  var fileCircleSize: CGFloat {
    50
  }

  var fileCircleFill: Color {
    .primary.opacity(0.04)
  }

  var contentVPadding: CGFloat {
    14
  }

  var contentHPadding: CGFloat {
    14
  }

  var contentHMargin: CGFloat {
    16
  }

  var fileWrapperCornerRadius: CGFloat {
    18
  }

  // MARK: - UI Components

  @ViewBuilder
  var fileIconCircleButton: some View {
    Button(action: fileIconButtonTapped) {
      ZStack {
        Circle()
          .fill(fileCircleFill)
          .frame(width: fileCircleSize, height: fileCircleSize)

        // Progress indicator
        if case let .downloading(bytesReceived, totalBytes) = documentState,
           totalBytes > 0
        {
          let progress = max(0, min(CGFloat(Double(bytesReceived) / Double(totalBytes)), 1))
          Circle()
            .trim(from: 0, to: progress)
            .stroke(progressBarColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: fileCircleSize, height: fileCircleSize)
            .rotationEffect(.degrees(-90))
        }

        // File icon
        Image(systemName: fileIconName)
          .foregroundColor(fileIconColor)
          .font(.system(size: 22))
      }
    }
    .buttonStyle(PlainButtonStyle())
  }

  @ViewBuilder
  var fileName: some View {
    Text(document.fileName ?? "Unknown File")
      .font(.body)
      .foregroundColor(textColor)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  @ViewBuilder
  var fileSize: some View {
    Text(fileSizeText)
      .font(.callout)
      .foregroundColor(labelColor)
      .frame(minWidth: fileSizeMinWidth, alignment: .leading)
  }

  @ViewBuilder
  var fileData: some View {
    VStack(alignment: .leading, spacing: 2) {
      fileName
      fileSize
    }
  }

  @ViewBuilder
  var fileBackgroundRect: some View {
    RoundedRectangle(cornerRadius: fileWrapperCornerRadius)
      .fill(fileBackgroundColor)
  }

  var fileBackgroundColor: Color {
    Color(UIColor { traitCollection in
      if traitCollection.userInterfaceStyle == .dark {
        UIColor(hex: "#141414") ?? UIColor.systemGray6
      } else {
        UIColor(hex: "#F8F8F8") ?? UIColor.systemGray6
      }
    })
  }

  // MARK: - Computed Properties

  var fileTypeIconName: String {
    if let mimeType = document.mimeType {
      if mimeType.hasPrefix("image/") {
        return "photo.fill"
      } else if mimeType.hasPrefix("video/") {
        return "video.fill"
      } else if mimeType.hasPrefix("audio/") {
        return "music.note"
      } else if mimeType == "application/pdf" {
        return "text.document.fill"
      } else if mimeType == "application/zip" || mimeType == "application/x-rar-compressed" {
        return "archivebox.fill"
      }
    }

    if let fileName = document.fileName,
       let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
    {
      return iconName(for: fileExtension)
    }

    return "document.fill"
  }

  func iconName(for fileExtension: String) -> String {
    switch fileExtension {
      // Documents
      case "pdf": "doc.richtext.fill"
      case "doc", "docx": "text.document.fill"
      case "rtf", "txt": "text.alignleft"
      case "pages": "text.document.fill"
      // Spreadsheets
      case "xls", "xlsx": "tablecells.fill"
      case "csv": "tablecells"
      case "numbers": "tablecells.fill"
      // Presentations
      case "ppt", "pptx": "rectangle.on.rectangle.fill"
      case "key", "keynote": "rectangle.on.rectangle.fill"
      // Images
      case "jpg", "jpeg", "png", "gif", "heic", "heif": "photo.fill"
      case "svg": "photo.artframe"
      case "bmp", "tiff", "tif": "photo.fill"
      case "webp": "photo.fill"
      case "ico": "app.fill"
      case "psd": "photo.stack.fill"
      case "ai", "eps": "paintbrush.pointed.fill"
      // Videos
      case "mp4", "mov", "avi", "mkv", "webm": "video.fill"
      case "m4v", "3gp", "flv", "wmv": "video.fill"
      case "mpg", "mpeg", "m2v": "video.fill"
      // Audio
      case "mp3", "wav", "aac", "m4a": "music.note"
      case "flac", "ogg", "wma": "music.note"
      case "aiff", "au": "music.note"
      // Archives
      case "zip", "rar", "7z", "tar": "archivebox.fill"
      case "gz", "bz2", "xz": "archivebox.fill"
      case "dmg", "iso": "opticaldiscdrive.fill"
      // Code & Development
      case "swift": "swift"
      case "js", "ts", "jsx", "tsx": "curlybraces"
      case "html", "htm": "globe"
      case "css", "scss", "sass": "paintbrush.fill"
      case "json", "xml", "yaml", "yml": "doc.text.fill"
      case "py", "java", "cpp", "c", "h": "terminal.fill"
      case "php", "rb", "go", "rs": "terminal.fill"
      case "sql": "cylinder.fill"
      case "sh", "bash", "zsh": "terminal"
      // Fonts
      case "ttf", "otf", "woff", "woff2": "textformat"
      // 3D & CAD
      case "obj", "fbx", "dae", "3ds": "cube.fill"
      case "dwg", "dxf": "ruler.fill"
      // Ebooks
      case "epub", "mobi", "azw": "book.fill"
      // Executable
      case "app", "exe", "msi": "app.badge.fill"
      case "deb", "rpm": "shippingbox.fill"
      // Configuration
      case "plist", "conf", "cfg", "ini": "gearshape.fill"
      // Logs
      case "log": "doc.text"
      // Certificates & Keys
      case "cer", "crt", "pem", "key": "lock.fill"
      default: "document.fill"
    }
  }

  var fileIconName: String {
    switch documentState {
      case .needsDownload:
        "arrow.down"
      case .downloading:
        "xmark"
      case .locallyAvailable:
        fileTypeIconName
    }
  }

  var fileIconColor: Color {
    switch documentState {
      case .needsDownload, .downloading:
        Color(ThemeManager.shared.selected.accent)
      case .locallyAvailable:
        .gray
    }
  }

  var fileSizeText: String {
    switch documentState {
      case .locallyAvailable, .needsDownload:
        return FileHelpers.formatFileSize(UInt64(document.size ?? 0))
      case let .downloading(bytesReceived, totalBytes):
        let downloadedStr = FileHelpers.formatFileSize(UInt64(bytesReceived))
        let totalStr = FileHelpers.formatFileSize(UInt64(totalBytes))
        return "\(downloadedStr) / \(totalStr)"
    }
  }

  var fileSizeMinWidth: CGFloat {
    // Calculate approximate width needed for file size text
    let sampleText = FileHelpers.formatFileSize(UInt64(document.size ?? 0))
    return max(80, CGFloat(sampleText.count * 8))
  }
}
