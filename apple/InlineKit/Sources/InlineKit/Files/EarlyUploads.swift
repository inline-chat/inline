import Foundation

/// Attachments start uploading while the message is still being written; the send then takes the
/// running upload over (see `FileUploader.startEarlyUpload(media:)`). On by default; turning it off
/// makes every upload start at Send, as before.
public enum EarlyUploadSettings {
  public static let enabledKey = "experimental.earlyUploads"

  public static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }
}
