#if os(macOS)
import AppKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Message text pasteboard")
@MainActor
struct MessageTextPasteboardTests {
  @Test("Copy publishes native rich text and editable Markdown in one clipboard item")
  func copyPublishesNativeFormatting() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    #expect(MessageTextPasteboard.copy(formattedText(), to: pasteboard))
    #expect(pasteboard.pasteboardItems?.count == 1)
    #expect(pasteboard.string(forType: .string) == "Bold italic docs")
    #expect(MessageTextPasteboard.markdown(from: pasteboard) == "**Bold** _italic_ [docs](https://example.com/docs)")

    let rtf = try #require(pasteboard.data(forType: .rtf))
    let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                        documentAttributes: nil)
    #expect(decoded.string == "Bold italic docs")
    let boldFont = try #require(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    let italicFont = try #require(decoded.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
    #expect(link(in: decoded, at: 12) == "https://example.com/docs")
    let html = try #require(pasteboard.data(forType: .html))
    #expect(!html.isEmpty)
  }

  @Test("External RTF formatting becomes Markdown and survives sending")
  func importsExternalRTF() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let source = formattedText()
    let rtf = try source.data(from: NSRange(location: 0, length: source.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let item = NSPasteboardItem()
    item.setString(source.string, forType: .string)
    item.setData(rtf, forType: .rtf)
    #expect(pasteboard.writeObjects([item]))

    let markdown = try #require(MessageTextPasteboard.markdown(from: pasteboard))
    #expect(markdown == "**Bold** _italic_ [docs](https://example.com/docs)")
    let sent = ProcessEntities.fromAttributedString(NSAttributedString(string: markdown))
    #expect(sent.text == source.string)
    #expect(sent.entities.entities.contains { $0.type == .bold && $0.offset == 0 && $0.length == 4 })
    #expect(sent.entities.entities.contains { $0.type == .italic && $0.offset == 5 && $0.length == 6 })
    #expect(sent.entities.entities.contains {
      $0.type == .textURL && $0.offset == 12 && $0.length == 4 && $0.textURL.url == "https://example.com/docs"
    })
  }

  @Test("Inline Markdown takes priority over the fallback native representation")
  func prefersMarkdownRepresentation() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString("source", forType: .string)
    item.setString("**source**", forType: .init(MessageTextPasteboard.markdownType))
    let fallback = formattedText()
    item.setData(try fallback.data(from: NSRange(location: 0, length: fallback.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
    #expect(pasteboard.writeObjects([item]))
    #expect(MessageTextPasteboard.markdown(from: pasteboard) == "**source**")
  }

  @Test("Plain text keeps the existing native plain-text paste path")
  func plainTextFallback() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.setString("ordinary text\n**already markdown**", forType: .string))
    #expect(MessageTextPasteboard.markdown(from: pasteboard) == nil)
    #expect(pasteboard.string(forType: .string) == "ordinary text\n**already markdown**")
  }

  @Test("Malformed rich data leaves the plain representation available")
  func malformedRichTextFallback() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString("plain fallback", forType: .string)
    item.setData(Data([0x00, 0xFF, 0x00, 0xFE]), forType: .rtf)
    #expect(pasteboard.writeObjects([item]))
    #expect(MessageTextPasteboard.markdown(from: pasteboard) == nil)
    #expect(pasteboard.string(forType: .string) == "plain fallback")
  }

  @Test("Selected Unicode text rebases style ranges for copy and resend")
  func selectedUnicodeText() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let source = NSMutableAttributedString(string: "before 👩🏽‍💻 سلام after", attributes: [.font: NSFont.systemFont(ofSize: 15)])
    let selection = (source.string as NSString).range(of: "👩🏽‍💻 سلام")
    source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 15), range: selection)
    #expect(MessageTextPasteboard.copy(source.attributedSubstring(from: selection), to: pasteboard))

    #expect(pasteboard.string(forType: .string) == "👩🏽‍💻 سلام")
    let markdown = try #require(MessageTextPasteboard.markdown(from: pasteboard))
    #expect(markdown == "**👩🏽‍💻 سلام**")
    let sent = ProcessEntities.fromAttributedString(NSAttributedString(string: markdown))
    #expect(sent.text == "👩🏽‍💻 سلام")
    let bold = try #require(sent.entities.entities.first { $0.type == .bold })
    #expect(bold.offset == 0)
    #expect(bold.length == Int64(selection.length))
  }

  @Test("Native copy preserves underline and strikethrough without chat theme colors")
  func preservesAdditionalStyles() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let source = NSMutableAttributedString(string: "under strike", attributes: [
      .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white,
    ])
    source.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 5))
    source.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 6, length: 6))
    #expect(MessageTextPasteboard.copy(source, to: pasteboard))
    let rtf = try #require(pasteboard.data(forType: .rtf))
    let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                        documentAttributes: nil)
    #expect(decoded.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    #expect(decoded.attribute(.strikethroughStyle, at: 6, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    let color = try #require(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    #expect(color.usingColorSpace(.deviceRGB)?.redComponent == 0)
  }

  @Test("Native RTF preserves overlapping bold and italic regardless of entity order")
  func overlappingFontTraits() throws {
    var bold = MessageEntity()
    bold.type = .bold
    bold.offset = 0
    bold.length = 10
    var italic = MessageEntity()
    italic.type = .italic
    italic.offset = 5
    italic.length = 10

    for order in [[bold, italic], [italic, bold]] {
      var entities = MessageEntities()
      entities.entities = order
      let content = MessageTextPasteboard.content(text: "bold both italic", entities: entities)
      let rtf = try #require(content.rtf)
      let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
      let leading = try #require(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      let overlap = try #require(decoded.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
      let trailing = try #require(decoded.attribute(.font, at: 11, effectiveRange: nil) as? NSFont)
      #expect(NSFontManager.shared.traits(of: leading).contains(.boldFontMask))
      #expect(!NSFontManager.shared.traits(of: leading).contains(.italicFontMask))
      #expect(NSFontManager.shared.traits(of: overlap).contains(.boldFontMask))
      #expect(NSFontManager.shared.traits(of: overlap).contains(.italicFontMask))
      #expect(!NSFontManager.shared.traits(of: trailing).contains(.boldFontMask))
      #expect(NSFontManager.shared.traits(of: trailing).contains(.italicFontMask))
    }
  }

  private func formattedText() -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: 16)
    let text = NSMutableAttributedString(string: "Bold italic docs", attributes: [.font: font])
    text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 16), range: NSRange(location: 0, length: 4))
    text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                      range: NSRange(location: 5, length: 6))
    text.addAttribute(.link, value: URL(string: "https://example.com/docs")!, range: NSRange(location: 12, length: 4))
    return text
  }

  private func link(in text: NSAttributedString, at offset: Int) -> String? {
    let value = text.attribute(.link, at: offset, effectiveRange: nil)
    return (value as? URL)?.absoluteString ?? (value as? String)
  }
}
#endif
