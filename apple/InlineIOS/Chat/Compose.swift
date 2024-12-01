import InlineKit
import SwiftUI
import UIKit

struct Compose: UIViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let maxHeight: CGFloat
  @Binding var height: CGFloat

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator

    // Performance optimizations
    textView.isScrollEnabled = true
    textView.isUserInteractionEnabled = true
    textView.backgroundColor = .clear

    // Remove border and make transparent
    textView.layer.borderWidth = 0
    textView.layer.borderColor = UIColor.clear.cgColor
    textView.borderStyle = .none

    // Appearance configuration
    textView.font = .preferredFont(forTextStyle: .body)
    textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    textView.textContainer.lineFragmentPadding = 0

    // Animation improvements
    textView.layoutManager.allowsNonContiguousLayout = false
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // Accessibility
    textView.adjustsFontForContentSizeCategory = true

    updateTextViewState(textView)
    return textView
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    if uiView.text != text && uiView.text != placeholder {
      updateTextViewState(uiView)
    }

    DispatchQueue.main.async {
      let size = uiView.sizeThatFits(CGSize(width: uiView.bounds.width, height: .infinity))
      let newHeight = min(size.height, maxHeight)
      if height != newHeight {
        withAnimation(.smoothSnappy) {
          height = newHeight
        }
      }
    }
  }

  private func updateTextViewState(_ textView: UITextView) {
    if textView.text == text { return }

    textView.text = text
    textView.textColor = .label
  }

  class Coordinator: NSObject, UITextViewDelegate {
    var parent: Compose

    init(_ parent: Compose) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text

      let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .infinity))
      withAnimation(.smoothSnappy) {
        parent.height = min(size.height, parent.maxHeight)
      }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {}

    func textViewDidEndEditing(_ textView: UITextView) {}
  }
}
