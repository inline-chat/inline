@testable import InlineIOS
import InlineKit
import InlineProtocol
import Testing
import TextProcessing
import UIKit

@Suite("iOS formatted message copy and paste", .serialized)
@MainActor
struct MessageCopyPasteTests {
  @Test("Selected message text copies rich text and Markdown with UTF-16 selection offsets")
  func selectedMessageCopy() throws {
    let previousItems = UIPasteboard.general.items
    defer { UIPasteboard.general.items = previousItems }

    let source = NSMutableAttributedString(
      string: "👋 café bold ending",
      attributes: [.font: UIFont.systemFont(ofSize: 17)]
    )
    let selection = (source.string as NSString).range(of: "café bold")
    source.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: selection)
    let view = CodeBlockTextView(usingTextLayoutManager: false)
    view.attributedText = source
    view.selectedRange = selection
    view.copy(nil)

    #expect(UIPasteboard.general.string == "café bold")
    #expect(MessageTextPasteboard.markdown() == "**café bold**")
    let rtf = try #require(UIPasteboard.general.data(forPasteboardType: "public.rtf"))
    let rich = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    let font = try #require(rich.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
  }

  @Test("Native copy retains bold and italic where their message ranges overlap")
  func overlappingStyleCopy() throws {
    let previousItems = UIPasteboard.general.items
    defer { UIPasteboard.general.items = previousItems }
    let entities = MessageEntities.with {
      $0.entities = [
        .with { $0.type = .bold
          $0.offset = 0
          $0.length = 9
        },
        .with { $0.type = .italic
          $0.offset = 5
          $0.length = 4
        },
      ]
    }
    MessageTextPasteboard.copy(text: "bold both", entities: entities)

    let rtf = try #require(UIPasteboard.general.data(forPasteboardType: "public.rtf"))
    let rich = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    let boldOnly = try #require(rich.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    let combined = try #require(rich.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)
    #expect(boldOnly.fontDescriptor.symbolicTraits.contains(.traitBold))
    #expect(!boldOnly.fontDescriptor.symbolicTraits.contains(.traitItalic))
    #expect(combined.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]))
  }

  @Test("Composer pastes editable Markdown and sending restores the original bold range")
  func composerPaste() throws {
    let previousItems = UIPasteboard.general.items
    defer { UIPasteboard.general.items = previousItems }
    copyBoldText()

    let compose = ComposeView(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
    let view = compose.textView
    let observer = TextChangeObserver()
    view.delegate = observer
    view.attributedText = NSAttributedString(
      string: "before old after", attributes: [.font: UIFont.systemFont(ofSize: 17)]
    )
    view.selectedRange = NSRange(location: 7, length: 3)
    view.paste(nil)

    #expect(view.text == "before **bold** after")
    #expect(view.selectedRange == NSRange(location: 15, length: 0))
    #expect(observer.changes > 0)
    let font = try #require(view.textStorage.attribute(.font, at: 9, effectiveRange: nil) as? UIFont)
    #expect(!font.fontDescriptor.symbolicTraits.contains(.traitBold))
    let sent = ProcessEntities.fromAttributedString(view.attributedText)
    #expect(sent.text == "before bold after")
    #expect(sent.entities.entities.contains { $0.type == .bold && $0.offset == 7 && $0.length == 4 })
  }

  @Test("Rich text without plain text is available to both composer paste menus")
  func richOnlyPaste() throws {
    let previousItems = UIPasteboard.general.items
    defer { UIPasteboard.general.items = previousItems }
    let source = NSAttributedString(string: "bold", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)])
    let rtf = try source.data(from: NSRange(location: 0, length: source.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    UIPasteboard.general.items = [["public.rtf": rtf]]

    let compose = ComposeView(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
    #expect(compose.textView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))

    let standalone = StandaloneComposeTextView(frame: .zero, textContainer: nil)
    standalone.text = "before old after"
    standalone.selectedRange = NSRange(location: 7, length: 3)
    #expect(standalone.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    standalone.paste(nil)
    #expect(standalone.text == "before **bold** after")
    #expect(standalone.selectedRange == NSRange(location: 15, length: 0))
  }

  private func copyBoldText() {
    let entities = MessageEntities.with {
      $0.entities = [.with { $0.type = .bold
        $0.offset = 0
        $0.length = 4
      }]
    }
    MessageTextPasteboard.copy(text: "bold", entities: entities)
  }

  private final class TextChangeObserver: NSObject, UITextViewDelegate {
    var changes = 0

    func textViewDidChange(_ textView: UITextView) {
      changes += 1
    }
  }
}
