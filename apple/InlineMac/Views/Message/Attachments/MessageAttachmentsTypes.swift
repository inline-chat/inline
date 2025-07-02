import AppKit
import InlineKit

protocol AttachmentView: NSView {
  var attachment: Attachment { get }
}
