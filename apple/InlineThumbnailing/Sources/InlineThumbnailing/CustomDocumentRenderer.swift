import CoreGraphics
import CoreText
import Foundation

struct CustomRenderedThumbnail {
  let image: CGImage
  let source: ThumbnailSource
}

enum CustomDocumentRenderer {
  static let canvasSize = 600
  static let maximumTextBytes = 64 * 1024
  static let maximumJSONBytes = 512 * 1024

  static func render(kind: CustomDocumentKind, at url: URL) -> CustomRenderedThumbnail? {
    switch kind {
    case .plainText:
      return text(at: url, label: url.pathExtension.uppercased().nonEmpty ?? "TXT", source: .plainText)
    case let .delimited(delimiter):
      return delimited(at: url, delimiter: delimiter)
    case .json:
      return json(at: url)
    case .markdown:
      return markdown(at: url)
    }
  }

  private static func text(
    at url: URL,
    label: String,
    source: ThumbnailSource
  ) -> CustomRenderedThumbnail? {
    guard let contents = boundedText(at: url) else { return nil }
    let lines = contents
      .components(separatedBy: .newlines)
      .map(cleanTextLine)
      .filter { !$0.isEmpty }
      .prefix(8)
    guard !lines.isEmpty else { return nil }

    return renderCanvas(source: source) { context in
      drawCardBackground(context)
      drawLabel(label, context: context)
      var y: CGFloat = 444
      for line in lines {
        drawText(
          String(line.prefix(52)),
          at: CGPoint(x: 54, y: y),
          width: 492,
          appearance: TextAppearance(fontSize: 28, style: .userFixedPitch, color: gray(0.17)),
          context: context
        )
        y -= 48
      }
    }
  }

  private static func delimited(at url: URL, delimiter: Character) -> CustomRenderedThumbnail? {
    guard let contents = boundedText(at: url) else { return nil }
    let rows = parseDelimited(contents, delimiter: delimiter, maximumRows: 6, maximumColumns: 4)
    guard !rows.isEmpty else { return nil }

    return renderCanvas(source: .delimitedText) { context in
      drawCardBackground(context)
      drawLabel(delimiter == "\t" ? "TSV" : "CSV", context: context)

      let origin = CGPoint(x: 42, y: 74)
      let tableWidth: CGFloat = 516
      let tableHeight: CGFloat = 390
      let rowHeight = tableHeight / CGFloat(max(rows.count, 1))
      let columnCount = max(rows.map(\.count).max() ?? 1, 1)
      let columnWidth = tableWidth / CGFloat(columnCount)

      for rowIndex in rows.indices {
        let y = origin.y + tableHeight - CGFloat(rowIndex + 1) * rowHeight
        context.setFillColor(
          rowIndex == 0
            ? color(red: 0.11, green: 0.45, blue: 0.92)
            : gray(rowIndex.isMultiple(of: 2) ? 0.97 : 1)
        )
        context.fill(CGRect(x: origin.x, y: y, width: tableWidth, height: rowHeight))

        for columnIndex in 0 ..< columnCount {
          let x = origin.x + CGFloat(columnIndex) * columnWidth
          context.setStrokeColor(gray(0.86))
          context.stroke(CGRect(x: x, y: y, width: columnWidth, height: rowHeight))
          guard columnIndex < rows[rowIndex].count else { continue }
          drawText(
            String(rows[rowIndex][columnIndex].prefix(18)),
            at: CGPoint(x: x + 12, y: y + rowHeight / 2 - 11),
            width: columnWidth - 24,
            appearance: TextAppearance(
              fontSize: rowIndex == 0 ? 22 : 20,
              style: .system,
              color: rowIndex == 0 ? gray(1) : gray(0.16)
            ),
            context: context
          )
        }
      }
    }
  }

  private static func json(at url: URL) -> CustomRenderedThumbnail? {
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
    guard fileSize <= maximumJSONBytes,
          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
      return text(at: url, label: "JSON", source: .json)
    }

    let rows: [(String, String)]
    if let dictionary = object as? [String: Any] {
      rows = dictionary.keys.sorted().prefix(7).map { key in
        (key, compactJSONValue(dictionary[key]))
      }
    } else if let array = object as? [Any] {
      rows = array.prefix(7).enumerated().map { index, value in
        ("[\(index)]", compactJSONValue(value))
      }
    } else {
      rows = [("value", compactJSONValue(object))]
    }
    guard !rows.isEmpty else { return nil }

    return renderCanvas(source: .json) { context in
      drawCardBackground(context)
      drawLabel("JSON", context: context)
      var y: CGFloat = 442
      for (key, value) in rows {
        drawText(
          String(cleanTextLine(key).prefix(19)),
          at: CGPoint(x: 54, y: y),
          width: 190,
          appearance: TextAppearance(
            fontSize: 24,
            style: .userFixedPitch,
            color: color(red: 0.13, green: 0.43, blue: 0.87)
          ),
          context: context
        )
        drawText(
          String(cleanTextLine(value).prefix(30)),
          at: CGPoint(x: 244, y: y),
          width: 302,
          appearance: TextAppearance(fontSize: 24, style: .userFixedPitch, color: gray(0.17)),
          context: context
        )
        y -= 50
      }
    }
  }

  private static func markdown(at url: URL) -> CustomRenderedThumbnail? {
    guard let contents = boundedText(at: url) else { return nil }
    let sourceLines = contents.components(separatedBy: .newlines)
    let heading = sourceLines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
      .map(cleanMarkdownLine)
    let bodyLines = sourceLines
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") }
      .prefix(7)
    guard heading != nil || !bodyLines.isEmpty else { return nil }

    return renderCanvas(source: .markdown) { context in
      drawCardBackground(context)
      drawLabel("MD", context: context)
      var y: CGFloat = 438
      if let heading {
        drawText(
          String(heading.prefix(38)),
          at: CGPoint(x: 54, y: y),
          width: 492,
          appearance: TextAppearance(fontSize: 32, style: .emphasizedSystem, color: gray(0.12)),
          context: context
        )
        y -= 62
      }

      for sourceLine in bodyLines {
        let isList = sourceLine.hasPrefix("- ") || sourceLine.hasPrefix("* ") || sourceLine.hasPrefix("+ ")
        if isList {
          context.setFillColor(color(red: 0.13, green: 0.43, blue: 0.87))
          context.fillEllipse(in: CGRect(x: 58, y: y + 7, width: 10, height: 10))
        }
        drawText(
          String(cleanMarkdownLine(sourceLine).prefix(isList ? 46 : 50)),
          at: CGPoint(x: isList ? 82 : 54, y: y),
          width: isList ? 464 : 492,
          appearance: TextAppearance(fontSize: 24, style: .system, color: gray(0.22)),
          context: context
        )
        y -= 48
        if y < 82 { break }
      }
    }
  }

  private static func boundedText(at url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximumTextBytes), !data.isEmpty else { return nil }
    guard !data.prefix(4_096).contains(0) else { return nil }
    if let text = String(data: data, encoding: .utf8) { return text }
    if let text = String(data: data, encoding: .utf16) { return text }
    return nil
  }

  private static func parseDelimited(
    _ input: String,
    delimiter: Character,
    maximumRows: Int,
    maximumColumns: Int
  ) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var index = input.startIndex

    func finishField() {
      if row.count < maximumColumns {
        row.append(cleanTextLine(field))
      }
      field = ""
    }

    func finishRow() {
      finishField()
      if !row.allSatisfy(\.isEmpty) { rows.append(row) }
      row = []
    }

    while index < input.endIndex, rows.count < maximumRows {
      let character = input[index]
      let next = input.index(after: index)
      if character == "\"" {
        if quoted, next < input.endIndex, input[next] == "\"" {
          field.append("\"")
          index = input.index(after: next)
          continue
        }
        quoted.toggle()
      } else if character == delimiter, !quoted {
        finishField()
      } else if character == "\n", !quoted {
        finishRow()
      } else if character != "\r" {
        field.append(character)
      }
      index = next
    }

    if rows.count < maximumRows, !field.isEmpty || !row.isEmpty { finishRow() }
    return rows
  }

  private static func compactJSONValue(_ value: Any?) -> String {
    switch value {
    case let string as String:
      return "\"\(string)\""
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? "true" : "false"
      }
      return number.stringValue
    case let array as [Any]:
      return "[\(array.count) items]"
    case let dictionary as [String: Any]:
      return "{\(dictionary.count) keys}"
    case nil:
      return "null"
    default:
      return String(describing: value ?? "null")
    }
  }

  private static func cleanTextLine(_ source: String) -> String {
    source
      .replacingOccurrences(of: "\t", with: "  ")
      .unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) }
      .map(String.init)
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func cleanMarkdownLine(_ source: String) -> String {
    var line = source.trimmingCharacters(in: .whitespaces)
    while line.hasPrefix("#") { line.removeFirst() }
    for prefix in ["- ", "* ", "+ ", "> "] where line.hasPrefix(prefix) {
      line.removeFirst(prefix.count)
    }
    return cleanTextLine(
      line
        .replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")
    )
  }

  private static func renderCanvas(
    source: ThumbnailSource,
    draw: (CGContext) -> Void
  ) -> CustomRenderedThumbnail? {
    guard let context = CGContext(
      data: nil,
      width: canvasSize,
      height: canvasSize,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }
    draw(context)
    guard let image = context.makeImage() else { return nil }
    return CustomRenderedThumbnail(image: image, source: source)
  }

  private static func drawCardBackground(_ context: CGContext) {
    context.setFillColor(gray(0.93))
    context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    context.setFillColor(gray(1))
    context.fill(CGRect(x: 24, y: 24, width: 552, height: 552))
  }

  private static func drawLabel(_ text: String, context: CGContext) {
    drawText(
      text,
      at: CGPoint(x: 54, y: 510),
      width: 200,
      appearance: TextAppearance(fontSize: 26, style: .system, color: gray(0.48)),
      context: context
    )
  }

  private struct TextAppearance {
    let fontSize: CGFloat
    let style: CTFontUIFontType
    let color: CGColor
  }

  private static func drawText(
    _ text: String,
    at point: CGPoint,
    width: CGFloat,
    appearance: TextAppearance,
    context: CGContext
  ) {
    let font = CTFontCreateUIFontForLanguage(appearance.style, appearance.fontSize, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, appearance.fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: font,
      kCTForegroundColorAttributeName as NSAttributedString.Key: appearance.color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.saveGState()
    context.clip(to: CGRect(
      x: point.x,
      y: point.y - 8,
      width: max(0, width),
      height: appearance.fontSize + 14
    ))
    context.textPosition = point
    CTLineDraw(line, context)
    context.restoreGState()
  }

  private static func gray(_ value: CGFloat) -> CGColor {
    CGColor(gray: value, alpha: 1)
  }

  private static func color(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: 1)
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
