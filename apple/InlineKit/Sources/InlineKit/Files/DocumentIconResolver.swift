import Foundation

public enum DocumentIconStyle: Sendable {
  case filled
  case regular
}

public enum DocumentIconResolver {
  public static func symbolName(
    mimeType: String?,
    fileName: String?,
    style: DocumentIconStyle = .filled
  ) -> String {
    if let mimeType,
       let kind = kind(forMimeType: normalize(mimeType))
    {
      return symbolName(for: kind, style: style)
    }

    if let fileName,
       let fileExtension = fileExtension(from: fileName),
       let kind = kind(forFileExtension: fileExtension)
    {
      return symbolName(for: kind, style: style)
    }

    return symbolName(for: .generic, style: style)
  }
}

private extension DocumentIconResolver {
  enum Kind: Sendable {
    case generic
    case image
    case video
    case audio
    case pdf
    case document
    case spreadsheet
    case presentation
    case archive
    case code
    case data
    case font
    case threeD
    case ebook
    case app
    case config
    case log
    case certificate
  }

  static let documentMimeTypes: Set<String> = [
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.oasis.opendocument.text",
    "application/x-iwork-pages-sffpages",
  ]

  static let spreadsheetMimeTypes: Set<String> = [
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.oasis.opendocument.spreadsheet",
    "application/x-iwork-numbers-sffnumbers",
    "text/csv",
    "application/csv",
  ]

  static let presentationMimeTypes: Set<String> = [
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.oasis.opendocument.presentation",
    "application/x-iwork-keynote-sffkey",
  ]

  static let archiveMimeTypes: Set<String> = [
    "application/zip",
    "application/x-zip-compressed",
    "application/vnd.rar",
    "application/x-rar-compressed",
    "application/x-7z-compressed",
    "application/x-tar",
    "application/gzip",
  ]

  static func kind(forMimeType mimeType: String) -> Kind? {
    if mimeType.hasPrefix("image/") { return .image }
    if mimeType.hasPrefix("video/") { return .video }
    if mimeType.hasPrefix("audio/") { return .audio }
    if mimeType == "application/pdf" { return .pdf }
    if documentMimeTypes.contains(mimeType) { return .document }
    if spreadsheetMimeTypes.contains(mimeType) { return .spreadsheet }
    if presentationMimeTypes.contains(mimeType) { return .presentation }
    if archiveMimeTypes.contains(mimeType) { return .archive }
    return nil
  }

  static func kind(forFileExtension fileExtension: String) -> Kind? {
    switch fileExtension {
      case "pdf":
        return .pdf
      case "doc", "docx", "rtf", "txt", "md", "pages", "odt":
        return .document
      case "xls", "xlsx", "csv", "tsv", "numbers", "ods":
        return .spreadsheet
      case "ppt", "pptx", "key", "keynote", "odp":
        return .presentation
      case "jpg", "jpeg", "png", "gif", "heic", "heif", "svg", "bmp", "tiff", "tif", "webp", "ico", "psd", "ai", "eps":
        return .image
      case "mp4", "mov", "avi", "mkv", "webm", "m4v", "3gp", "flv", "wmv", "mpg", "mpeg", "m2v":
        return .video
      case "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma", "aiff", "au", "opus", "amr", "caf":
        return .audio
      case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso":
        return .archive
      case "swift", "js", "ts", "jsx", "tsx", "html", "htm", "css", "scss", "sass", "py", "java", "cpp", "c", "h", "php", "rb", "go", "rs", "sh", "bash", "zsh":
        return .code
      case "json", "xml", "yaml", "yml", "sql":
        return .data
      case "ttf", "otf", "woff", "woff2":
        return .font
      case "obj", "fbx", "dae", "3ds", "dwg", "dxf":
        return .threeD
      case "epub", "mobi", "azw":
        return .ebook
      case "app", "exe", "msi", "deb", "rpm":
        return .app
      case "plist", "conf", "cfg", "ini":
        return .config
      case "log":
        return .log
      case "cer", "crt", "pem", "p12", "pfx":
        return .certificate
      default:
        return nil
    }
  }

  static func symbolName(for kind: Kind, style: DocumentIconStyle) -> String {
    switch kind {
      case .generic:
        return style == .filled ? "document.fill" : "document"
      case .image:
        return style == .filled ? "photo.fill" : "photo"
      case .video:
        return style == .filled ? "video.fill" : "video"
      case .audio:
        return "waveform"
      case .pdf:
        return style == .filled ? "doc.richtext.fill" : "doc.richtext"
      case .document:
        return style == .filled ? "text.document.fill" : "text.document"
      case .spreadsheet:
        return style == .filled ? "tablecells.fill" : "tablecells"
      case .presentation:
        return style == .filled ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"
      case .archive:
        return style == .filled ? "archivebox.fill" : "archivebox"
      case .code:
        return "curlybraces"
      case .data:
        return style == .filled ? "cylinder.fill" : "cylinder"
      case .font:
        return "textformat"
      case .threeD:
        return style == .filled ? "cube.fill" : "cube"
      case .ebook:
        return style == .filled ? "book.fill" : "book"
      case .app:
        return style == .filled ? "app.badge.fill" : "app.badge"
      case .config:
        return style == .filled ? "gearshape.fill" : "gearshape"
      case .log:
        return style == .filled ? "doc.text.fill" : "doc.text"
      case .certificate:
        return style == .filled ? "lock.fill" : "lock"
    }
  }

  static func fileExtension(from fileName: String) -> String? {
    let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    return fileExtension.isEmpty ? nil : fileExtension
  }

  static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
