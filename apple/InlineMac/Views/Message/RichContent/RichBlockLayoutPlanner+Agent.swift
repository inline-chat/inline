import AppKit
import InlineKit
import InlineProtocol
import TextProcessing

/// Shared metrics for the agent and bot blocks. Views read the same values,
/// so planned and rendered geometry never drift.
enum RichBlockAgentMetrics {
  static let fieldsLabelGap: CGFloat = 12
  static let fieldsRowSpacing: CGFloat = 4
  static let stepMarkerSide: CGFloat = 16
  static let stepMarkerGap: CGFloat = 6
  static let stepSpacing: CGFloat = 5
  static let calloutHorizontalInset: CGFloat = 10
  static let calloutVerticalInset: CGFloat = 8
  static let calloutIconSide: CGFloat = 15
  static let calloutIconGap: CGFloat = 8
  static let meterBarHeight: CGFloat = 6
  static let meterBarGap: CGFloat = 5
  static let diffHeaderHeight: CGFloat = 28
  static let diffBodyVerticalPadding: CGFloat = 6
  static let diffBodyHorizontalPadding: CGFloat = 10
  static let disclosureStatusSide: CGFloat = 13
  static let disclosureTrailingGap: CGFloat = 8
  static let formFieldSpacing: CGFloat = 12
  static let formLabelGap: CGFloat = 4
  static let formChoiceSpacing: CGFloat = 4
  static let formChoiceIndent: CGFloat = 20
  static let formControlHeight: CGFloat = 24
  static let formMultilineHeight: CGFloat = 64
  static let formSubmitHeight: CGFloat = 28
  static let formTextFieldMaximumWidth: CGFloat = 360
  /// Single choices beyond this many options use a pop-up menu.
  static let formChoiceListLimit = 6

  static var diffFont: NSFont { RichBlockCodeMetrics.bodyFont }

  static func diffLineHeight() -> CGFloat {
    let font = diffFont
    return ceil(font.ascender - font.descender + font.leading) + 2
  }
}

extension RichBlockLayoutPlanner {
  /// Monospaced, LTR projection used for diff paths and monospace field values.
  static func monospaceText(
    _ attributedText: NSAttributedString,
    range: RichBlockTextRange,
    color: NSColor = .labelColor
  ) -> NSAttributedString? {
    guard range.offset >= 0, range.length >= 0, range.offset <= attributedText.length,
          range.length <= attributedText.length - range.offset
    else { return nil }
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = .leftToRight
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byCharWrapping
    return NSAttributedString(
      string: (attributedText.string as NSString).substring(
        with: NSRange(location: range.offset, length: range.length)
      ),
      attributes: [
        .font: RichBlockCodeMetrics.bodyFont,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }
}

extension RichBlockLayoutPlanner.Builder {
  struct DisclosureDecorationLayout {
    var value: RichBlockDisclosureDecoration
    var reservedWidth: CGFloat
  }

  private func styled(
    _ range: RichBlockTextRange,
    role: RichBlockTextRole,
    isRTL: Bool,
    maximumWidth: CGFloat? = nil
  ) -> NSAttributedString? {
    RichBlockLayoutPlanner.styledText(
      attributedText,
      offset: range.offset,
      length: range.length,
      role: role,
      baseFontSize: baseFontSize,
      isRTL: isRTL,
      math: math,
      maximumWidth: maximumWidth
    )
  }

  private func validRange(_ text: InlineProtocol.BlockText) -> RichBlockTextRange? {
    let range = RichBlockTextRange(text)
    guard range.offset >= 0, range.length >= 0, range.offset <= attributedText.length,
          range.length <= attributedText.length - range.offset
    else { return nil }
    return range
  }

  private func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
    let measurement = measureText(text, width: max(1, width))
    return CGSize(width: min(width, measurement.maxLineUsedWidth), height: measurement.height)
  }

  // MARK: Disclosure status and meta

  func disclosureDecoration(
    _ disclosure: InlineProtocol.BlockDisclosure,
    width: CGFloat
  ) -> DisclosureDecorationLayout? {
    let status = RichBlockStatus(disclosure.status)
    let meta = disclosure.hasMeta ? validRange(disclosure.meta) : nil
    // Running shows as the summary shimmer and done as plain text; only the
    // states a reader must notice get a glyph.
    let showsGlyph = switch status {
    case .waiting?, .failed?, .cancelled?: true
    default: false
    }
    var metaWidth: CGFloat = 0
    if let meta, meta.length > 0, let text = styled(meta, role: .footer, isRTL: false) {
      metaWidth = min(ceil(measureText(text, width: .greatestFiniteMagnitude, singleLine: true).maxLineUsedWidth), width * 0.4)
    }
    guard status != nil || metaWidth > 0 else { return nil }
    let reserved = (showsGlyph ? RichBlockAgentMetrics.disclosureStatusSide + 4 : 0)
      + metaWidth
      + (showsGlyph || metaWidth > 0 ? RichBlockAgentMetrics.disclosureTrailingGap : 0)
    return .init(
      value: .init(status: status, meta: metaWidth > 0 ? meta : nil, metaWidth: metaWidth),
      reservedWidth: min(reserved, max(0, width - 40))
    )
  }

  // MARK: Fields

  mutating func appendFields(
    _ fields: InlineProtocol.BlockFields,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard !fields.fields.isEmpty, fields.fields.count <= 128 else { return false }
    let isRTL = fields.hasIsRtl ? fields.isRtl : (inheritedDirection ?? false)
    var labels: [(RichBlockTextRange, NSAttributedString)] = []
    var labelColumn: CGFloat = 1
    for field in fields.fields {
      guard let range = validRange(field.label), let text = styled(range, role: .paragraph, isRTL: isRTL)
      else { return false }
      labels.append((range, text))
      labelColumn = max(labelColumn, measure(text, width: .greatestFiniteMagnitude).width)
    }
    labelColumn = min(ceil(labelColumn) + 1, max(60, width * 0.36), 180)
    let valueWidth = max(1, width - labelColumn - RichBlockAgentMetrics.fieldsLabelGap)
    var rows: [RichBlockFieldsNode.Row] = []
    var y: CGFloat = 0
    var usedWidth: CGFloat = 0
    for (index, field) in fields.fields.enumerated() {
      guard let valueRange = validRange(field.value) else { return false }
      let valueText = field.monospace
        ? RichBlockLayoutPlanner.monospaceText(attributedText, range: valueRange)
        : styled(valueRange, role: .paragraph, isRTL: isRTL, maximumWidth: valueWidth)
      guard let valueText else { return false }
      if index > 0 { y += RichBlockAgentMetrics.fieldsRowSpacing }
      let labelSize = measure(labels[index].1, width: labelColumn)
      let valueSize = measure(valueText, width: valueWidth)
      let rowHeight = max(labelSize.height, valueSize.height)
      let labelX = isRTL ? width - labelColumn : 0
      let valueX = isRTL ? 0 : labelColumn + RichBlockAgentMetrics.fieldsLabelGap
      rows.append(.init(
        label: labels[index].0,
        value: valueRange,
        labelFrame: CGRect(x: labelX, y: y, width: labelColumn, height: labelSize.height),
        valueFrame: CGRect(x: isRTL ? valueWidth - valueSize.width : valueX, y: y, width: valueSize.width, height: valueSize.height),
        monospace: field.monospace
      ))
      usedWidth = max(usedWidth, labelColumn + RichBlockAgentMetrics.fieldsLabelGap + valueSize.width)
      y += rowHeight
    }
    let frame = CGRect(x: x, y: height, width: isRTL ? width : min(width, ceil(usedWidth)), height: ceil(y))
    nodes.append(.init(path: path, frame: frame, kind: .fields(.init(rows: rows, isRTL: isRTL))))
    recordMeasuredFrame(frame)
    height = frame.maxY
    return true
  }

  // MARK: Steps

  mutating func appendSteps(
    _ steps: InlineProtocol.BlockSteps,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard !steps.steps.isEmpty, steps.steps.count <= 256 else { return false }
    let isRTL = steps.hasIsRtl ? steps.isRtl : (inheritedDirection ?? false)
    let marker = RichBlockAgentMetrics.stepMarkerSide
    let textX = isRTL ? 0 : marker + RichBlockAgentMetrics.stepMarkerGap
    let textWidth = max(1, width - marker - RichBlockAgentMetrics.stepMarkerGap)
    var planned: [RichBlockStepsNode.Step] = []
    var y: CGFloat = 0
    var usedWidth: CGFloat = 0
    for (index, step) in steps.steps.enumerated() {
      guard let range = validRange(step.text),
            let text = styled(range, role: .paragraph, isRTL: isRTL, maximumWidth: textWidth)
      else { return false }
      if index > 0 { y += RichBlockAgentMetrics.stepSpacing }
      let textSize = measure(text, width: textWidth)
      let firstLine = ceil(baseFontSize * 1.25)
      let markerFrame = CGRect(
        x: isRTL ? width - marker : 0,
        y: y + max(0, floor((firstLine - marker) / 2)),
        width: marker,
        height: marker
      )
      let textFrame = CGRect(x: isRTL ? textWidth - textSize.width : textX, y: y, width: textSize.width, height: textSize.height)
      var detailRange: RichBlockTextRange?
      var detailFrame: CGRect?
      var stepHeight = textSize.height
      if step.hasDetail, let range = validRange(step.detail), range.length > 0,
         let detail = styled(range, role: .footer, isRTL: isRTL, maximumWidth: textWidth)
      {
        let detailSize = measure(detail, width: textWidth)
        detailRange = range
        detailFrame = CGRect(
          x: isRTL ? textWidth - detailSize.width : textX,
          y: y + textSize.height + 1,
          width: detailSize.width,
          height: detailSize.height
        )
        stepHeight += 1 + detailSize.height
        usedWidth = max(usedWidth, textX + detailSize.width)
      }
      usedWidth = max(usedWidth, textX + textSize.width)
      planned.append(.init(
        text: range,
        detail: detailRange,
        status: RichBlockStatus(step.status),
        markerFrame: markerFrame,
        textFrame: textFrame,
        detailFrame: detailFrame
      ))
      y += stepHeight
    }
    let frame = CGRect(x: x, y: height, width: isRTL ? width : min(width, ceil(usedWidth)), height: ceil(y))
    nodes.append(.init(path: path, frame: frame, kind: .steps(.init(steps: planned, isRTL: isRTL))))
    recordMeasuredFrame(frame)
    height = frame.maxY
    return true
  }

  // MARK: Callout

  mutating func layout(
    callout: InlineProtocol.BlockCallout,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    depth: Int,
    inheritedDirection: Bool?
  ) -> Bool {
    let isRTL = callout.hasIsRtl ? callout.isRtl : (inheritedDirection ?? false)
    let tone = RichBlockCalloutTone(callout.kind)
    let insetX = RichBlockAgentMetrics.calloutHorizontalInset
    let insetY = RichBlockAgentMetrics.calloutVerticalInset
    let icon = RichBlockAgentMetrics.calloutIconSide
    let contentOffset = icon + RichBlockAgentMetrics.calloutIconGap
    let contentWidth = max(1, width - insetX * 2 - contentOffset)
    let contentX = isRTL ? x + insetX : x + insetX + contentOffset
    let startY = height
    let decorationIndex = nodes.count
    nodes.append(.init(
      path: path,
      frame: CGRect(x: x, y: startY, width: width, height: 0),
      kind: .callout(.init(
        tone: tone,
        title: nil,
        titleFrame: nil,
        iconFrame: CGRect(x: isRTL ? width - insetX - icon : insetX, y: insetY + 1, width: icon, height: icon),
        isRTL: isRTL
      ))
    ))
    claimMaximumWidth()
    height += insetY
    if callout.hasTitle, let range = validRange(callout.title), range.length > 0,
       let title = styled(range, role: .heading(level: 4), isRTL: isRTL, maximumWidth: contentWidth)
    {
      let size = measure(title, width: contentWidth)
      let frame = CGRect(
        x: (isRTL ? contentWidth - size.width : contentOffset) + insetX,
        y: height - startY,
        width: size.width,
        height: size.height
      )
      if case var .callout(node) = nodes[decorationIndex].kind {
        node.title = range
        node.titleFrame = frame
        nodes[decorationIndex].kind = .callout(node)
      }
      height += size.height
      if !callout.children.isEmpty { height += 4 }
    }
    if !callout.children.isEmpty {
      guard layout(
        blocks: callout.children,
        parent: path,
        x: contentX,
        width: contentWidth,
        depth: depth,
        inheritedDirection: isRTL,
        fullBleedContainer: nil
      ) else { return false }
    }
    height += insetY
    nodes[decorationIndex].frame.size.height = max(icon + insetY * 2, height - startY)
    height = startY + nodes[decorationIndex].frame.height
    trailingTextLine = nil
    return true
  }

  // MARK: Meter

  mutating func appendMeter(
    _ meter: InlineProtocol.BlockMeter,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard let labelRange = validRange(meter.label), meter.max > 0, meter.max.isFinite, meter.value.isFinite,
          let label = styled(labelRange, role: .paragraph, isRTL: inheritedDirection ?? false)
    else { return false }
    let isRTL = inheritedDirection ?? false
    var metaRange: RichBlockTextRange?
    var metaFrame: CGRect?
    var metaWidth: CGFloat = 0
    var metaHeight: CGFloat = 0
    if meter.hasMeta, let range = validRange(meter.meta), range.length > 0,
       let meta = styled(range, role: .footer, isRTL: isRTL)
    {
      let measurement = measureText(meta, width: width * 0.5, singleLine: true)
      metaWidth = ceil(measurement.maxLineUsedWidth)
      metaHeight = measurement.height
      metaRange = range
    }
    let labelWidth = max(1, width - (metaWidth > 0 ? metaWidth + 8 : 0))
    let labelSize = measure(label, width: labelWidth)
    let rowHeight = max(labelSize.height, metaHeight)
    if metaRange != nil {
      metaFrame = CGRect(
        x: isRTL ? 0 : width - metaWidth,
        y: rowHeight - metaHeight,
        width: metaWidth,
        height: metaHeight
      )
    }
    let barFrame = CGRect(
      x: 0,
      y: rowHeight + RichBlockAgentMetrics.meterBarGap,
      width: width,
      height: RichBlockAgentMetrics.meterBarHeight
    )
    let tone: RichBlockMeterTone = switch meter.tone {
    case .warning: .warning
    case .critical: .critical
    case .unspecified, .UNRECOGNIZED: .normal
    }
    let node = RichBlockMeterNode(
      label: labelRange,
      meta: metaRange,
      fraction: min(max(meter.value / meter.max, 0), 1),
      tone: tone,
      labelFrame: CGRect(x: isRTL ? width - labelSize.width : 0, y: 0, width: labelSize.width, height: labelSize.height),
      metaFrame: metaFrame,
      barFrame: barFrame
    )
    let frame = CGRect(x: x, y: height, width: width, height: ceil(barFrame.maxY))
    nodes.append(.init(path: path, frame: frame, kind: .meter(node)))
    claimMaximumWidth()
    height = frame.maxY
    return true
  }

  // MARK: Diff

  mutating func appendDiff(
    _ diff: InlineProtocol.BlockDiff,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat
  ) -> Bool {
    guard let pathRange = validRange(diff.path) else { return false }
    let previous = diff.hasPreviousPath ? validRange(diff.previousPath) : nil
    var body: RichBlockTextRange?
    var renderedLines = 0
    var hiddenLines = 0
    var contentWidth: CGFloat = 0
    let lineHeight = RichBlockAgentMetrics.diffLineHeight()
    if diff.hasText, let range = validRange(diff.text), range.length > 0 {
      body = range
      let source = (attributedText.string as NSString).substring(
        with: NSRange(location: range.offset, length: range.length)
      )
      let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
      let trimmedCount = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
      renderedLines = min(trimmedCount, RichBlockDiffNode.maximumRenderedLines)
      hiddenLines = max(0, trimmedCount - renderedLines)
      let font = RichBlockAgentMetrics.diffFont
      for line in lines.prefix(renderedLines) {
        let lineWidth = (String(line) as NSString).size(withAttributes: [.font: font]).width
        contentWidth = max(contentWidth, min(4_000, ceil(lineWidth)))
      }
      contentWidth += RichBlockAgentMetrics.diffBodyHorizontalPadding * 2
    }
    let footerLines = (hiddenLines > 0 || (diff.hasTruncated && diff.truncated)) ? 1 : 0
    let bodyHeight = body == nil
      ? 0
      : CGFloat(renderedLines + footerLines) * lineHeight + RichBlockAgentMetrics.diffBodyVerticalPadding * 2
    let node = RichBlockDiffNode(
      path: pathRange,
      previousPath: previous,
      change: RichBlockDiffChange(diff.change),
      additions: diff.hasAdditions ? Int(diff.additions) : nil,
      deletions: diff.hasDeletions ? Int(diff.deletions) : nil,
      body: body,
      renderedLineCount: renderedLines,
      hiddenLineCount: hiddenLines,
      truncated: diff.hasTruncated && diff.truncated,
      headerHeight: RichBlockAgentMetrics.diffHeaderHeight,
      lineHeight: lineHeight,
      bodyContentWidth: contentWidth
    )
    let frame = CGRect(
      x: x,
      y: height,
      width: width,
      height: RichBlockAgentMetrics.diffHeaderHeight + bodyHeight
    )
    nodes.append(.init(path: path, frame: frame, kind: .diff(node)))
    claimMaximumWidth()
    height = frame.maxY
    trailingTextLine = nil
    return true
  }

  // MARK: Form

  mutating func appendForm(
    _ form: InlineProtocol.BlockForm,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    let formID = form.formID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !formID.isEmpty, form.fields.count <= 32 else { return false }
    let isRTL = form.hasIsRtl ? form.isRtl : (inheritedDirection ?? false)
    var y: CGFloat = 0
    var titleRange: RichBlockTextRange?
    var titleFrame: CGRect?
    if form.hasTitle, let range = validRange(form.title), range.length > 0,
       let title = styled(range, role: .heading(level: 4), isRTL: isRTL, maximumWidth: width)
    {
      let size = measure(title, width: width)
      titleRange = range
      titleFrame = CGRect(x: isRTL ? width - size.width : 0, y: 0, width: size.width, height: size.height)
      y = size.height + 8
    }
    var fields: [RichBlockFormNode.Field] = []
    var fieldIDs = Set<String>()
    let fieldWidth = min(width, RichBlockAgentMetrics.formTextFieldMaximumWidth)
    for (index, field) in form.fields.enumerated() {
      let fieldID = field.fieldID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !fieldID.isEmpty, fieldIDs.insert(fieldID).inserted,
            let labelRange = validRange(field.label),
            let label = styled(labelRange, role: .paragraph, isRTL: isRTL, maximumWidth: width)
      else { return false }
      if index > 0 { y += RichBlockAgentMetrics.formFieldSpacing }
      let labelSize = measure(label, width: width - 12)
      let labelFrame = CGRect(x: isRTL ? width - labelSize.width : 0, y: y, width: labelSize.width + 12, height: labelSize.height)
      y += labelSize.height
      var descriptionRange: RichBlockTextRange?
      var descriptionFrame: CGRect?
      if field.hasDescription_p, let range = validRange(field.description_p), range.length > 0,
         let description = styled(range, role: .footer, isRTL: isRTL, maximumWidth: width)
      {
        let size = measure(description, width: width)
        descriptionRange = range
        descriptionFrame = CGRect(x: isRTL ? width - size.width : 0, y: y + 1, width: size.width, height: size.height)
        y += 1 + size.height
      }
      y += RichBlockAgentMetrics.formLabelGap
      guard let (control, controlHeight) = formControl(field, width: width, fieldWidth: fieldWidth, isRTL: isRTL)
      else { return false }
      let controlFrameWidth: CGFloat = switch control {
      case .choices: width
      case .toggle: 52
      default: fieldWidth
      }
      fields.append(.init(
        id: fieldID,
        label: labelRange,
        labelFrame: labelFrame,
        description: descriptionRange,
        descriptionFrame: descriptionFrame,
        required: field.required,
        control: control,
        controlFrame: CGRect(
          x: isRTL ? width - controlFrameWidth : 0,
          y: y,
          width: controlFrameWidth,
          height: controlHeight
        )
      ))
      y += controlHeight
    }
    y += RichBlockAgentMetrics.formFieldSpacing
    let submitLabel = form.hasSubmitLabel && !form.submitLabel.trimmingCharacters(in: .whitespaces).isEmpty
      ? form.submitLabel
      : String(localized: "Submit")
    let submitFrame = CGRect(x: 0, y: y, width: width, height: RichBlockAgentMetrics.formSubmitHeight)
    y = submitFrame.maxY
    let node = RichBlockFormNode(
      formID: formID,
      title: titleRange,
      titleFrame: titleFrame,
      fields: fields,
      submitLabel: submitLabel,
      submitFrame: submitFrame,
      requiredGrant: form.requiredGrant.rawValue,
      closed: form.closed,
      isRTL: isRTL
    )
    let frame = CGRect(x: x, y: height, width: width, height: ceil(y))
    nodes.append(.init(path: path, frame: frame, kind: .form(node)))
    claimMaximumWidth()
    height = frame.maxY
    trailingTextLine = nil
    return true
  }

  private func formControl(
    _ field: InlineProtocol.BlockFormField,
    width: CGFloat,
    fieldWidth: CGFloat,
    isRTL: Bool
  ) -> (RichBlockFormNode.Control, CGFloat)? {
    switch field.kind {
    case let .select(select):
      guard !select.options.isEmpty, select.options.count <= 64 else { return nil }
      var optionIDs = Set<String>()
      let usesMenu = !select.multiple && select.options.count > RichBlockAgentMetrics.formChoiceListLimit
      let optionWidth = max(1, width - RichBlockAgentMetrics.formChoiceIndent)
      var options: [RichBlockFormNode.Option] = []
      var y: CGFloat = 0
      for (index, option) in select.options.enumerated() {
        let optionID = option.optionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !optionID.isEmpty, optionIDs.insert(optionID).inserted,
              let labelRange = validRange(option.label),
              let label = styled(labelRange, role: .paragraph, isRTL: isRTL, maximumWidth: optionWidth)
        else { return nil }
        let description = option.hasDescription_p ? validRange(option.description_p) : nil
        if usesMenu {
          options.append(.init(id: optionID, label: labelRange, description: description, frame: .zero))
          continue
        }
        if index > 0 { y += RichBlockAgentMetrics.formChoiceSpacing }
        var optionHeight = max(18, measure(label, width: optionWidth).height)
        if let description, description.length > 0,
           let text = styled(description, role: .footer, isRTL: isRTL, maximumWidth: optionWidth)
        {
          optionHeight += measure(text, width: optionWidth).height
        }
        options.append(.init(
          id: optionID,
          label: labelRange,
          description: description,
          frame: CGRect(x: 0, y: y, width: width, height: optionHeight)
        ))
        y += optionHeight
      }
      let defaults = select.defaultOptionIds.filter(optionIDs.contains)
      if usesMenu {
        var height = RichBlockAgentMetrics.formControlHeight
        var otherFrame: CGRect?
        if select.allowOther {
          otherFrame = CGRect(x: 0, y: height + 6, width: fieldWidth, height: RichBlockAgentMetrics.formControlHeight)
          height += 6 + RichBlockAgentMetrics.formControlHeight
        }
        return (.menu(options: options, defaults: defaults, otherFrame: otherFrame), height)
      }
      var otherFrame: CGRect?
      if select.allowOther {
        y += RichBlockAgentMetrics.formChoiceSpacing
        otherFrame = CGRect(x: 0, y: y, width: min(width, fieldWidth + RichBlockAgentMetrics.formChoiceIndent), height: RichBlockAgentMetrics.formControlHeight)
        y += RichBlockAgentMetrics.formControlHeight
      }
      return (.choices(options: options, multiple: select.multiple, defaults: defaults, otherFrame: otherFrame), y)
    case let .text(text):
      let kind: RichBlockFormNode.TextKind = switch text.kind {
      case .multiline: .multiline
      case .secret: .secret
      case .singleLine, .UNRECOGNIZED: .singleLine
      }
      // A secret field never carries or shows a value.
      let defaultValue = kind == .secret || !text.hasDefaultValue ? nil : text.defaultValue
      return (
        .text(
          kind: kind,
          placeholder: text.hasPlaceholder ? text.placeholder : nil,
          defaultValue: defaultValue,
          maxLength: text.hasMaxLength && text.maxLength > 0 ? Int(text.maxLength) : nil
        ),
        kind == .multiline ? RichBlockAgentMetrics.formMultilineHeight : RichBlockAgentMetrics.formControlHeight
      )
    case let .toggle(toggle):
      return (.toggle(defaultValue: toggle.defaultValue), 22)
    case let .number(number):
      return (
        .number(
          defaultValue: number.hasDefaultValue ? number.defaultValue : nil,
          minimum: number.hasMin ? number.min : nil,
          maximum: number.hasMax ? number.max : nil,
          step: number.hasStep && number.step > 0 ? number.step : nil,
          integer: number.integer
        ),
        RichBlockAgentMetrics.formControlHeight
      )
    case nil:
      return nil
    }
  }
}
