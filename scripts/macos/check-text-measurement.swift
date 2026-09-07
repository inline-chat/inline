import AppKit
import CoreText

// Compile the production measurer directly, without building or launching Inline:
// swiftc -O -o /tmp/check-text-measurement apple/InlineMac/Utils/TextMeasurer.swift \
//   scripts/macos/check-text-measurement.swift
// /tmp/check-text-measurement [optional-private-message-text-file]
// Covers the bounded correction, not all long-message gaps or scrolling performance.
@main
struct TextMeasurementCheck {
  @MainActor
  static func main() throws {
    let font = NSFont.systemFont(ofSize: 14)
    let measurer = TextMeasurer(font: font, extraHeight: 1)
    let paragraph = "این یک پیام آزمایشی فارسی است. متن باید درست اندازه‌گیری شود و فضای خالی اضافه نداشته باشد.\n\n"
    let longPersian = String(repeating: paragraph, count: 180)
    let maximumText = (String(repeating: paragraph, count: 1_200) as NSString).substring(to: 100_000)
    let mixed = String(repeating: "Hello 123 «سلام دنیا» (macOS) — آزمایش متن و اندازه‌گیری.\n\n", count: 300)
    var fixtures: [(String, String)] = [
      ("many short lines", String(repeating: "سلام دنیا\n", count: 1_100)),
      ("long Persian", longPersian),
      ("mixed direction", mixed),
      ("trailing newline", longPersian + "\n"),
      ("100k UTF-16 Persian", maximumText),
      ("bidi controls", String(repeating: "\u{202E}سلام\u{202C} abc \u{2067}دنیا\u{2069}\n", count: 1_000)),
    ]
    if let path = CommandLine.arguments.dropFirst().first {
      try fixtures.append(("private message", String(contentsOfFile: path, encoding: .utf8)))
    }

    var fallbackCount = 0
    for (name, text) in fixtures {
      let attributed = NSMutableAttributedString(string: text, attributes: [.font: font])
      attributed.addAttribute(
        .font,
        value: NSFont.systemFont(ofSize: 14, weight: .semibold),
        range: NSRange(location: 0, length: min(6, attributed.length))
      )
      let usesFallback = CTTypesetterCreateWithAttributedStringAndOptions(attributed, nil) == nil
      if usesFallback { fallbackCount += 1 }
      for width: CGFloat in [240, 400, 600] {
        let start = ContinuousClock.now
        let measured = measurer.measure(attributed, width: width)
        let duration = start.duration(to: .now)
        let rendered = renderedHeight(attributed, width: measured.width)
        check(measured.width > 0 && measured.width <= width)
        if name == "many short lines" {
          check(measured.width < 80, "Short lines must not expand to the container width: \(measured.width)")
        }
        check(measured.height.isFinite)
        // Allow Core Text's existing pixel rounding difference, but neither
        // clipped content nor a growing blank region under the rendered text.
        check(
          abs(measured.height - rendered - 1) <= 3,
          "\(name), width \(width): measured \(measured.height), rendered \(rendered)"
        )
        print(
          "PASS \(name) width=\(Int(width)) fallback=\(usesFallback) height=\(measured.height) render=\(rendered) time=\(duration)"
        )
      }
    }
    check(fallbackCount > 0, "Fixtures must exercise the complexity-limit fallback")

    // Preserve ordinary measurement, formatting, insets, and truncation modes.
    for text in ["", "Hello world", "سلام دنیا", "First\n\nLast", "Line\n", "👩🏽‍💻 👨‍👩‍👧‍👦", "Hello سلام 123"] {
      for mode: NSLineBreakMode in [.byWordWrapping, .byTruncatingTail] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = mode
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style])
        if attributed.length > 3 {
          attributed.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 17, weight: .bold),
            range: NSRange(location: 0, length: 3)
          )
        }
        let sut = TextMeasurer(font: font, lineBreakMode: mode, extraWidth: 2, extraHeight: 1)
        for width: CGFloat in [0, 40.5, 400] {
          let old = legacyMeasure(attributed, width: width)
          let expected = text.isEmpty ? CGSize.zero : CGSize(width: ceil(old.width) + 2, height: ceil(old.height) + 1)
          check(
            sut.measure(attributed, width: width) == expected,
            "Normal measurement changed: \(text.debugDescription), mode \(mode), width \(width), expected \(expected), got \(sut.measure(attributed, width: width))"
          )
        }
      }
    }
    // Extreme single paragraphs can make unrestricted native layout take seconds.
    // Check the protected sizing path without forcing that unrestricted renderer.
    let extreme = NSAttributedString(
      string: maximumText.replacingOccurrences(of: "\n", with: " "), attributes: [.font: font]
    )
    let start = ContinuousClock.now
    let cpuStart = clock()
    let protectedSize = measurer.measure(extreme, width: 400)
    let cpuSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
    let legacyCPUStart = clock()
    let legacySize = legacyMeasure(extreme, width: 400)
    let legacyCPUSeconds = Double(clock() - legacyCPUStart) / Double(CLOCKS_PER_SEC)
    check(
      protectedSize == CGSize(width: ceil(legacySize.width), height: ceil(legacySize.height) + 1),
      "Unsafe paragraph: expected \(legacySize), got \(protectedSize)"
    )
    check(
      cpuSeconds < max(0.25, legacyCPUSeconds * 2),
      "Complexity protection regressed: \(cpuSeconds)s CPU versus \(legacyCPUSeconds)s previously"
    )
    print(
      "PASS protected 100k single paragraph time=\(start.duration(to: .now)) height=\(protectedSize.height) cpu=\(cpuSeconds)s"
    )
    print("PASS ordinary Core Text geometry unchanged; \(fallbackCount) complex fixtures exercised")
  }

  @MainActor
  private static func renderedHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
    // Independent rendering oracle: a real NSTextView, configured like MessageView.
    let view = NSTextView(usingTextLayoutManager: true)
    view.textContainerInset = .zero
    view.textContainer!.lineFragmentPadding = 0
    view.textContainer!.widthTracksTextView = false
    view.textContainer!.heightTracksTextView = false
    view.textContainer!.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    view.textStorage!.setAttributedString(text)
    let manager = view.textLayoutManager!
    manager.ensureLayout(for: manager.documentRange)
    var bottom: CGFloat = 0
    manager.enumerateTextLayoutFragments(
      from: manager.documentRange.location,
      options: [.ensuresLayout, .ensuresExtraLineFragment]
    ) { fragment in
      for line in fragment.textLineFragments where line.characterRange.length > 0 {
        bottom = max(bottom, fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY)
      }
      return true
    }
    return ceil(bottom)
  }

  private static func check(_ condition: Bool, _ message: String = "Check failed") {
    guard condition else {
      FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
      exit(1)
    }
  }

  private static func legacyMeasure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
    CTFramesetterSuggestFrameSizeWithConstraints(
      CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: text.length), nil,
      CGSize(width: max(1, ceil(width)), height: .greatestFiniteMagnitude), nil
    )
  }
}
