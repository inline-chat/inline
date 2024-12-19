import SwiftUI
import UIKit

final class OptimizedTextStorage: NSTextStorage {
  private var storage = NSMutableAttributedString()

  override var string: String { storage.string }

  override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
    -> [NSAttributedString.Key: Any]
  {
    storage.attributes(at: location, effectiveRange: range)
  }

  override func replaceCharacters(in range: NSRange, with str: String) {
    beginEditing()
    storage.replaceCharacters(in: range, with: str)
    edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
    endEditing()
  }

  override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    beginEditing()
    storage.setAttributes(attrs, range: range)
    edited(.editedAttributes, range: range, changeInLength: 0)
    endEditing()
  }
}

final class OptimizedLayoutManager: NSLayoutManager {
  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    guard let textContainer = textContainers.first,
      glyphsToShow.location >= 0,
      glyphsToShow.length <= numberOfGlyphs
    else {
      return
    }

    let visibleRect = textContainer.size
    let glyphRange = glyphRange(
      forBoundingRect: CGRect(origin: .zero, size: visibleRect),
      in: textContainer
    )

    guard glyphRange.location >= 0,
      glyphRange.length <= numberOfGlyphs
    else {
      return
    }

    super.drawGlyphs(forGlyphRange: glyphRange, at: origin)
  }
}

struct Compose: UIViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let maxHeight: CGFloat
  @Binding var height: CGFloat

  private let textAttributes: [NSAttributedString.Key: Any] = [
    .font: UIFont.preferredFont(forTextStyle: .body),
    .foregroundColor: UIColor.label,
  ]

  private let placeholderAttributes: [NSAttributedString.Key: Any] = [
    .font: UIFont.preferredFont(forTextStyle: .body),
    .foregroundColor: UIColor.secondaryLabel,
  ]

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeUIView(context: Context) -> UITextView {
    let storage = OptimizedTextStorage()
    let layoutManager = OptimizedLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    container.widthTracksTextView = true
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0

    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)

    let textView = UITextView(frame: .zero, textContainer: container)
    textView.delegate = context.coordinator

    layoutManager.allowsNonContiguousLayout = true
    layoutManager.usesFontLeading = false
    textView.layoutManager.allowsNonContiguousLayout = true

    textView.backgroundColor = .clear
    textView.font = UIFont.preferredFont(forTextStyle: .body)
    textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)

    textView.isScrollEnabled = true
    textView.autocorrectionType = .no
    textView.autocapitalizationType = UITextAutocapitalizationType.sentences
    textView.smartQuotesType = UITextSmartQuotesType.no
    textView.smartDashesType = UITextSmartDashesType.no

    textView.layer.drawsAsynchronously = true
    textView.layer.shouldRasterize = true
    textView.layer.rasterizationScale = UIScreen.main.scale

    textView.textStorage.setAttributedString(
      NSAttributedString(string: text, attributes: textAttributes)
    )

    return textView
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    guard uiView.text != text else { return }

    UIView.performWithoutAnimation {
      let selectedRange = uiView.selectedRange
      uiView.textStorage.setAttributedString(
        NSAttributedString(string: text, attributes: textAttributes)
      )
      uiView.selectedRange = selectedRange

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        updateHeight(uiView)
      }
    }
  }

  private func updateHeight(_ textView: UITextView) {
    let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .infinity))
    let newHeight = min(size.height, maxHeight)

    guard height != newHeight else { return }
    height = newHeight
  }

  class Coordinator: NSObject, UITextViewDelegate {
    var parent: Compose
    private var heightUpdateWorkItem: DispatchWorkItem?

    init(_ parent: Compose) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text

      heightUpdateWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.updateHeight(textView)
      }
      heightUpdateWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func updateHeight(_ textView: UITextView) {
      let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .infinity))
      parent.height = min(size.height, parent.maxHeight)
    }
  }
}
