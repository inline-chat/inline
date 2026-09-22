import UIKit

/// The independent message bitmap used by UIKit's native, pannable preview.
final class MessageContextMenuPreviewView: UIImageView {
  private let bubblePath: CGPath
  private let bitmapSize: CGSize

  init(image: UIImage, visiblePath: UIBezierPath) {
    bubblePath = visiblePath.cgPath
    bitmapSize = image.size
    super.init(image: image)
    backgroundColor = .clear
    isOpaque = false
    _ = Self.installShapeBeforeExpansion
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func shapedPreview(_ preview: UITargetedPreview) -> UITargetedPreview {
    guard bitmapSize.width > 0, bitmapSize.height > 0,
          bounds.width > 0, bounds.height > 0 else { return preview }
    let path = UIBezierPath(cgPath: bubblePath)
    path.apply(CGAffineTransform(
      scaleX: bounds.width / bitmapSize.width,
      y: bounds.height / bitmapSize.height
    ))
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    parameters.visiblePath = path
    parameters.shadowPath = path
    let shaped = UITargetedPreview(view: self, parameters: parameters, target: preview.target)
    shaped.setValue(true, forKey: "prefersUnmaskedPlatterStyle")
    return shaped
  }

  // UIKit creates the expanded preview after asking for the lift preview.
  // Supply its outline before the platter builds any masks or animations;
  // changing it in willDisplay/completion visibly morphs a rectangle into a tail.
  // Only our bitmap views take this path; all other native previews pass through.
  private static let installShapeBeforeExpansion: Void = {
    let selector = NSSelectorFromString("setExpandedPreview:")
    guard let platterClass = NSClassFromString("_UIContentPlatterView"),
          let method = class_getInstanceMethod(platterClass, selector) else { return }
    typealias Setter = @convention(c) (UIView, Selector, UITargetedPreview?) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
    let replacement: @convention(block) (UIView, UITargetedPreview?) -> Void = { platter, preview in
      let shaped: UITargetedPreview?
      if let preview, let bitmap = preview.view as? MessageContextMenuPreviewView {
        shaped = bitmap.shapedPreview(preview)
      } else {
        shaped = preview
      }
      original(platter, selector, shaped)
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
  }()
}
