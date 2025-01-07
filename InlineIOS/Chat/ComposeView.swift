import InlineKit
import SwiftUI
import UIKit

struct TextView: UIViewRepresentable {
  @Binding var text: String

  @Binding var height: CGFloat

  private let maxLines: Int = 10
  private let minHeight: CGFloat = 36

  // Cache font metrics
  private let font: UIFont = .systemFont(ofSize: 17)
  private let textContainerInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeUIView(context: Context) -> UITextView {
    // Create TextKit 2 stack to avoid this warning :
    // UITextView 0x10813c600 is switching to TextKit 1 compatibility mode because its layoutManager was accessed. Break on void _UITextViewEnablingCompatibilityMode(UITextView *__strong, BOOL) to debug.

    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    layoutManager.allowsNonContiguousLayout = true
    storage.addLayoutManager(layoutManager)

    let container = NSTextContainer(size: .zero)
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)

    // Initialize textView with TextKit 2 components
    let textView = UITextView(frame: .zero, textContainer: container)
    textView.delegate = context.coordinator
    textView.font = font
    textView.backgroundColor = .clear
    textView.isScrollEnabled = true
    textView.textContainerInset = textContainerInsets
    textView.isSelectable = true
    textView.isUserInteractionEnabled = true
    textView.autocorrectionType = .no
    textView.text = text

    return textView
  }

  func updateUIView(_ uiView: UITextView, context: Context) {
    // Only update text if it actually changed
    guard uiView.text != text else { return }
    uiView.text = text
    recalculateHeight(uiView)
  }

  private func recalculateHeight(_ uiView: UITextView) {
    // Perform all UIView operations on main thread
    DispatchQueue.main.async {
      let size = uiView.sizeThatFits(CGSize(width: uiView.bounds.width, height: .infinity))
      let maxHeight = font.lineHeight * CGFloat(maxLines) + textContainerInsets.top + textContainerInsets.bottom
      let newHeight = min(max(size.height, minHeight), maxHeight)

      if self.height != newHeight {
        self.height = newHeight
      }
    }
  }

  class Coordinator: NSObject, UITextViewDelegate {
    var parent: TextView
    // Add debouncer for text changes
    private var textChangeWorkItem: DispatchWorkItem?

    init(_ parent: TextView) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      // Cancel previous work item
      textChangeWorkItem?.cancel()

      // Create new work item with debounced update
      let workItem = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        DispatchQueue.main.async {
          self.parent.text = textView.text
          self.parent.recalculateHeight(textView)
        }
      }

      textChangeWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      return true
    }
  }
}

struct ComposeView: View {
  @Binding var text: String
  @Binding var height: CGFloat

  var body: some View {
    ZStack(alignment: .leading) {
      TextView(text: $text, height: $height)
        .frame(height: height)
        .background(.clear)

      if text.isEmpty {
        Text("Write a message")
          .foregroundStyle(.tertiary)
          .padding(.leading, 6)
          .padding(.vertical, 6)
          .allowsHitTesting(false)
          .transition(
            .asymmetric(
              insertion: .offset(x: 40).combined(with: .opacity),
              removal: .offset(x: 40).combined(with: .opacity)
            )
          )
      }
    }
    .animation(.smoothSnappy, value: text.isEmpty)
  }
}
