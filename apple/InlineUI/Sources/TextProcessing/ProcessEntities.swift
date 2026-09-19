import Foundation
import InlineKit
import InlineProtocol
import Logger

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

public struct CodeBlockStyle: Sendable {
  public var cornerRadius: CGFloat
  public var lineWidth: CGFloat
  public var lineSpacing: CGFloat
  public var horizontalPadding: CGFloat
  public var verticalPadding: CGFloat
  public var blockSpacing: CGFloat
  public var blockHorizontalInset: CGFloat

  public init(
    cornerRadius: CGFloat = 8,
    lineWidth: CGFloat = 4,
    lineSpacing: CGFloat = 4,
    horizontalPadding: CGFloat = 6,
    verticalPadding: CGFloat = 6,
    blockSpacing: CGFloat = 6,
    blockHorizontalInset: CGFloat = 2
  ) {
    self.cornerRadius = cornerRadius
    self.lineWidth = lineWidth
    self.lineSpacing = lineSpacing
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.blockSpacing = blockSpacing
    self.blockHorizontalInset = blockHorizontalInset
  }

  public var textInsetLeft: CGFloat {
    lineWidth + lineSpacing + horizontalPadding
  }

  public var textInsetRight: CGFloat {
    horizontalPadding
  }

  public static let block = CodeBlockStyle(
    cornerRadius: 8,
    lineWidth: 4,
    lineSpacing: 3,
    horizontalPadding: 4,
    verticalPadding: 8.0 / 3.0,
    blockSpacing: 6,
    blockHorizontalInset: 0
  )

  public static let inline = CodeBlockStyle(
    cornerRadius: 6,
    lineWidth: 0,
    lineSpacing: 0,
    horizontalPadding: 3,
    verticalPadding: 1,
    blockSpacing: 0,
    blockHorizontalInset: 0
  )
}

public class ProcessEntities {
  public struct Configuration {
    public struct Palette {
      public let primaryColor: PlatformColor
      public let linkColor: PlatformColor
      public let secondaryColor: PlatformColor

      public init(
        primaryColor: PlatformColor,
        linkColor: PlatformColor,
        secondaryColor: PlatformColor
      ) {
        self.primaryColor = primaryColor
        self.linkColor = linkColor
        self.secondaryColor = secondaryColor
      }
    }

    var font: PlatformFont
    var boldWeight: PlatformFontWeight?
    var monospaceBaseFont: PlatformFont?

    /// Colors used for the rendered rich-text surface.
    var palette: Palette

    /// Default color for body text.
    var primaryColor: PlatformColor { palette.primaryColor }

    /// Color of URLs, link texts and mentions.
    var linkColor: PlatformColor { palette.linkColor }

    /// Color of lower-emphasis rich-text syntax like thread-link brackets.
    var secondaryColor: PlatformColor { palette.secondaryColor }

    /// If enabled, mentions convert to in-app URLs
    var convertMentionsToLink: Bool

    /// If enabled, phone numbers render as tappable entities
    var renderPhoneNumbers: Bool

    /// Optional override for block code background color.
    var codeBlockBackgroundColor: PlatformColor?

    /// Optional override for inline code background color.
    var inlineCodeBackgroundColor: PlatformColor?

    public init(
      font: PlatformFont,
      boldWeight: PlatformFontWeight? = nil,
      monospaceBaseFont: PlatformFont? = nil,
      palette: Palette,
      convertMentionsToLink: Bool = true,
      renderPhoneNumbers: Bool = true,
      codeBlockBackgroundColor: PlatformColor? = nil,
      inlineCodeBackgroundColor: PlatformColor? = nil
    ) {
      self.font = font
      self.boldWeight = boldWeight
      self.monospaceBaseFont = monospaceBaseFont
      self.palette = palette
      self.convertMentionsToLink = convertMentionsToLink
      self.renderPhoneNumbers = renderPhoneNumbers
      self.codeBlockBackgroundColor = codeBlockBackgroundColor
      self.inlineCodeBackgroundColor = inlineCodeBackgroundColor
    }

    public init(
      font: PlatformFont,
      boldWeight: PlatformFontWeight? = nil,
      monospaceBaseFont: PlatformFont? = nil,
      primaryColor: PlatformColor,
      linkColor: PlatformColor,
      secondaryColor: PlatformColor? = nil,
      convertMentionsToLink: Bool = true,
      renderPhoneNumbers: Bool = true,
      codeBlockBackgroundColor: PlatformColor? = nil,
      inlineCodeBackgroundColor: PlatformColor? = nil
    ) {
      self.init(
        font: font,
        boldWeight: boldWeight,
        monospaceBaseFont: monospaceBaseFont,
        palette: Palette(
          primaryColor: primaryColor,
          linkColor: linkColor,
          secondaryColor: secondaryColor ?? Self.defaultSecondaryColor
        ),
        convertMentionsToLink: convertMentionsToLink,
        renderPhoneNumbers: renderPhoneNumbers,
        codeBlockBackgroundColor: codeBlockBackgroundColor,
        inlineCodeBackgroundColor: inlineCodeBackgroundColor
      )
    }

    public init(
      font: PlatformFont,
      boldWeight: PlatformFontWeight? = nil,
      monospaceBaseFont: PlatformFont? = nil,
      textColor: PlatformColor,
      linkColor: PlatformColor,
      secondaryColor: PlatformColor? = nil,
      convertMentionsToLink: Bool = true,
      renderPhoneNumbers: Bool = true,
      codeBlockBackgroundColor: PlatformColor? = nil,
      inlineCodeBackgroundColor: PlatformColor? = nil
    ) {
      self.init(
        font: font,
        boldWeight: boldWeight,
        monospaceBaseFont: monospaceBaseFont,
        primaryColor: textColor,
        linkColor: linkColor,
        secondaryColor: secondaryColor,
        convertMentionsToLink: convertMentionsToLink,
        renderPhoneNumbers: renderPhoneNumbers,
        codeBlockBackgroundColor: codeBlockBackgroundColor,
        inlineCodeBackgroundColor: inlineCodeBackgroundColor
      )
    }

    private static var defaultSecondaryColor: PlatformColor {
      #if os(macOS)
      NSColor.secondaryLabelColor
      #else
      UIColor.secondaryLabel
      #endif
    }
  }

  ///
  /// Converts text and an array of entities to attributed string
  ///
  public static func toAttributedString(
    text: String,
    entities: MessageEntities?,
    configuration: Configuration
  ) -> NSMutableAttributedString {
    let inlineCodeBackground = configuration.inlineCodeBackgroundColor
      ?? configuration.primaryColor.withAlphaComponent(0.12)
    let blockCodeBackground = configuration.codeBlockBackgroundColor
      ?? configuration.primaryColor.withAlphaComponent(0.08)
    let codeBlockStyle = CodeBlockStyle.block

    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: configuration.font,
        .foregroundColor: configuration.primaryColor,
      ]
    )

    guard let entities else {
      return attributedString
    }

    let nsText = text as NSString
    for entity in entities.entities {
      guard let range = validatedRange(of: entity, in: nsText) else { continue }

      switch entity.type {
        case .url:
          // URL is the text itself
          let urlText = (text as NSString).substring(with: range)
          if isValidPhoneNumberCandidate(urlText) {
            guard configuration.renderPhoneNumbers else { break }
            var attributes: [NSAttributedString.Key: Any] = [
              .foregroundColor: configuration.linkColor,
              .underlineStyle: 0,
              .phoneNumber: urlText,
            ]

            #if os(macOS)
            attributes[.cursor] = NSCursor.pointingHand
            #endif

            attributedString.addAttributes(attributes, range: range)
          } else {
            var attributes: [NSAttributedString.Key: Any] = [
              .foregroundColor: configuration.linkColor,
              .underlineStyle: 0,
            ]
            if let url = URL(string: urlText) {
              attributes[.link] = url
            } else {
              attributes[.link] = urlText
            }

            #if os(macOS)
            attributes[.cursor] = NSCursor.pointingHand
            #endif

            attributedString.addAttributes(attributes, range: range)
          }

        case .textURL:
          if case let .textURL(textURL) = entity.entity {
            let rangeText = (text as NSString).substring(with: range)
            if let mentionTarget = inlineMentionTarget(from: textURL.url) {
              var attributes: [NSAttributedString.Key: Any] = [
                .mentionUserId: mentionTarget.userId,
                .foregroundColor: configuration.linkColor,
                .underlineStyle: 0,
              ]
              if let agentId = mentionTarget.agentId {
                attributes[.mentionAgentId] = agentId
              }
              if configuration.convertMentionsToLink {
                attributes[.link] = inlineMentionURL(userId: mentionTarget.userId, agentId: mentionTarget.agentId)
              }

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            } else if let target = inlineThreadLink(from: textURL.url, visibleText: rangeText) {
              attributedString.addAttributes(
                threadLinkAttributes(target, configuration: configuration),
                range: range
              )
              AttributedStringHelpers.styleThreadLinkSyntax(
                in: attributedString,
                range: range,
                linkColor: configuration.linkColor,
                bracketColor: configuration.secondaryColor
              )
            } else if let emailAddress = emailAddress(from: textURL.url) {
              var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: configuration.linkColor,
                .underlineStyle: 0,
                .emailAddress: emailAddress,
              ]

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            } else {
              var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: configuration.linkColor,
                .underlineStyle: 0,
              ]
              if let url = URL(string: textURL.url) {
                attributes[.link] = url
              } else {
                attributes[.link] = textURL.url
              }

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            }
          }

        case .email:
          let emailText = (text as NSString).substring(with: range)
          var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: configuration.linkColor,
            .underlineStyle: 0,
            .emailAddress: emailText,
          ]

          #if os(macOS)
          attributes[.cursor] = NSCursor.pointingHand
          #endif

          attributedString.addAttributes(attributes, range: range)

        case .phoneNumber:
          guard configuration.renderPhoneNumbers else { break }
          let phoneText = (text as NSString).substring(with: range)
          var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: configuration.linkColor,
            .underlineStyle: 0,
            .phoneNumber: phoneText,
          ]

          #if os(macOS)
          attributes[.cursor] = NSCursor.pointingHand
          #endif

          attributedString.addAttributes(attributes, range: range)

        case .botCommand:
          let commandText = (text as NSString).substring(with: range)
          var attributes: [NSAttributedString.Key: Any] = [
            .botCommand: commandText,
            .foregroundColor: configuration.linkColor,
            .underlineStyle: 0,
          ]
          if case let .botCommand(botCommand)? = entity.entity,
             botCommand.botUserID > 0 {
            attributes[.botCommandTargetUserId] = NSNumber(value: botCommand.botUserID)
          }

          #if os(macOS)
          attributes[.cursor] = NSCursor.pointingHand
          #endif

          attributedString.addAttributes(attributes, range: range)

        case .mention:
          if case let .mention(mention) = entity.entity {
            let agentId = mention.hasAgentID ? mention.agentID : nil
            if configuration.convertMentionsToLink {
              var attributes: [NSAttributedString.Key: Any] = [
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
                .link: inlineMentionURL(userId: mention.userID, agentId: agentId),
                .underlineStyle: 0,
              ]
              if let agentId {
                attributes[.mentionAgentId] = agentId
              }

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            } else {
              var attributes: [NSAttributedString.Key: Any] = [
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
              ]
              if let agentId {
                attributes[.mentionAgentId] = agentId
              }
              attributedString.addAttributes(attributes, range: range)
            }
          }

        case .groupMention:
          if case let .groupMention(groupMention) = entity.entity {
            var attributes: [NSAttributedString.Key: Any] = [
              .mentionGroupId: groupMention.groupID,
              .foregroundColor: configuration.linkColor,
            ]

            #if os(macOS)
            attributes[.cursor] = NSCursor.pointingHand
            #endif

            attributedString.addAttributes(attributes, range: range)
          }

        case .thread:
          guard case let .thread(thread) = entity.entity, thread.chatID > 0 else {
            break
          }
          attributedString.addAttributes(
            threadLinkAttributes(.chatId(thread.chatID), configuration: configuration),
            range: range
          )
          AttributedStringHelpers.styleThreadLinkSyntax(
            in: attributedString,
            range: range,
            linkColor: configuration.linkColor,
            bracketColor: configuration.secondaryColor
          )

        case .threadTitle:
          guard case let .threadTitle(threadTitle) = entity.entity,
                threadTitle.spaceID >= 0,
                threadTitle.title.isEmpty == false
          else {
            break
          }
          attributedString.addAttributes(
            threadLinkAttributes(
              .title(spaceId: threadTitle.spaceID, title: threadTitle.title),
              configuration: configuration
            ),
            range: range
          )
          AttributedStringHelpers.styleThreadLinkSyntax(
            in: attributedString,
            range: range,
            linkColor: configuration.linkColor,
            bracketColor: configuration.secondaryColor
          )

        case .bold:
          // Preserve nested emphasis instead of stretching the first font across the entire entity.
          attributedString.enumerateAttribute(.font, in: range) { value, fontRange, _ in
            let boldFont = createBoldFont(
              from: value as? PlatformFont ?? configuration.font,
              preferredWeight: configuration.boldWeight
            )
            attributedString.addAttribute(.font, value: boldFont, range: fontRange)
          }

        case .italic:
          attributedString.enumerateAttribute(.font, in: range) { value, fontRange, _ in
            let italicFont = createItalicFont(from: value as? PlatformFont ?? configuration.font)
            attributedString.addAttribute(.font, value: italicFont, range: fontRange)
          }
          attributedString.addAttribute(.italic, value: true, range: range)

        case .underline, .strikethrough, .highlight:
          if let style = InlineTextStyle.allCases.first(where: { $0.entityType == entity.type }) {
            attributedString.addAttribute(style.marker, value: true, range: range)
          }

        case .math:
          // Keep editor/draft text in canonical UTF-16 coordinates. Formula
          // attachments belong only in the later display projection.
          // A stable per-source range value keeps adjacent formulas distinct
          // when Foundation coalesces runs. Extraction uses the actual run range.
          attributedString.addAttribute(.richTextMath, value: NSValue(range: range), range: range)
          if case let .math(metadata)? = entity.entity, metadata.display {
            attributedString.addAttribute(.richTextMathDisplay, value: true, range: range)
          }

        case .code:
          // monospace font with custom marker
          let monospaceFont = createMonospaceFont(
            from: configuration.monospaceBaseFont ?? configuration.font
          )
          let inlineFont = monospaceFont.withSize(max(11, monospaceFont.pointSize - 1))
          attributedString.addAttributes([
            .font: inlineFont,
            .inlineCode: true,
            .inlineCodeBackground: inlineCodeBackground,
          ], range: range)

        case .pre:
          let monospaceFont = createMonospaceFont(
            from: configuration.monospaceBaseFont ?? configuration.font
          )
          #if os(iOS)
          let blockFont = monospaceFont.withSize(max(11, monospaceFont.pointSize - 2))
          #else
          let blockFont = monospaceFont.withSize(max(11, monospaceFont.pointSize - 1))
          #endif
          let paragraphStyle = NSMutableParagraphStyle()
          paragraphStyle.firstLineHeadIndent = codeBlockStyle.textInsetLeft
          paragraphStyle.headIndent = codeBlockStyle.textInsetLeft
          paragraphStyle.tailIndent = -codeBlockStyle.textInsetRight
          attributedString.addAttributes([
            .font: blockFont,
            .preCode: true,
            .codeBlock: true,
            .codeBlockBackground: blockCodeBackground,
            .paragraphStyle: paragraphStyle,
          ], range: range)
          applyCodeBlockSpacing(
            text: text,
            blockRange: range,
            attributedString: attributedString,
            spacing: codeBlockStyle.blockSpacing
          )

        default:
          break
      }
    }

    // Link attributes clear incidental underlines. Intentional styles win regardless of entity order.
    InlineTextStyle.reapply(to: attributedString)
    return attributedString
  }

  private static func validatedRange(of entity: MessageEntity, in text: NSString) -> NSRange? {
    guard entity.offset >= 0, entity.length > 0,
          entity.offset <= Int64(text.length),
          entity.length <= Int64(text.length) - entity.offset
    else { return nil }
    let start = Int(entity.offset)
    let end = start + Int(entity.length)
    func splitsSurrogate(_ position: Int) -> Bool {
      position > 0 && position < text.length
        && (0xD800 ... 0xDBFF).contains(text.character(at: position - 1))
        && (0xDC00 ... 0xDFFF).contains(text.character(at: position))
    }
    guard !splitsSurrogate(start), !splitsSurrogate(end) else { return nil }
    return NSRange(location: start, length: end - start)
  }

  private static func threadLinkAttributes(
    _ target: ThreadLinkTarget,
    configuration: Configuration
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .threadLink: target,
      .foregroundColor: configuration.linkColor,
      .underlineStyle: 0,
    ]

    #if os(macOS)
    attributes[.cursor] = NSCursor.pointingHand
    #endif

    return attributes
  }

  private static func applyCodeBlockSpacing(
    text: String,
    blockRange: NSRange,
    attributedString: NSMutableAttributedString,
    spacing: CGFloat
  ) {
    guard spacing > 0, blockRange.length > 0 else { return }
    let nsText = text as NSString
    let firstParagraph = nsText.paragraphRange(for: NSRange(location: blockRange.location, length: 0))
    let lastLocation = max(blockRange.location, blockRange.location + blockRange.length - 1)
    let lastParagraph = nsText.paragraphRange(for: NSRange(location: lastLocation, length: 0))

    if NSEqualRanges(firstParagraph, lastParagraph) {
      let intersection = NSIntersectionRange(firstParagraph, blockRange)
      guard intersection.length > 0 else { return }
      let existing = attributedString.attribute(.paragraphStyle, at: intersection.location, effectiveRange: nil)
        as? NSParagraphStyle
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.paragraphSpacingBefore = spacing
      style.paragraphSpacing = spacing
      attributedString.addAttribute(.paragraphStyle, value: style, range: intersection)
      return
    }

    let firstIntersection = NSIntersectionRange(firstParagraph, blockRange)
    if firstIntersection.length > 0 {
      let existing = attributedString.attribute(.paragraphStyle, at: firstIntersection.location, effectiveRange: nil)
        as? NSParagraphStyle
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.paragraphSpacingBefore = spacing
      attributedString.addAttribute(.paragraphStyle, value: style, range: firstIntersection)
    }

    let lastIntersection = NSIntersectionRange(lastParagraph, blockRange)
    if lastIntersection.length > 0 {
      let existing = attributedString.attribute(.paragraphStyle, at: lastIntersection.location, effectiveRange: nil)
        as? NSParagraphStyle
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.paragraphSpacing = spacing
      attributedString.addAttribute(.paragraphStyle, value: style, range: lastIntersection)
    }
  }

  ///
  /// Extract entities from attributed string
  ///
  public static func fromAttributedString(
    _ attributedString: NSAttributedString,
    parseMarkdown: Bool = true,
    threadLinkSpaceId: Int64? = nil
  ) -> (text: String, entities: MessageEntities) {
    var text = attributedString.string
    let nsText = attributedString.string as NSString
    var entities: [MessageEntity] = []
    // Complete oversized math is literal source, but must stay opaque during this extraction.
    // This metadata is revision-local and never becomes a protobuf entity.
    var opaqueMathRanges: [NSRange] = []
    let fullRange = NSRange(location: 0, length: attributedString.length)

    // Extract mention entities first (before text modification)
    attributedString.enumerateAttribute(
      .mentionUserId,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let userId = value as? Int64 {
        guard let range = trimmedEntityRange(in: nsText, range: range) else { return }
        var entity = MessageEntity()
        entity.type = .mention
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.mention = MessageEntity.MessageEntityMention.with {
          $0.userID = userId
          if let agentId = attributedString.attribute(.mentionAgentId, at: range.location, effectiveRange: nil) as? Int64 {
            $0.agentID = agentId
          }
        }
        entities.append(entity)
      }
    }

    attributedString.enumerateAttribute(
      .mentionGroupId,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let groupId = value as? Int64 {
        guard let range = trimmedEntityRange(in: nsText, range: range) else { return }
        var entity = MessageEntity()
        entity.type = .groupMention
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.groupMention = MessageEntity.MessageEntityGroupMention.with {
          $0.groupID = groupId
        }
        entities.append(entity)
      }
    }

    attributedString.enumerateAttribute(
      .threadLink,
      in: fullRange,
      options: []
    ) { value, range, _ in
      guard let target = value as? ThreadLinkTarget, range.length > 0 else {
        return
      }

      var entity = MessageEntity()
      entity.offset = Int64(range.location)
      entity.length = Int64(range.length)

      switch target {
        case let .chatId(chatId):
          guard chatId > 0 else { return }
          entity.type = .thread
          entity.thread = MessageEntity.MessageEntityThread.with {
            $0.chatID = chatId
          }
        case let .title(spaceId, title):
          guard spaceId >= 0, title.isEmpty == false else { return }
          entity.type = .threadTitle
          entity.threadTitle = MessageEntity.MessageEntityThreadTitle.with {
            $0.spaceID = spaceId
            $0.title = title
          }
      }

      entities.append(entity)
    }

    attributedString.enumerateAttribute(
      .botCommand,
      in: fullRange,
      options: []
    ) { value, range, _ in
      guard value != nil,
            range.location != NSNotFound,
            range.length > 0
      else { return }

      let commandText = (attributedString.string as NSString).substring(with: range)
      // Editable Markdown can temporarily sit inside an otherwise valid command label.
      // Validate its visible spelling after removing those markers so routing metadata survives.
      guard parseMarkdown || isBotCommandText(commandText) else { return }

      var entity = MessageEntity()
      entity.type = .botCommand
      entity.offset = Int64(range.location)
      entity.length = Int64(range.length)
      if let target = attributedString.attribute(
        .botCommandTargetUserId,
        at: range.location,
        effectiveRange: nil
      ) as? NSNumber,
        target.int64Value > 0 {
        entity.botCommand = MessageEntity.MessageEntityBotCommand.with {
          $0.botUserID = target.int64Value
        }
      }
      entities.append(entity)
    }

    attributedString.enumerateAttribute(
      .emailAddress,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let emailAddress = value as? String, !emailAddress.isEmpty {
        var entity = MessageEntity()
        entity.type = .email
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    attributedString.enumerateAttribute(
      .phoneNumber,
      in: fullRange,
      options: []
    ) { value, range, _ in
      guard value != nil, range.length > 0 else { return }

      var phoneText = (attributedString.string as NSString).substring(with: range)
      if parseMarkdown, !isValidPhoneNumberCandidate(phoneText) {
        // Validate only explicit phone metadata after stripping editable syntax. A plain
        // attributed string avoids re-entering this attribute path; tel: link labels may be arbitrary.
        phoneText = fromAttributedString(NSAttributedString(string: phoneText)).text
      }
      guard isValidPhoneNumberCandidate(phoneText) else { return }

      var entity = MessageEntity()
      entity.type = .phoneNumber
      entity.offset = Int64(range.location)
      entity.length = Int64(range.length)
      entities.append(entity)
    }

    // Extract link entities (excluding mention links).
    attributedString.enumerateAttribute(
      .link,
      in: fullRange,
      options: []
    ) { value, range, _ in
      guard range.location != NSNotFound, range.length > 0 else { return }

      // Skip if this range is a mention; mention extraction is authoritative.
      let attributesAtLocation = attributedString.attributes(at: range.location, effectiveRange: nil)
      if attributesAtLocation[.mentionUserId] != nil {
        return
      }

      if attributesAtLocation[.mentionGroupId] != nil {
        return
      }

      if attributesAtLocation[.threadLink] != nil {
        return
      }

      if attributesAtLocation[.emailAddress] != nil {
        return
      }

      if attributesAtLocation[.phoneNumber] != nil {
        return
      }

      if attributesAtLocation[.botCommand] != nil {
        return
      }

      let urlString: String? = {
        if let url = value as? URL { return url.absoluteString }
        if let str = value as? String { return str }
        return nil
      }()

      guard let urlString, !urlString.isEmpty else { return }

      let rangeText = (attributedString.string as NSString).substring(with: range)

      if let mentionTarget = inlineMentionTarget(from: urlString) {
        guard let range = trimmedEntityRange(in: nsText, range: range) else { return }
        var entity = MessageEntity()
        entity.type = .mention
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.mention = MessageEntity.MessageEntityMention.with {
          $0.userID = mentionTarget.userId
          if let agentId = mentionTarget.agentId {
            $0.agentID = agentId
          }
        }
        entities.append(entity)
        return
      }

      if let target = inlineThreadLink(from: urlString, visibleText: rangeText),
         let entity = threadEntity(target: target, offset: Int64(range.location), length: Int64(range.length))
      {
        entities.append(entity)
        return
      }

      if emailAddress(from: urlString) != nil {
        var entity = MessageEntity()
        entity.type = .email
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
        return
      }

      if phoneNumber(from: urlString) != nil {
        var entity = MessageEntity()
        entity.type = .phoneNumber
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
        return
      }

      // Ignore data-detector and unsafe link targets.
      guard isAllowedExternalLink(urlString) else { return }

      // Prefer URL entity when the visible text is the URL itself; otherwise use text_url.
      if rangeText == urlString {
        var entity = MessageEntity()
        entity.type = .url
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      } else {
        var entity = MessageEntity()
        entity.type = .textURL
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.textURL = MessageEntity.MessageEntityTextUrl.with {
          $0.url = urlString
        }
        entities.append(entity)
      }
    }

    attributedString.enumerateAttribute(.richTextMath, in: fullRange) { value, range, _ in
      guard value is NSValue else { return }
      entities.append(MessageEntity.with {
        $0.type = .math
        $0.offset = Int64(range.location)
        $0.length = Int64(range.length)
        if attributedString.attribute(.richTextMathDisplay, at: range.location, effectiveRange: nil) as? Bool == true {
          $0.math = .with { $0.display = true }
        }
      })
    }

    // Only semantic markers become styles; pasted colors and incidental link underlines do not.
    for style in InlineTextStyle.allCases {
      attributedString.enumerateAttribute(style.marker, in: fullRange) { value, range, _ in
        guard value as? Bool == true else { return }
        entities.append(MessageEntity.with {
          $0.type = style.entityType
          $0.offset = Int64(range.location)
          $0.length = Int64(range.length)
        })
      }
    }

    // Extract inline code entities from custom attribute
    attributedString.enumerateAttribute(
      .inlineCode,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if value != nil {
        var entity = MessageEntity()
        entity.type = .code
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    // Extract pre code entities from custom attribute
    attributedString.enumerateAttribute(
      .preCode,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if value != nil {
        var entity = MessageEntity()
        entity.type = .pre
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    // Extract italic entities from font attributes (only if no custom italic attribute exists)
    attributedString.enumerateAttribute(
      .font,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let font = value as? PlatformFont {
        // Check if this range already has a custom italic attribute
        let hasItalicAttribute = attributedString.attributes(at: range.location, effectiveRange: nil)[.italic] != nil

        if !hasItalicAttribute {
          #if os(macOS)
          let isItalic = NSFontManager.shared.traits(of: font).contains(.italicFontMask)
          #else
          let isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
          #endif

          if isItalic {
            var entity = MessageEntity()
            entity.type = .italic
            entity.offset = Int64(range.location)
            entity.length = Int64(range.length)
            entities.append(entity)
          }
        }
      }
    }

    // Also check for custom italic attribute (fallback)
    attributedString.enumerateAttribute(
      .italic,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if value != nil {
        var entity = MessageEntity()
        entity.type = .italic
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entities.append(entity)
      }
    }

    // Extract bold entities from font attributes (only if no existing bold entity)
    attributedString.enumerateAttribute(
      .font,
      in: fullRange,
      options: []
    ) { value, range, _ in
      if let font = value as? PlatformFont {
        #if os(macOS)
        let isBold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        #else
        let isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif

        if isBold {
          var entity = MessageEntity()
          entity.type = .bold
          entity.offset = Int64(range.location)
          entity.length = Int64(range.length)
          entities.append(entity)
        }
      }
    }

    if parseMarkdown {
      entities = extractMathFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      // Extract pre code entities from ```text``` markdown syntax and update all entity offsets
      // The math scan already honors code precedence; TeX itself now shields code-like syntax.
      entities = extractPreFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      // Extract inline code entities from `text` markdown syntax and update all entity offsets
      // NOTE: This must come SECOND to avoid interference with pre code blocks
      entities = extractInlineCodeFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      // Extract markdown links after code so code spans shield their contents from link parsing.
      entities = extractLinksFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      entities = extractAdditionalStylesFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      // Extract bold entities from **text** markdown syntax and update all entity offsets
      // NOTE: Only extract if not within code blocks
      entities = extractBoldFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      // Extract italic entities from _text_ markdown syntax and update all entity offsets
      // NOTE: Only extract if not within code blocks
      entities = extractItalicFromMarkdown(text: &text, existingEntities: entities, opaqueRanges: &opaqueMathRanges)

      if let threadLinkSpaceId, threadLinkSpaceId >= 0 {
        entities = extractThreadTitleLinks(text: &text, spaceId: threadLinkSpaceId, existingEntities: entities, opaqueRanges: opaqueMathRanges)
      }
    }

    // Explicit styles and typed Markdown can describe the same visible span after remapping.
    var seenStyles = Set<MessageEntity>()
    entities.removeAll { entity in
      switch entity.type {
        case .bold, .italic, .underline, .strikethrough, .highlight:
          return !seenStyles.insert(entity).inserted
        default:
          return false
      }
    }

    if parseMarkdown {
      let visibleText = text as NSString
      entities.removeAll { entity in
        guard entity.type == .botCommand else { return false }
        guard let range = validatedRange(of: entity, in: visibleText) else { return true }
        return !isBotCommandText(visibleText.substring(with: range))
      }
    }

    // Detect whole URLs before email/phone substrings inside their paths or queries.
    entities = extractMissingURLEntities(text: text, existingEntities: entities, opaqueRanges: opaqueMathRanges)
    entities = extractBotCommandEntities(text: text, existingEntities: entities, opaqueRanges: opaqueMathRanges)
    entities = extractEmailEntities(text: text, existingEntities: entities, opaqueRanges: opaqueMathRanges)
    entities = extractPhoneNumberEntities(text: text, existingEntities: entities, opaqueRanges: opaqueMathRanges)

    // Sort entities by offset
    entities.sort { $0.offset < $1.offset }

    var messageEntities = MessageEntities()
    messageEntities.entities = entities

    return (text: text, entities: messageEntities)
  }

  /// Paste/send must not depend on a platform data detector running after a delimiter.
  private static func extractMissingURLEntities(
    text: String,
    existingEntities: [MessageEntity],
    opaqueRanges: [NSRange]
  ) -> [MessageEntity] {
    let protected = existingEntities.filter { entity in
      switch entity.type {
      case .bold, .italic, .underline, .strikethrough, .highlight: false
      default: true
      }
    }
    let source = NSAttributedString(string: text)
    let detected = ComposeLinkPaste.links(in: source, range: NSRange(location: 0, length: source.length))
      .compactMap { match -> MessageEntity? in
      guard !protected.contains(where: { rangesOverlap(lhs: $0, rhs: match.range) }),
            !opaqueRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
      else { return nil }
      return MessageEntity.with {
        $0.type = .url
        $0.offset = Int64(match.range.location)
        $0.length = Int64(match.range.length)
      }
    }
    return existingEntities + detected
  }

  private static func trimmedEntityRange(in text: NSString, range: NSRange) -> NSRange? {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length > 0,
          NSMaxRange(range) <= text.length
    else {
      return nil
    }

    var start = range.location
    var end = NSMaxRange(range)

    while start < end, isEntityWhitespace(text.character(at: start)) {
      start += 1
    }

    while end > start, isEntityWhitespace(text.character(at: end - 1)) {
      end -= 1
    }

    guard end > start else { return nil }
    return NSRange(location: start, length: end - start)
  }

  private static func isEntityWhitespace(_ character: unichar) -> Bool {
    guard let scalar = UnicodeScalar(character) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
  }

  private static func isAllowedExternalLink(_ urlString: String) -> Bool {
    LinkDetector.isSupportedLinkURLString(urlString)
  }

  private static func inlineMentionTarget(from urlString: String) -> (userId: Int64, agentId: Int64?)? {
    guard let components = URLComponents(string: urlString),
          components.scheme?.lowercased() == "inline",
          components.host?.lowercased() == "user"
    else { return nil }

    let queryId = components.queryItems?.first {
      let name = $0.name.lowercased()
      return name == "id" || name == "user_id"
    }?.value
    let pathId = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let userId = positiveInt64(queryId) ?? positiveInt64(pathId) else { return nil }
    let agentId = positiveInt64(queryValue(in: components, names: ["agent_id"]))
    return (userId, agentId)
  }

  private static func inlineMentionURL(userId: Int64, agentId: Int64?) -> String {
    guard let agentId else { return "inline://user/\(userId)" }
    return "inline://user?id=\(userId)&agent_id=\(agentId)"
  }

  private static func inlineThreadLink(from urlString: String, visibleText: String? = nil) -> ThreadLinkTarget? {
    guard let components = URLComponents(string: urlString),
          components.scheme?.lowercased() == "inline",
          let host = components.host?.lowercased(),
          host == "chat" || host == "thread"
    else { return nil }

    let queryChatId = positiveInt64(queryValue(in: components, names: ["id", "chat_id"]))
    let pathChatId = positiveInt64(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    if let chatId = queryChatId ?? pathChatId {
      return .chatId(chatId)
    }

    guard host == "thread" else { return nil }
    guard let spaceId = nonNegativeInt64(queryValue(in: components, names: ["space_id"])) else {
      return nil
    }

    let explicitTitle = trimmedTitle(queryValue(in: components, names: ["title"]))
    let labelTitle = visibleText.flatMap { strippedInlineMarkdownTitle($0) }
    guard let title = explicitTitle ?? labelTitle else {
      return nil
    }

    return .title(spaceId: spaceId, title: title)
  }

  private static func queryValue(in components: URLComponents, names: Set<String>) -> String? {
    components.queryItems?.first { names.contains($0.name.lowercased()) }?.value
  }

  private static func trimmedTitle(_ value: String?) -> String? {
    let title = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return title?.isEmpty == false ? title : nil
  }

  private static func strippedInlineMarkdownTitle(_ value: String) -> String? {
    var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements: [(String, String)] = [
      ("`([^`\\n]+)`", "$1"),
      ("\\*\\*([^\\n]+?)\\*\\*", "$1"),
      ("__([^\\n]+?)__", "$1"),
      ("(^|\\s)_([^_\\n]+?)_(?=\\s|$)", "$1$2"),
    ]

    for replacement in replacements {
      guard let regex = try? NSRegularExpression(pattern: replacement.0) else { continue }
      let range = NSRange(location: 0, length: (title as NSString).length)
      title = regex.stringByReplacingMatches(in: title, range: range, withTemplate: replacement.1)
    }

    return trimmedTitle(title)
  }

  private static func positiveInt64(_ value: String?) -> Int64? {
    guard let value, !value.isEmpty, value.allSatisfy(\.isNumber), let id = Int64(value), id > 0 else {
      return nil
    }
    return id
  }

  private static func nonNegativeInt64(_ value: String?) -> Int64? {
    guard let value, !value.isEmpty, value.allSatisfy(\.isNumber), let id = Int64(value), id >= 0 else {
      return nil
    }
    return id
  }

  private static func threadEntity(target: ThreadLinkTarget, offset: Int64, length: Int64) -> MessageEntity? {
    var entity = MessageEntity()
    entity.offset = offset
    entity.length = length

    switch target {
      case let .chatId(chatId):
        guard chatId > 0 else { return nil }
        entity.type = .thread
        entity.thread = MessageEntity.MessageEntityThread.with {
          $0.chatID = chatId
        }
      case let .title(spaceId, title):
        guard spaceId >= 0, !title.isEmpty else { return nil }
        entity.type = .threadTitle
        entity.threadTitle = MessageEntity.MessageEntityThreadTitle.with {
          $0.spaceID = spaceId
          $0.title = title
        }
    }

    return entity
  }

  private static func emailAddress(from urlString: String) -> String? {
    guard urlString.lowercased().hasPrefix("mailto:") else { return nil }
    let startIndex = urlString.index(urlString.startIndex, offsetBy: "mailto:".count)
    let remainder = String(urlString[startIndex...])
    let address = remainder.split(separator: "?").first.map(String.init)
    return address?.isEmpty == false ? address : nil
  }

  private static func phoneNumber(from urlString: String) -> String? {
    if urlString.lowercased().hasPrefix("tel:") {
      let startIndex = urlString.index(urlString.startIndex, offsetBy: "tel:".count)
      let remainder = String(urlString[startIndex...])
      let number = remainder.split(separator: "?").first.map(String.init)
      guard let number, !number.isEmpty else { return nil }
      return isValidPhoneNumberCandidate(number) ? number : nil
    }

    return isValidPhoneNumberCandidate(urlString) ? urlString : nil
  }

  private static func isValidPhoneNumberCandidate(_ phoneNumber: String) -> Bool {
    let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
      return false
    }

    let allowedCharacters = CharacterSet(charactersIn: "+-()0123456789")
    if trimmed.rangeOfCharacter(from: allowedCharacters.inverted) != nil {
      return false
    }

    let hasLeadingPlus = trimmed.first == "+"
    if hasLeadingPlus, trimmed.dropFirst().contains("+") {
      return false
    }
    if !hasLeadingPlus, trimmed.contains("+") {
      return false
    }

    var parenDepth = 0
    for character in trimmed {
      if character == "(" {
        parenDepth += 1
      } else if character == ")" {
        parenDepth -= 1
        if parenDepth < 0 {
          return false
        }
      }
    }
    if parenDepth != 0 {
      return false
    }

    let digits = trimmed.filter { $0.isNumber }
    guard digits.count >= 7, digits.count <= 15 else { return false }

    let hasStrongIndicator = trimmed.contains("+") || trimmed.contains("(") || trimmed.contains(")")
    if digits.count < 10 && !hasStrongIndicator {
      return false
    }

    return true
  }

  // MARK: - Helper Methods

  // MARK: - Constants

  /// Common monospace font family names for detection
  private static let monospacePatterns = ["Monaco", "Menlo", "Courier", "SF Mono", "Consolas"]

  /// Thread-safe cache for monospace font detection results
  private static let monospaceFontCacheLock = NSLock()
  private nonisolated(unsafe) static var _monospaceFontCache: [String: Bool] = [:]

  // MARK: - Regex Patterns

  /// Regex pattern for pre code blocks with optional language specification
  /// Matches: ```[language]\n[content]``` or ```[content]```
  /// Examples: "```swift\nlet x = 1```", "```hello world```"
  private static let preBlockPattern = "(?<!`)(`{3}|`{4,}(?=(?:[a-zA-Z0-9+#-]+)?\\n))(?!`)(?:([a-zA-Z0-9+#-]+)\\n)?([\\s\\S]*?)(?<!`)\\1(?!`)"

  /// Regex pattern for inline code blocks
  /// Matches: `[content]`
  private static let inlineCodePattern = "(?<!`)(`+)(?!`)([\\s\\S]*?)(?<!`)\\1(?!`)"

  /// Regex pattern for bold text
  /// Matches: **[content]**
  private static let boldTextPattern = "\\*\\*(.*?)\\*\\*"

  /// Regex pattern for italic text
  /// Matches: _[content]_ only when surrounded by whitespace or string boundaries
  private static let italicTextPattern = "(^|\\s)_(.+?)_(\\s|$)"

  private static func getCachedMonospaceResult(for fontName: String) -> Bool? {
    monospaceFontCacheLock.lock()
    defer { monospaceFontCacheLock.unlock() }
    return _monospaceFontCache[fontName]
  }

  private static func setCachedMonospaceResult(for fontName: String, result: Bool) {
    monospaceFontCacheLock.lock()
    defer { monospaceFontCacheLock.unlock() }
    _monospaceFontCache[fontName] = result
  }

  // MARK: - Monospace Detection Utilities

  /// Checks if a font is monospace using platform-specific detection and font name patterns
  public static func isMonospaceFont(_ font: PlatformFont) -> Bool {
    let fontName = font.fontName

    // Check cache first for performance
    if let cached = getCachedMonospaceResult(for: fontName) {
      return cached
    }

    var isMonospace = false

    #if os(macOS)
    isMonospace = font.isFixedPitch || monospacePatterns.contains { fontName.contains($0) }
    #else
    isMonospace = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ||
      monospacePatterns.contains { fontName.contains($0) }
    #endif

    // Cache the result for performance
    setCachedMonospaceResult(for: fontName, result: isMonospace)
    return isMonospace
  }

  /// Determines if cursor is within a code block based on attributes and font
  public static func isCursorInCodeBlock(
    attributes: [NSAttributedString.Key: Any]
  ) -> Bool {
    // Check for explicit preCode or inlineCode attributes
    let hasPreCode = attributes[.preCode] != nil
    let hasInlineCode = attributes[.inlineCode] != nil

    if hasPreCode || hasInlineCode {
      return true
    }

    // Check for monospace font
    if let font = attributes[.font] as? PlatformFont {
      return isMonospaceFont(font)
    }

    return false
  }

  /// Sorts message entities by their offset position
  public static func sortEntities(_ entities: [MessageEntity]) -> [MessageEntity] {
    entities.sorted { $0.offset < $1.offset }
  }

  /// Sorts message entities in place by their offset position
  public static func sortEntities(_ entities: inout [MessageEntity]) {
    entities.sort { $0.offset < $1.offset }
  }

  /// Code and TeX source must remain opaque to Markdown and semantic detectors.
  private static func isPositionWithinCodeBlock(position: Int, entities: [MessageEntity]) -> Bool {
    for entity in entities {
      if entity.type == .code || entity.type == .pre || entity.type == .math {
        let start = Int(entity.offset)
        let end = start + Int(entity.length)
        if position >= start, position < end {
          return true
        }
      }
    }
    return false
  }

  /// Recognition uses a mask, but extraction always slices the original text.
  /// Keeping UTF-16 length and line endings preserves source ranges and prevents
  /// markers inside TeX or literal HTML tokens from closing outer formatting.
  private static func markdownSyntaxMask(_ text: String, entities: [MessageEntity], opaqueRanges: [NSRange]) -> String {
    let nsText = text as NSString
    let protected = entities.filter { $0.type == .code || $0.type == .pre || $0.type == .math }
      .compactMap { validatedRange(of: $0, in: nsText) } + opaqueRanges
    let ranges = entities.filter { $0.type == .math }.compactMap { validatedRange(of: $0, in: nsText) } + opaqueRanges
      + InlineMathMarkdown.literalHTMLRanges(in: text, protectedRanges: protected)
    guard !ranges.isEmpty else { return text }
    let masked = NSMutableString(string: text)
    for range in ranges {
      let units = nsText.substring(with: range).utf16.map { unit in
        unit == 10 || unit == 13 ? unit : UInt16(120)
      }
      masked.replaceCharacters(in: range, with: String(decoding: units, as: UTF16.self))
    }
    return masked as String
  }

  private struct OffsetRemoval {
    let position: Int
    let length: Int
  }

  private struct OffsetAdjustment {
    let position: Int
    let delta: Int
    let includeAtPosition: Bool
  }

  private static let emailRegex: NSRegularExpression = {
    let pattern = "\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }()

  private static let phoneNumberRegex: NSRegularExpression = {
    let pattern = "(?<!\\w)(\\+?[0-9(][0-9()\\-]{5,}[0-9])(?!\\w)"
    return try! NSRegularExpression(pattern: pattern, options: [])
  }()

  private static func extractBotCommandEntities(
    text: String,
    existingEntities: [MessageEntity],
    opaqueRanges: [NSRange]
  ) -> [MessageEntity] {
    guard !text.isEmpty else { return existingEntities }

    var entities = existingEntities
    let nsText = text as NSString
    var index = 0

    while index < nsText.length {
      guard let commandRange = botCommandRange(in: nsText, at: index) else {
        index += 1
        continue
      }

      if !isPositionWithinCodeBlock(position: commandRange.location, entities: entities),
         !opaqueRanges.contains(where: { NSIntersectionRange($0, commandRange).length > 0 }),
         !entities.contains(where: { rangesOverlap(lhs: $0, rhs: commandRange) })
      {
        var entity = MessageEntity()
        entity.type = .botCommand
        entity.offset = Int64(commandRange.location)
        entity.length = Int64(commandRange.length)
        entities.append(entity)
      }

      index = max(index + 1, NSMaxRange(commandRange))
    }

    return entities
  }

  private static func isBotCommandText(_ text: String) -> Bool {
    let nsText = text as NSString
    guard let commandRange = botCommandRange(in: nsText, at: 0) else {
      return false
    }

    return commandRange.location == 0 && commandRange.length == nsText.length
  }

  private static func botCommandRange(in nsText: NSString, at index: Int) -> NSRange? {
    guard index >= 0, index < nsText.length, nsText.character(at: index) == 47 else {
      return nil
    }

    if index > 0, !isBotCommandBoundary(nsText.character(at: index - 1)) {
      return nil
    }

    var cursor = index + 1
    while cursor < nsText.length, isBotCommandIdentifierCharacter(nsText.character(at: cursor)) {
      cursor += 1
    }

    let commandLength = cursor - index - 1
    guard commandLength >= 1, commandLength <= 32 else {
      return nil
    }

    if cursor < nsText.length, nsText.character(at: cursor) == 64 {
      let suffixStart = cursor
      cursor += 1

      while cursor < nsText.length, isBotCommandIdentifierCharacter(nsText.character(at: cursor)) {
        cursor += 1
      }

      if cursor == suffixStart + 1 {
        cursor = suffixStart
      }
    }

    if cursor < nsText.length, nsText.character(at: cursor) == 47 {
      return nil
    }

    return NSRange(location: index, length: cursor - index)
  }

  private static func isBotCommandIdentifierCharacter(_ character: unichar) -> Bool {
    (character >= 48 && character <= 57)
      || (character >= 65 && character <= 90)
      || (character >= 97 && character <= 122)
      || character == 95
  }

  private static func isBotCommandBoundary(_ character: unichar) -> Bool {
    character == 32 || character == 9 || character == 10 || character == 13
  }

  private static func extractEmailEntities(
    text: String,
    existingEntities: [MessageEntity],
    opaqueRanges: [NSRange]
  ) -> [MessageEntity] {
    guard !text.isEmpty else { return existingEntities }

    var entities = existingEntities
    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = emailRegex.matches(in: text, options: [], range: range)

    for match in matches {
      guard match.range.length > 0 else { continue }

      if isPositionWithinCodeBlock(position: match.range.location, entities: entities)
        || opaqueRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
        continue
      }

      if entities.contains(where: { rangesOverlap(lhs: $0, rhs: match.range) }) {
        continue
      }

      var entity = MessageEntity()
      entity.type = .email
      entity.offset = Int64(match.range.location)
      entity.length = Int64(match.range.length)
      entities.append(entity)
    }

    return entities
  }

  private static func extractPhoneNumberEntities(
    text: String,
    existingEntities: [MessageEntity],
    opaqueRanges: [NSRange]
  ) -> [MessageEntity] {
    guard !text.isEmpty else { return existingEntities }

    var entities = existingEntities
    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = phoneNumberRegex.matches(in: text, options: [], range: range)
    let nsText = text as NSString

    for match in matches {
      guard match.range.length > 0 else { continue }

      if isPositionWithinCodeBlock(position: match.range.location, entities: entities)
        || opaqueRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
        continue
      }

      if entities.contains(where: { rangesOverlap(lhs: $0, rhs: match.range) }) {
        continue
      }

      let rawPhoneNumber = nsText.substring(with: match.range)
      guard isValidPhoneNumberCandidate(rawPhoneNumber) else { continue }

      var entity = MessageEntity()
      entity.type = .phoneNumber
      entity.offset = Int64(match.range.location)
      entity.length = Int64(match.range.length)
      entities.append(entity)
    }

    return entities
  }

  private static func rangesOverlap(lhs: MessageEntity, rhs: NSRange) -> Bool {
    let start = Int(lhs.offset)
    let end = start + Int(lhs.length)
    let lhsRange = NSRange(location: start, length: end - start)
    return NSIntersectionRange(lhsRange, rhs).length > 0
  }

  private static func blocksThreadTitleLinkExtraction(entity: MessageEntity, range: NSRange) -> Bool {
    guard rangesOverlap(lhs: entity, rhs: range) else { return false }

    switch entity.type {
      case .bold, .italic, .underline, .strikethrough, .highlight:
        return false
      default:
        return true
    }
  }

  private static func totalRemovedCharacters(before offset: Int, removals: [OffsetRemoval]) -> Int {
    var total = 0
    for removal in removals {
      if offset > removal.position {
        total += removal.length
      }
    }
    return total
  }

  private static func applyOffsetRemovals(_ entities: inout [MessageEntity], removals: [OffsetRemoval]) {
    guard !removals.isEmpty else { return }

    for i in 0 ..< entities.count {
      let entityOffset = Int(entities[i].offset)
      let entityLength = Int(entities[i].length)
      let entityRange = NSRange(location: entityOffset, length: entityLength)
      let offsetAdjustment = totalRemovedCharacters(before: entityOffset, removals: removals)
      let lengthAdjustment = totalRemovedCharacters(in: entityRange, removals: removals)
      entities[i].offset = Int64(max(0, entityOffset - offsetAdjustment))
      entities[i].length = Int64(max(0, entityLength - lengthAdjustment))
    }
  }

  private static func applyOffsetRemovals(_ ranges: inout [NSRange], removals: [OffsetRemoval]) {
    guard !removals.isEmpty else { return }
    ranges = ranges.map { range in
      NSRange(
        location: range.location - totalRemovedCharacters(before: range.location, removals: removals),
        length: range.length - totalRemovedCharacters(in: range, removals: removals)
      )
    }.filter { $0.length > 0 }
  }

  private static func totalRemovedCharacters(in range: NSRange, removals: [OffsetRemoval]) -> Int {
    guard range.length > 0 else { return 0 }

    var total = 0
    for removal in removals {
      let removalRange = NSRange(location: removal.position, length: removal.length)
      total += NSIntersectionRange(range, removalRange).length
    }
    return total
  }

  private static func totalOffsetAdjustment(before offset: Int, adjustments: [OffsetAdjustment]) -> Int {
    var total = 0
    for adjustment in adjustments {
      if adjustment.includeAtPosition {
        if offset >= adjustment.position {
          total += adjustment.delta
        }
      } else if offset > adjustment.position {
        total += adjustment.delta
      }
    }
    return total
  }

  private static func applyOffsetAdjustments(_ entities: inout [MessageEntity], adjustments: [OffsetAdjustment]) {
    guard !adjustments.isEmpty else { return }

    for i in 0 ..< entities.count {
      let entityOffset = Int(entities[i].offset)
      let adjustment = totalOffsetAdjustment(before: entityOffset, adjustments: adjustments)
      entities[i].offset = Int64(max(0, entityOffset + adjustment))
    }
  }

  private static func applyOffsetAdjustments(_ ranges: inout [NSRange], adjustments: [OffsetAdjustment]) {
    guard !adjustments.isEmpty else { return }
    // Code extraction cannot rewrite an opaque formula; only its preceding text changes.
    ranges = ranges.map { range in
      NSRange(
        location: range.location + totalOffsetAdjustment(before: range.location, adjustments: adjustments),
        length: range.length
      )
    }
  }

  private static func isLineBreakCharacter(_ character: unichar) -> Bool {
    character == 10 || character == 13
  }

  private static func isInlineWhitespaceCharacter(_ character: unichar) -> Bool {
    character == 32 || character == 9
  }

  private static func createBoldFont(
    from font: PlatformFont,
    preferredWeight: PlatformFontWeight?
  ) -> PlatformFont {
    PlatformFontTraits.settingBold(true, on: font, preferredWeight: preferredWeight)
  }

  private static func createMonospaceFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    // Provide robust fallback chain to guarantee a non-nil font
    let safeSize = max(font.pointSize, 12.0)
    if let mono = NSFont.monospacedSystemFont(ofSize: safeSize, weight: .regular) as PlatformFont? {
      return mono
    }
    if let userFixed = NSFont.userFixedPitchFont(ofSize: safeSize) as PlatformFont? {
      return userFixed
    }
    return NSFont.systemFont(ofSize: safeSize)
    #else
    let safeSize = max(font.pointSize, 12.0)
    return UIFont.monospacedSystemFont(ofSize: safeSize, weight: .regular)
    #endif
  }

  private static func createItalicFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    // NSFontManager.convert may return nil depending on the source font/traits. Provide safe fallbacks.
    if let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) as PlatformFont?,
       NSFontManager.shared.traits(of: converted).contains(.italicFontMask)
    {
      return converted
    }
    // Fallback: try to create italic using font descriptor
    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
    if let italicFont = NSFont(descriptor: descriptor, size: font.pointSize) {
      return italicFont
    }
    // Safe fallbacks with valid point size
    let safeSize = max(font.pointSize, 12.0)
    return NSFont.systemFont(ofSize: safeSize)
    #else
    let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
      return UIFont(descriptor: descriptor, size: font.pointSize)
    }
    let safeSize = max(font.pointSize, 12.0)
    return UIFont.italicSystemFont(ofSize: safeSize)
    #endif
  }

  /// Extract typed math before Markdown, with code precedence and literal oversized fallback.
  private static func extractMathFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    guard text.contains("$") else { return existingEntities }
    let nsText = text as NSString
    let protected = existingEntities.filter { $0.type == .code || $0.type == .pre || $0.type == .math }
      .compactMap { validatedRange(of: $0, in: nsText) }
    let matches = InlineMathMarkdown.matches(in: text, protectedRanges: protected)
    guard !matches.isEmpty else { return existingEntities }
    let supported = matches.filter(\.isSupported)
    opaqueRanges = matches.filter { !$0.isSupported }.map(\.range)
    let removals = supported.flatMap { match in
      [
        OffsetRemoval(position: match.range.location, length: match.content.location - match.range.location),
        OffsetRemoval(position: NSMaxRange(match.content), length: NSMaxRange(match.range) - NSMaxRange(match.content)),
      ]
    }
    let preserved = existingEntities.filter { entity in
      switch entity.type {
        case .bold, .italic, .underline, .strikethrough, .highlight:
          // Outer formatting may wrap a formula; its interior is opaque TeX.
          return matches.allSatisfy { match in
            !rangesOverlap(lhs: entity, rhs: match.range)
              || (entity.offset <= Int64(match.range.location)
                && entity.offset + entity.length >= Int64(NSMaxRange(match.range)))
          }
        default: return !matches.contains { rangesOverlap(lhs: entity, rhs: $0.range) }
      }
    }
    var entities = preserved + supported.map { match in
      MessageEntity.with {
        $0.type = .math
        $0.offset = Int64(match.content.location)
        $0.length = Int64(match.content.length)
        if match.blockDisplay { $0.math = .with { $0.display = true } }
      }
    }
    let output = NSMutableString(string: text)
    for removal in removals.sorted(by: { $0.position > $1.position }) {
      output.deleteCharacters(in: NSRange(location: removal.position, length: removal.length))
    }
    text = output as String
    applyOffsetRemovals(&entities, removals: removals)
    applyOffsetRemovals(&opaqueRanges, removals: removals)
    return entities.filter { $0.length > 0 }
  }

  /// Remove only complete additive style markers and remap explicit entities through the removals.
  private static func extractAdditionalStylesFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    let nsText = text as NSString
    let codeRanges = existingEntities.filter { $0.type == .code || $0.type == .pre }
      .compactMap { validatedRange(of: $0, in: nsText) }
    let matches = InlineStyleMarkdown.matches(in: markdownSyntaxMask(text, entities: existingEntities, opaqueRanges: opaqueRanges), codeRanges: codeRanges)
    guard !matches.isEmpty else { return existingEntities }
    let removals = matches.flatMap { [$0.opening, $0.closing] }
      .map { OffsetRemoval(position: $0.location, length: $0.length) }
    var entities = existingEntities + matches.map { match in
      MessageEntity.with {
        $0.type = match.entityType
        $0.offset = Int64(match.content.location)
        $0.length = Int64(match.content.length)
      }
    }
    let output = NSMutableString(string: text)
    for removal in removals.sorted(by: { $0.position > $1.position }) {
      output.deleteCharacters(in: NSRange(location: removal.position, length: removal.length))
    }
    text = output as String
    applyOffsetRemovals(&entities, removals: removals)
    applyOffsetRemovals(&opaqueRanges, removals: removals)
    return entities.filter { $0.length > 0 }
  }

  /// Extract bold entities from **text** markdown syntax
  private static func extractBoldFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var boldEntities: [MessageEntity] = []

    do {
      let regex = try NSRegularExpression(pattern: boldTextPattern, options: [])
      let nsText = text as NSString
      let matches = regex.matches(in: markdownSyntaxMask(text, entities: existingEntities, opaqueRanges: opaqueRanges), options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing ** markers
      var removals: [OffsetRemoval] = []

      for match in matches.reversed() {
        // Get the full match range (including **)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range (excluding **)
        if match.numberOfRanges > 1 {
          let contentRange = match.range(at: 1)

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Convert NSRange to Range<String.Index> safely
            guard let swiftFullRange = Range(fullRange, in: text),
                  let swiftContentRange = Range(contentRange, in: text)
            else {
              continue // Skip this match if range conversion fails
            }

            // Extract content text
            let contentText = String(text[swiftContentRange])

            // Replace the full match with just the content
            text.replaceSubrange(swiftFullRange, with: contentText)

            let openMarkerLength = 2
            let closeMarkerLength = 2
            let closeMarkerPosition = fullRange.location + fullRange.length - closeMarkerLength
            removals.append(OffsetRemoval(position: fullRange.location, length: openMarkerLength))
            removals.append(OffsetRemoval(position: closeMarkerPosition, length: closeMarkerLength))

            // Store the entity position in pre-removal coordinates; map after applying removals.
            var boldEntity = MessageEntity()
            boldEntity.type = .bold
            boldEntity.offset = Int64(contentRange.location)
            boldEntity.length = Int64(contentRange.length)
            boldEntities.append(boldEntity)
          }
        }
      }

      applyOffsetRemovals(&allEntities, removals: removals)
      applyOffsetRemovals(&opaqueRanges, removals: removals)
      applyOffsetRemovals(&boldEntities, removals: removals)

      // Add bold entities to the list
      allEntities.append(contentsOf: boldEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }

  private static func extractInlineCodeFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var inlineCodeEntities: [MessageEntity] = []

    do {
      let regex = try NSRegularExpression(pattern: inlineCodePattern, options: [])
      let nsText = text as NSString
      let matches = regex.matches(in: markdownSyntaxMask(text, entities: existingEntities, opaqueRanges: opaqueRanges), options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing ` markers
      var removals: [OffsetRemoval] = []

      for match in matches.reversed() {
        // Get the full match range (including `)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block (prevents nested code blocks)
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range (excluding `)
        if match.numberOfRanges > 2 {
          var contentRange = match.range(at: 2)
          let rawContent = nsText.substring(with: contentRange)
          // Padding separates a backtick at either edge from its longer delimiter.
          if rawContent.hasPrefix(" "), rawContent.hasSuffix(" "),
             rawContent.contains(where: { $0 != " " }) {
            contentRange.location += 1
            contentRange.length -= 2
          }

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Convert NSRange to Range<String.Index> safely
            guard let swiftFullRange = Range(fullRange, in: text),
                  let swiftContentRange = Range(contentRange, in: text)
            else {
              continue // Skip this match if range conversion fails
            }

            // Extract content text
            let contentText = String(text[swiftContentRange])

            // Replace the full match with just the content
            text.replaceSubrange(swiftFullRange, with: contentText)

            let openMarkerLength = contentRange.location - fullRange.location
            let closeMarkerLength = NSMaxRange(fullRange) - NSMaxRange(contentRange)
            let closeMarkerPosition = fullRange.location + fullRange.length - closeMarkerLength
            removals.append(OffsetRemoval(position: fullRange.location, length: openMarkerLength))
            removals.append(OffsetRemoval(position: closeMarkerPosition, length: closeMarkerLength))

            // Store the entity position in pre-removal coordinates; map after applying removals.
            var inlineCodeEntity = MessageEntity()
            inlineCodeEntity.type = .code
            inlineCodeEntity.offset = Int64(contentRange.location)
            inlineCodeEntity.length = Int64(contentRange.length)
            inlineCodeEntities.append(inlineCodeEntity)
          }
        }
      }

      applyOffsetRemovals(&allEntities, removals: removals)
      applyOffsetRemovals(&opaqueRanges, removals: removals)
      applyOffsetRemovals(&inlineCodeEntities, removals: removals)

      // Add inline code entities to the list
      allEntities.append(contentsOf: inlineCodeEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }

  private struct MarkdownLinkMatch {
    let fullRange: NSRange
    let textRange: NSRange
    let url: String
  }

  static func markdownLinkRanges(in text: String) -> [NSRange] {
    guard text.contains("](") else { return [] }
    return findMarkdownLinkMatches(in: text).map(\.fullRange)
  }

  private struct ThreadTitleLinkMatch {
    let fullRange: NSRange
    let titleRange: NSRange
    let title: String
  }

  private static func findMarkdownLinkMatches(in text: String) -> [MarkdownLinkMatch] {
    let nsText = text as NSString
    var matches: [MarkdownLinkMatch] = []
    var cursor = 0

    while cursor < nsText.length {
      guard nsText.character(at: cursor) == 91 else {
        cursor += 1
        continue
      }

      var textEnd = cursor + 1
      var bracketDepth = 1
      while textEnd < nsText.length {
        let character = nsText.character(at: textEnd)
        if character == 91 {
          bracketDepth += 1
        } else if character == 93 {
          bracketDepth -= 1
          if bracketDepth == 0 { break }
        }
        textEnd += 1
      }

      guard textEnd < nsText.length else {
        cursor += 1
        continue
      }

      let textRange = NSRange(location: cursor + 1, length: textEnd - cursor - 1)
      guard textRange.length > 0 else {
        cursor += 1
        continue
      }

      guard textEnd + 1 < nsText.length, nsText.character(at: textEnd + 1) == 40 else {
        cursor += 1
        continue
      }

      let urlStart = textEnd + 2
      var parenDepth = 1
      var urlEndCursor = urlStart

      while urlEndCursor < nsText.length, parenDepth > 0 {
        let character = nsText.character(at: urlEndCursor)
        if character == 40 {
          parenDepth += 1
        } else if character == 41 {
          parenDepth -= 1
        }
        urlEndCursor += 1
      }

      guard parenDepth == 0 else {
        cursor += 1
        continue
      }

      let urlRange = NSRange(location: urlStart, length: urlEndCursor - urlStart - 1)
      guard urlRange.length > 0 else {
        cursor += 1
        continue
      }

      let url = nsText.substring(with: urlRange)
      guard !url.isEmpty else {
        cursor += 1
        continue
      }

      matches.append(
        MarkdownLinkMatch(
          fullRange: NSRange(location: cursor, length: urlEndCursor - cursor),
          textRange: textRange,
          url: url
        )
      )

      cursor = urlEndCursor
    }

    return matches
  }

  private static func extractLinksFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var textUrlEntities: [MessageEntity] = []
    let matches = findMarkdownLinkMatches(in: markdownSyntaxMask(text, entities: existingEntities, opaqueRanges: opaqueRanges))

    guard !matches.isEmpty else { return allEntities }

    var removals: [OffsetRemoval] = []

    for match in matches.reversed() {
      if isPositionWithinCodeBlock(position: match.fullRange.location, entities: allEntities) {
        continue
      }

      // A math marker in a URL destination is source, never a masked URL payload.
      let syntaxRanges = [
        NSRange(location: match.fullRange.location, length: match.textRange.location - match.fullRange.location),
        NSRange(location: NSMaxRange(match.textRange), length: NSMaxRange(match.fullRange) - NSMaxRange(match.textRange)),
      ]
      let mathRanges = allEntities.filter { $0.type == .math }
        .compactMap { validatedRange(of: $0, in: text as NSString) } + opaqueRanges
      guard !syntaxRanges.contains(where: { syntax in mathRanges.contains { NSIntersectionRange(syntax, $0).length > 0 } })
      else {
        // Keep the unparsed destination intact during all subsequent style passes.
        opaqueRanges.append(contentsOf: syntaxRanges)
        continue
      }

      guard let swiftFullRange = Range(match.fullRange, in: text),
            let swiftTextRange = Range(match.textRange, in: text)
      else {
        continue
      }

      let linkText = String(text[swiftTextRange])
      text.replaceSubrange(swiftFullRange, with: linkText)

      let prefixLength = match.textRange.location - match.fullRange.location
      if prefixLength > 0 {
        removals.append(OffsetRemoval(position: match.fullRange.location, length: prefixLength))
      }

      let suffixStart = match.textRange.location + match.textRange.length
      let fullEnd = match.fullRange.location + match.fullRange.length
      let suffixLength = fullEnd - suffixStart
      if suffixLength > 0 {
        removals.append(OffsetRemoval(position: suffixStart, length: suffixLength))
      }

      if let target = inlineThreadLink(from: match.url, visibleText: linkText),
         let entity = threadEntity(
           target: target,
           offset: Int64(match.textRange.location),
           length: Int64(match.textRange.length)
         )
      {
        textUrlEntities.append(entity)
      } else {
        var entity = MessageEntity()
        entity.type = .textURL
        entity.offset = Int64(match.textRange.location)
        entity.length = Int64(match.textRange.length)
        entity.textURL = MessageEntity.MessageEntityTextUrl.with {
          $0.url = match.url
        }
        textUrlEntities.append(entity)
      }
    }

    applyOffsetRemovals(&allEntities, removals: removals)
    applyOffsetRemovals(&opaqueRanges, removals: removals)
    applyOffsetRemovals(&textUrlEntities, removals: removals)
    allEntities.append(contentsOf: textUrlEntities)
    return allEntities
  }

  private static func extractThreadTitleLinks(
    text: inout String,
    spaceId: Int64,
    existingEntities: [MessageEntity],
    opaqueRanges: [NSRange]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var threadEntities: [MessageEntity] = []
    let matches = findThreadTitleLinkMatches(in: text)

    guard !matches.isEmpty else { return allEntities }

    for match in matches.reversed() {
      if isPositionWithinCodeBlock(position: match.fullRange.location, entities: allEntities) {
        continue
      }

      if allEntities.contains(where: { blocksThreadTitleLinkExtraction(entity: $0, range: match.fullRange) }) {
        continue
      }

      if opaqueRanges.contains(where: { NSIntersectionRange($0, match.fullRange).length > 0 }) { continue }

      var entity = MessageEntity()
      entity.type = .threadTitle
      entity.offset = Int64(match.fullRange.location)
      entity.length = Int64(match.fullRange.length)
      entity.threadTitle = MessageEntity.MessageEntityThreadTitle.with {
        $0.spaceID = spaceId
        $0.title = match.title
      }
      threadEntities.append(entity)
    }

    allEntities.append(contentsOf: threadEntities)
    return allEntities
  }

  private static func findThreadTitleLinkMatches(in text: String) -> [ThreadTitleLinkMatch] {
    let nsText = text as NSString
    var matches: [ThreadTitleLinkMatch] = []
    var cursor = 0

    while cursor + 3 < nsText.length {
      guard nsText.character(at: cursor) == 91,
            nsText.character(at: cursor + 1) == 91
      else {
        cursor += 1
        continue
      }

      let titleStart = cursor + 2
      var titleEnd = titleStart
      var foundClose = false

      while titleEnd + 1 < nsText.length {
        let character = nsText.character(at: titleEnd)
        if isLineBreakCharacter(character) {
          break
        }
        if character == 93, nsText.character(at: titleEnd + 1) == 93 {
          foundClose = true
          break
        }
        titleEnd += 1
      }

      guard foundClose else {
        cursor += 2
        continue
      }

      let rawTitleRange = NSRange(location: titleStart, length: titleEnd - titleStart)
      guard let titleRange = trimmedRange(rawTitleRange, in: nsText), titleRange.length > 0 else {
        cursor = titleEnd + 2
        continue
      }

      let title = nsText.substring(with: titleRange)
      matches.append(
        ThreadTitleLinkMatch(
          fullRange: NSRange(location: cursor, length: titleEnd + 2 - cursor),
          titleRange: titleRange,
          title: title
        )
      )

      cursor = titleEnd + 2
    }

    return matches
  }

  private static func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange? {
    guard range.location != NSNotFound, range.length > 0 else { return nil }

    var start = range.location
    var end = range.location + range.length

    while start < end {
      let character = text.character(at: start)
      guard isInlineWhitespaceCharacter(character) else { break }
      start += 1
    }

    while end > start {
      let character = text.character(at: end - 1)
      guard isInlineWhitespaceCharacter(character) else { break }
      end -= 1
    }

    guard end > start else { return nil }
    return NSRange(location: start, length: end - start)
  }

  private static func extractPreFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var preEntities: [MessageEntity] = []

    do {
      let regex = try NSRegularExpression(pattern: preBlockPattern, options: [.dotMatchesLineSeparators])
      let nsText = text as NSString
      let matches = regex.matches(in: markdownSyntaxMask(text, entities: existingEntities, opaqueRanges: opaqueRanges), options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid index invalidation while editing the text.
      var adjustments: [OffsetAdjustment] = []

      for match in matches.reversed() {
        // Get the full match range (including ``` and language)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block (prevents nested code blocks)
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Group 1 is the fence, group 2 is the optional language, group 3 is the content.
        let contentRange: NSRange
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
          contentRange = match.range(at: 3)
        } else {
          continue // Skip if no valid content group found
        }

        if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
          // Convert NSRange to Range<String.Index> safely
          guard let swiftContentRange = Range(contentRange, in: text)
          else {
            continue // Skip this match if range conversion fails
          }

          // Extract content text and trim a single leading/trailing newline to avoid extra blank lines
          let rawContentText = String(text[swiftContentRange])
          var leadingTrimLength = 0
          if rawContentText.hasPrefix("\r\n") {
            leadingTrimLength = 2
          } else if rawContentText.hasPrefix("\n") {
            leadingTrimLength = 1
          }

          let leadingTrimmedText = leadingTrimLength > 0 ? String(rawContentText.dropFirst(leadingTrimLength)) : rawContentText
          var trailingTrimLength = 0
          if leadingTrimmedText.hasSuffix("\r\n") {
            trailingTrimLength = 2
          } else if leadingTrimmedText.hasSuffix("\n") {
            trailingTrimLength = 1
          }

          let adjustedContentLocation = contentRange.location + leadingTrimLength
          let adjustedContentLength = max(0, contentRange.length - leadingTrimLength - trailingTrimLength)
          let adjustedContentRange = NSRange(location: adjustedContentLocation, length: adjustedContentLength)
          let contentRangeEnd = adjustedContentRange.location + adjustedContentRange.length
          let contentText = adjustedContentLength > 0 ? nsText.substring(with: adjustedContentRange) : ""

          let fullRangeEnd = fullRange.location + fullRange.length
          let needsLeadingLineBreak = fullRange.location > 0 &&
            !isLineBreakCharacter(nsText.character(at: fullRange.location - 1))
          let needsTrailingLineBreak = fullRangeEnd < nsText.length &&
            !isLineBreakCharacter(nsText.character(at: fullRangeEnd))

          var replacementRange = fullRange
          if needsLeadingLineBreak, fullRange.location > 0 {
            let previousCharacter = nsText.character(at: fullRange.location - 1)
            if isInlineWhitespaceCharacter(previousCharacter) {
              replacementRange.location -= 1
              replacementRange.length += 1
              adjustments.append(
                OffsetAdjustment(position: fullRange.location - 1, delta: -1, includeAtPosition: false)
              )
            }
          }

          if needsTrailingLineBreak, fullRangeEnd < nsText.length {
            let nextCharacter = nsText.character(at: fullRangeEnd)
            if isInlineWhitespaceCharacter(nextCharacter) {
              replacementRange.length += 1
              adjustments.append(
                OffsetAdjustment(position: fullRangeEnd, delta: -1, includeAtPosition: false)
              )
            }
          }

          guard let swiftReplacementRange = Range(replacementRange, in: text) else {
            continue
          }

          var replacementText = contentText
          if needsLeadingLineBreak {
            replacementText = "\n" + replacementText
            adjustments.append(
              OffsetAdjustment(position: adjustedContentRange.location, delta: 1, includeAtPosition: true)
            )
          }
          if needsTrailingLineBreak {
            replacementText += "\n"
            adjustments.append(
              OffsetAdjustment(position: contentRangeEnd, delta: 1, includeAtPosition: true)
            )
          }

          // Replace the full match with normalized block content.
          text.replaceSubrange(swiftReplacementRange, with: replacementText)

          let prefixRemovedLength = adjustedContentRange.location - fullRange.location
          let suffixRemovedLength = fullRangeEnd - contentRangeEnd

          if prefixRemovedLength > 0 {
            adjustments.append(
              OffsetAdjustment(position: fullRange.location, delta: -prefixRemovedLength, includeAtPosition: false)
            )
          }
          if suffixRemovedLength > 0 {
            adjustments.append(
              OffsetAdjustment(position: contentRangeEnd, delta: -suffixRemovedLength, includeAtPosition: false)
            )
          }

          // Store the entity position in pre-removal coordinates; map after applying removals.
          var preEntity = MessageEntity()
          preEntity.type = .pre
          preEntity.offset = Int64(adjustedContentRange.location)
          preEntity.length = Int64(adjustedContentRange.length)
          preEntities.append(preEntity)
        }
      }

      applyOffsetAdjustments(&allEntities, adjustments: adjustments)
      applyOffsetAdjustments(&opaqueRanges, adjustments: adjustments)
      applyOffsetAdjustments(&preEntities, adjustments: adjustments)

      // Add pre entities to the list
      allEntities.append(contentsOf: preEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }

  private static func extractItalicFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity],
    opaqueRanges: inout [NSRange]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var italicEntities: [MessageEntity] = []
    do {
      let regex = try NSRegularExpression(
        pattern: italicTextPattern,
        options: []
      )
      let nsText = text as NSString
      let matches = regex.matches(in: markdownSyntaxMask(text, entities: existingEntities, opaqueRanges: opaqueRanges), options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing _ markers
      var removals: [OffsetRemoval] = []

      for match in matches.reversed() {
        // Get the full match range (including surrounding whitespace/boundaries and _)
        let fullRange = match.range(at: 0)

        // Skip if this match is within a code block
        if isPositionWithinCodeBlock(position: fullRange.location, entities: allEntities) {
          continue
        }

        // Get the content range (excluding _ and whitespace) - now in group 2
        if match.numberOfRanges > 2 {
          let contentRange = match.range(at: 2)
          let leadingWhitespace = match.range(at: 1) // First capture group (^|\\s)
          let trailingWhitespace = match.range(at: 3) // Third capture group (\\s|$)

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Convert NSRange to Range<String.Index> safely
            guard let swiftFullRange = Range(fullRange, in: text),
                  let swiftContentRange = Range(contentRange, in: text)
            else {
              continue // Skip this match if range conversion fails
            }

            // Extract content text
            let contentText = String(text[swiftContentRange])

            // Calculate the leading whitespace length
            let leadingLength = leadingWhitespace.location != NSNotFound ? leadingWhitespace.length : 0

            // Calculate the trailing whitespace length
            let trailingLength = trailingWhitespace.location != NSNotFound ? trailingWhitespace.length : 0

            // Create replacement text: leading whitespace + content + trailing whitespace
            let leadingText = leadingLength > 0 ? String(text[Range(leadingWhitespace, in: text)!]) : ""
            let trailingText = trailingLength > 0 ? String(text[Range(trailingWhitespace, in: text)!]) : ""
            let replacementText = leadingText + contentText + trailingText

            // Replace the full match with the replacement text
            text.replaceSubrange(swiftFullRange, with: replacementText)

            let openMarkerPosition = contentRange.location - 1
            let closeMarkerPosition = contentRange.location + contentRange.length
            removals.append(OffsetRemoval(position: openMarkerPosition, length: 1))
            removals.append(OffsetRemoval(position: closeMarkerPosition, length: 1))

            // Store the entity position in pre-removal coordinates; map after applying removals.
            var italicEntity = MessageEntity()
            italicEntity.type = .italic
            italicEntity.offset = Int64(contentRange.location)
            italicEntity.length = Int64(contentRange.length)
            italicEntities.append(italicEntity)
          }
        }
      }

      applyOffsetRemovals(&allEntities, removals: removals)
      applyOffsetRemovals(&opaqueRanges, removals: removals)
      applyOffsetRemovals(&italicEntities, removals: removals)

      // Add italic entities to the list
      allEntities.append(contentsOf: italicEntities)

    } catch {}

    return allEntities
  }
}
