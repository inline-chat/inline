import AppKit

// Only persistence/services and ready document rendering are fixtures. The runner
// compiles the production strip, image/video views, and pending document view.
protocol ComposeAttachmentOwner: AnyObject {
  func removeImage(_ id: String)
  func removeVideo(_ id: String)
  func removeFile(_ id: String)
}
enum Theme {
  static let composeAttachmentsVPadding: CGFloat = 6
  static let composeAttachmentImageHeight: CGFloat = 80
  static let documentViewHeight: CGFloat = 36
}
struct DocumentInfo {}
struct LocalMedia { var localPath: String? = nil }
struct Photo { var sizes: [LocalMedia] = [] }
struct VideoInfo { var thumbnail: Photo? = nil; var video = LocalMedia() }
enum FileHelpers {
  enum Kind { case photos, videos }
  static func getLocalCacheDirectory(for kind: Kind) -> URL { URL(fileURLWithPath: "/tmp") }
  static func formatFileSize(_ size: UInt64) -> String { "\(size) bytes" }
}
enum DocumentThumbnailIntegration {
  static func canAttemptGeneration(at url: URL) -> Bool { false }
}
enum DocumentPresentationPlan {
  static let thumbnailSize: CGFloat = 80
  static let iconSize: CGFloat = 40
  static let thumbnailCornerRadius: CGFloat = 8
  static let closeButtonSize: CGFloat = 20
  static let mediaSpacing: CGFloat = 8
  static func preferredHeight(for info: DocumentInfo) -> CGFloat { 80 }
}
class DocumentView: NSView {
  convenience init(documentInfo: DocumentInfo, removeAction: @escaping () -> Void) {
    self.init(frame: .zero)
    let label = NSTextField(labelWithString: "Fixture document.pdf")
    label.frame = NSRect(x: 8, y: 25, width: 220, height: 20)
    addSubview(label)
  }
}
final class ToastCenter {
  static let shared = ToastCenter()
  func showError(_ message: String) {}
  func showSuccess(_ message: String) {}
}
extension NSEdgeInsets {
  static let zero = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}
