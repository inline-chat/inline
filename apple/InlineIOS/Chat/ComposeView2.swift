import InlineKit
import SwiftUI
import UIKit

struct TextView: UIViewRepresentable {
  @Binding var text: String
  let onSend: () -> Void
    
  // For internal height management
  @Binding var height: CGFloat
    
  // Maximum number of lines before scrolling
  private let maxLines: Int = 10
  private let minHeight: CGFloat = 36
    
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
    
  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.font = .systemFont(ofSize: 17)
    textView.backgroundColor = .clear
    textView.isScrollEnabled = true
    textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    
    // Improving performance with these settings
    textView.layoutManager.allowsNonContiguousLayout = true
    textView.isSelectable = true
    textView.isUserInteractionEnabled = true
        
    // Remove padding
    textView.textContainer.lineFragmentPadding = 0
        
    return textView
  }
    
  func updateUIView(_ uiView: UITextView, context: Context) {
    // Only update if text changed
    if uiView.text != text {
      uiView.text = text
      recalculateHeight(uiView)
    }
  }
    
  private func recalculateHeight(_ uiView: UITextView) {
    let size = uiView.sizeThatFits(CGSize(width: uiView.bounds.width, height: .infinity))
    let maxHeight = (uiView.font?.lineHeight ?? 0) * CGFloat(maxLines) + uiView.textContainerInset.top + uiView.textContainerInset.bottom
    let newHeight = min(max(size.height, minHeight), maxHeight)
        
    if height != newHeight {
      height = newHeight
    }
  }
    
  class Coordinator: NSObject, UITextViewDelegate {
    var parent: TextView
        
    init(_ parent: TextView) {
      self.parent = parent
    }
        
    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text
      parent.recalculateHeight(textView)
    }
        
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      return true
    }
  }
}
