import AppKit

final class ComposeStickerDetector {
  struct DetectedSticker {
    let image: NSImage
    let range: NSRange
  }

  func detectStickers(in attributedString: NSAttributedString) -> [DetectedSticker] {
    guard attributedString.length > 0 else { return [] }
    var results: [DetectedSticker] = []

    guard #available(macOS 15.0, *) else { return results }

    let fullRange = NSRange(location: 0, length: attributedString.length)
    attributedString.enumerateAttribute(.adaptiveImageGlyph, in: fullRange, options: []) { value, range, _ in
      guard let glyph = value as? NSAdaptiveImageGlyph else { return }
      let data = glyph.imageContent
      guard let image = NSImage(data: data) else { return }
      results.append(.init(image: image, range: range))
    }

    // TODO: Detect stickers pasted from the pasteboard before attachments handling strips them.
    return results
  }
}
