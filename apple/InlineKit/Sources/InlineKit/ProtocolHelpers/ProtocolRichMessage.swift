import Foundation
import CryptoKit
import GRDB
import InlineProtocol
import Logger

public enum RichMessageEffectiveMediaRef: Equatable, Hashable, Sendable {
  case photo(Int64)
  case video(Int64)
  case document(Int64)
  case voice(Int64)
}

public extension InlineProtocol.RichMessage {
  var stableSignature: String {
    let data = (try? serializedData()) ?? Data(fallbackText.utf8)
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\(data.count):\(hex)"
  }

  var effectiveMediaRefs: [RichMessageEffectiveMediaRef] {
    var refs: [RichMessageEffectiveMediaRef] = []
    var seen = Set<RichMessageEffectiveMediaRef>()

    for block in blocks {
      block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
    }

    return refs
  }
}

private extension InlineProtocol.RichBlock {
  func collectEffectiveMediaRefs(
    into refs: inout [RichMessageEffectiveMediaRef],
    seen: inout Set<RichMessageEffectiveMediaRef>
  ) {
    switch block {
    case let .list(value):
      for item in value.items {
        for block in item.blocks {
          block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
        }
      }
    case let .listItem(value):
      for block in value.blocks {
        block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
      }
    case let .quote(value):
      for block in value.blocks {
        block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
      }
    case let .thinking(value):
      for block in value.blocks {
        block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
      }
    case let .details(value):
      for block in value.blocks {
        block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
      }
    case let .photo(value):
      if value.hasMedia {
        value.media.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
    case let .video(value):
      if value.hasMedia {
        value.media.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
    case let .document(value):
      if value.hasMedia {
        value.media.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
    case let .audio(value):
      if value.hasMedia {
        value.media.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
    case let .embed(value):
      if value.hasPoster {
        value.poster.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
    case let .embedPost(value):
      if value.hasAuthorPhoto {
        value.authorPhoto.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
      for block in value.blocks {
        block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
      }
    case let .linkPreview(value):
      if value.hasMedia {
        value.media.collectEffectiveMediaRef(into: &refs, seen: &seen)
      }
    case let .collage(value):
      for block in value.items {
        block.collectEffectiveMediaRefs(into: &refs, seen: &seen)
      }
    case .paragraph, .heading, .code, .divider, .table, .math, .map, .none:
      break
    }
  }
}

private extension InlineProtocol.RichMediaRef {
  func collectEffectiveMediaRef(
    into refs: inout [RichMessageEffectiveMediaRef],
    seen: inout Set<RichMessageEffectiveMediaRef>
  ) {
    let ref: RichMessageEffectiveMediaRef?
    switch media {
    case let .photoID(value) where value > 0:
      ref = .photo(value)
    case let .videoID(value) where value > 0:
      ref = .video(value)
    case let .documentID(value) where value > 0:
      ref = .document(value)
    case let .voiceID(value) where value > 0:
      ref = .voice(value)
    default:
      ref = nil
    }

    guard let ref else { return }
    if seen.insert(ref).inserted {
      refs.append(ref)
    }
  }
}

extension InlineProtocol.RichMessage: Codable {
  private enum CodingKeys: String, CodingKey {
    case blocks
    case direction
    case fallbackText
    case version
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    blocks = try container.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    if let direction = try container.decodeIfPresent(RichDirection.self, forKey: .direction) {
      self.direction = direction
    }
    fallbackText = try container.decodeIfPresent(String.self, forKey: .fallbackText) ?? ""
    version = try container.decodeIfPresent(Int32.self, forKey: .version) ?? 0
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(blocks, forKey: .blocks)
    try container.encodeIfPresent(hasDirection ? direction : nil, forKey: .direction)
    try container.encode(fallbackText, forKey: .fallbackText)
    try container.encode(version, forKey: .version)
  }
}

extension InlineProtocol.RichBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case blockID
    case direction
    case paragraph
    case heading
    case list
    case listItem
    case quote
    case code
    case divider
    case thinking
    case details
    case photo
    case video
    case document
    case audio
    case table
    case math
    case map
    case embed
    case embedPost
    case linkPreview
    case collage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    blockID = try container.decodeIfPresent(String.self, forKey: .blockID) ?? ""
    if let direction = try container.decodeIfPresent(RichDirection.self, forKey: .direction) {
      self.direction = direction
    }

    if let paragraph = try container.decodeIfPresent(RichParagraphBlock.self, forKey: .paragraph) {
      block = .paragraph(paragraph)
    } else if let heading = try container.decodeIfPresent(RichHeadingBlock.self, forKey: .heading) {
      block = .heading(heading)
    } else if let list = try container.decodeIfPresent(RichListBlock.self, forKey: .list) {
      block = .list(list)
    } else if let listItem = try container.decodeIfPresent(RichListItemBlock.self, forKey: .listItem) {
      block = .listItem(listItem)
    } else if let quote = try container.decodeIfPresent(RichQuoteBlock.self, forKey: .quote) {
      block = .quote(quote)
    } else if let code = try container.decodeIfPresent(RichCodeBlock.self, forKey: .code) {
      block = .code(code)
    } else if let divider = try container.decodeIfPresent(RichDividerBlock.self, forKey: .divider) {
      block = .divider(divider)
    } else if let thinking = try container.decodeIfPresent(RichThinkingBlock.self, forKey: .thinking) {
      block = .thinking(thinking)
    } else if let details = try container.decodeIfPresent(RichDetailsBlock.self, forKey: .details) {
      block = .details(details)
    } else if let photo = try container.decodeIfPresent(RichPhotoBlock.self, forKey: .photo) {
      block = .photo(photo)
    } else if let video = try container.decodeIfPresent(RichVideoBlock.self, forKey: .video) {
      block = .video(video)
    } else if let document = try container.decodeIfPresent(RichDocumentBlock.self, forKey: .document) {
      block = .document(document)
    } else if let audio = try container.decodeIfPresent(RichAudioBlock.self, forKey: .audio) {
      block = .audio(audio)
    } else if let table = try container.decodeIfPresent(RichTableBlock.self, forKey: .table) {
      block = .table(table)
    } else if let math = try container.decodeIfPresent(RichMathBlock.self, forKey: .math) {
      block = .math(math)
    } else if let map = try container.decodeIfPresent(RichMapBlock.self, forKey: .map) {
      block = .map(map)
    } else if let embed = try container.decodeIfPresent(RichEmbedBlock.self, forKey: .embed) {
      block = .embed(embed)
    } else if let embedPost = try container.decodeIfPresent(RichEmbedPostBlock.self, forKey: .embedPost) {
      block = .embedPost(embedPost)
    } else if let linkPreview = try container.decodeIfPresent(RichLinkPreviewBlock.self, forKey: .linkPreview) {
      block = .linkPreview(linkPreview)
    } else if let collage = try container.decodeIfPresent(RichCollageBlock.self, forKey: .collage) {
      block = .collage(collage)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(blockID, forKey: .blockID)
    try container.encodeIfPresent(hasDirection ? direction : nil, forKey: .direction)

    switch block {
    case let .paragraph(value):
      try container.encode(value, forKey: .paragraph)
    case let .heading(value):
      try container.encode(value, forKey: .heading)
    case let .list(value):
      try container.encode(value, forKey: .list)
    case let .listItem(value):
      try container.encode(value, forKey: .listItem)
    case let .quote(value):
      try container.encode(value, forKey: .quote)
    case let .code(value):
      try container.encode(value, forKey: .code)
    case let .divider(value):
      try container.encode(value, forKey: .divider)
    case let .thinking(value):
      try container.encode(value, forKey: .thinking)
    case let .details(value):
      try container.encode(value, forKey: .details)
    case let .photo(value):
      try container.encode(value, forKey: .photo)
    case let .video(value):
      try container.encode(value, forKey: .video)
    case let .document(value):
      try container.encode(value, forKey: .document)
    case let .audio(value):
      try container.encode(value, forKey: .audio)
    case let .table(value):
      try container.encode(value, forKey: .table)
    case let .math(value):
      try container.encode(value, forKey: .math)
    case let .map(value):
      try container.encode(value, forKey: .map)
    case let .embed(value):
      try container.encode(value, forKey: .embed)
    case let .embedPost(value):
      try container.encode(value, forKey: .embedPost)
    case let .linkPreview(value):
      try container.encode(value, forKey: .linkPreview)
    case let .collage(value):
      try container.encode(value, forKey: .collage)
    case nil:
      break
    }
  }
}

extension InlineProtocol.RichText: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
    case children
    case styles
    case url
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    children = try container.decodeIfPresent([RichText].self, forKey: .children) ?? []
    styles = try container.decodeIfPresent([RichTextStyle].self, forKey: .styles) ?? []
    if let url = try container.decodeIfPresent(String.self, forKey: .url) {
      self.url = url
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(children, forKey: .children)
    try container.encode(styles, forKey: .styles)
    try container.encodeIfPresent(hasURL ? url : nil, forKey: .url)
  }
}

extension InlineProtocol.RichParagraphBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    text = try container.decodeIfPresent([RichText].self, forKey: .text) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
  }
}

extension InlineProtocol.RichHeadingBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
    case level
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    text = try container.decodeIfPresent([RichText].self, forKey: .text) ?? []
    level = try container.decodeIfPresent(Int32.self, forKey: .level) ?? 0
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(level, forKey: .level)
  }
}

extension InlineProtocol.RichListBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case ordered
    case start
    case items
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    ordered = try container.decodeIfPresent(Bool.self, forKey: .ordered) ?? false
    start = try container.decodeIfPresent(Int32.self, forKey: .start) ?? 0
    items = try container.decodeIfPresent([RichListItemBlock].self, forKey: .items) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ordered, forKey: .ordered)
    try container.encode(start, forKey: .start)
    try container.encode(items, forKey: .items)
  }
}

extension InlineProtocol.RichListItemBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case blocks
    case checked
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    blocks = try container.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    if let checked = try container.decodeIfPresent(Bool.self, forKey: .checked) {
      self.checked = checked
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(blocks, forKey: .blocks)
    if hasChecked {
      try container.encode(checked, forKey: .checked)
    }
  }
}

extension InlineProtocol.RichQuoteBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case blocks
    case expandable
    case initiallyCollapsed
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    blocks = try container.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    expandable = try container.decodeIfPresent(Bool.self, forKey: .expandable) ?? false
    initiallyCollapsed = try container.decodeIfPresent(Bool.self, forKey: .initiallyCollapsed) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(blocks, forKey: .blocks)
    try container.encode(expandable, forKey: .expandable)
    try container.encode(initiallyCollapsed, forKey: .initiallyCollapsed)
  }
}

extension InlineProtocol.RichCodeBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
    case language
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    if let language = try container.decodeIfPresent(String.self, forKey: .language) {
      self.language = language
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(hasLanguage ? language : nil, forKey: .language)
  }
}

extension InlineProtocol.RichDividerBlock: Codable {
  public init(from decoder: Decoder) throws {
    self.init()
  }

  public func encode(to encoder: Encoder) throws {}
}

extension InlineProtocol.RichThinkingBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case blocks
    case initiallyCollapsed
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    blocks = try container.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    initiallyCollapsed = try container.decodeIfPresent(Bool.self, forKey: .initiallyCollapsed) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(blocks, forKey: .blocks)
    try container.encode(initiallyCollapsed, forKey: .initiallyCollapsed)
  }
}

extension InlineProtocol.RichDetailsBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case title
    case blocks
    case initiallyOpen
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    title = try container.decodeIfPresent([RichText].self, forKey: .title) ?? []
    blocks = try container.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    initiallyOpen = try container.decodeIfPresent(Bool.self, forKey: .initiallyOpen) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(title, forKey: .title)
    try container.encode(blocks, forKey: .blocks)
    try container.encode(initiallyOpen, forKey: .initiallyOpen)
  }
}

extension InlineProtocol.RichMediaRef: Codable {
  private enum CodingKeys: String, CodingKey {
    case alt
    case fileName
    case width
    case height
    case mimeType
    case cdnURL
    case fileUniqueID
    case photoID
    case videoID
    case documentID
    case voiceID
    case publicURL
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    alt = try container.decodeIfPresent(String.self, forKey: .alt) ?? ""
    if let fileName = try container.decodeIfPresent(String.self, forKey: .fileName) {
      self.fileName = fileName
    }
    if let width = try container.decodeIfPresent(Int32.self, forKey: .width) {
      self.width = width
    }
    if let height = try container.decodeIfPresent(Int32.self, forKey: .height) {
      self.height = height
    }
    if let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) {
      self.mimeType = mimeType
    }
    if let cdnURL = try container.decodeIfPresent(String.self, forKey: .cdnURL) {
      self.cdnURL = cdnURL
    }
    if let fileUniqueID = try container.decodeIfPresent(String.self, forKey: .fileUniqueID) {
      self.fileUniqueID = fileUniqueID
    }

    if let photoID = try container.decodeIfPresent(Int64.self, forKey: .photoID) {
      media = .photoID(photoID)
    } else if let videoID = try container.decodeIfPresent(Int64.self, forKey: .videoID) {
      media = .videoID(videoID)
    } else if let documentID = try container.decodeIfPresent(Int64.self, forKey: .documentID) {
      media = .documentID(documentID)
    } else if let voiceID = try container.decodeIfPresent(Int64.self, forKey: .voiceID) {
      media = .voiceID(voiceID)
    } else if let publicURL = try container.decodeIfPresent(String.self, forKey: .publicURL) {
      media = .publicURL(publicURL)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(alt, forKey: .alt)
    try container.encodeIfPresent(hasFileName ? fileName : nil, forKey: .fileName)
    try container.encodeIfPresent(hasWidth ? width : nil, forKey: .width)
    try container.encodeIfPresent(hasHeight ? height : nil, forKey: .height)
    try container.encodeIfPresent(hasMimeType ? mimeType : nil, forKey: .mimeType)
    try container.encodeIfPresent(hasCdnURL ? cdnURL : nil, forKey: .cdnURL)
    try container.encodeIfPresent(hasFileUniqueID ? fileUniqueID : nil, forKey: .fileUniqueID)

    switch media {
    case let .photoID(value):
      try container.encode(value, forKey: .photoID)
    case let .videoID(value):
      try container.encode(value, forKey: .videoID)
    case let .documentID(value):
      try container.encode(value, forKey: .documentID)
    case let .voiceID(value):
      try container.encode(value, forKey: .voiceID)
    case let .publicURL(value):
      try container.encode(value, forKey: .publicURL)
    case nil:
      break
    }
  }
}

extension InlineProtocol.RichPhotoBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case media
    case caption
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let media = try container.decodeIfPresent(RichMediaRef.self, forKey: .media) {
      self.media = media
    }
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(hasMedia ? media : nil, forKey: .media)
    try container.encode(caption, forKey: .caption)
  }
}

extension InlineProtocol.RichVideoBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case media
    case caption
    case duration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let media = try container.decodeIfPresent(RichMediaRef.self, forKey: .media) {
      self.media = media
    }
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
    if let duration = try container.decodeIfPresent(Int32.self, forKey: .duration) {
      self.duration = duration
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(hasMedia ? media : nil, forKey: .media)
    try container.encode(caption, forKey: .caption)
    try container.encodeIfPresent(hasDuration ? duration : nil, forKey: .duration)
  }
}

extension InlineProtocol.RichDocumentBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case media
    case caption
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let media = try container.decodeIfPresent(RichMediaRef.self, forKey: .media) {
      self.media = media
    }
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(hasMedia ? media : nil, forKey: .media)
    try container.encode(caption, forKey: .caption)
  }
}

extension InlineProtocol.RichAudioBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case media
    case caption
    case duration
    case title
    case performer
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let media = try container.decodeIfPresent(RichMediaRef.self, forKey: .media) {
      self.media = media
    }
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
    if let duration = try container.decodeIfPresent(Int32.self, forKey: .duration) {
      self.duration = duration
    }
    if let title = try container.decodeIfPresent(String.self, forKey: .title) {
      self.title = title
    }
    if let performer = try container.decodeIfPresent(String.self, forKey: .performer) {
      self.performer = performer
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(hasMedia ? media : nil, forKey: .media)
    try container.encode(caption, forKey: .caption)
    try container.encodeIfPresent(hasDuration ? duration : nil, forKey: .duration)
    try container.encodeIfPresent(hasTitle ? title : nil, forKey: .title)
    try container.encodeIfPresent(hasPerformer ? performer : nil, forKey: .performer)
  }
}

extension InlineProtocol.RichTableBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case rows
    case caption
    case bordered
    case striped
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    rows = try container.decodeIfPresent([RichTableRow].self, forKey: .rows) ?? []
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
    bordered = try container.decodeIfPresent(Bool.self, forKey: .bordered) ?? false
    striped = try container.decodeIfPresent(Bool.self, forKey: .striped) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rows, forKey: .rows)
    try container.encode(caption, forKey: .caption)
    try container.encode(bordered, forKey: .bordered)
    try container.encode(striped, forKey: .striped)
  }
}

extension InlineProtocol.RichTableRow: Codable {
  private enum CodingKeys: String, CodingKey {
    case cells
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    cells = try container.decodeIfPresent([RichTableCell].self, forKey: .cells) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(cells, forKey: .cells)
  }
}

extension InlineProtocol.RichTableCell: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
    case header
    case colspan
    case rowspan
    case align
    case valign
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    text = try container.decodeIfPresent([RichText].self, forKey: .text) ?? []
    header = try container.decodeIfPresent(Bool.self, forKey: .header) ?? false
    colspan = try container.decodeIfPresent(Int32.self, forKey: .colspan) ?? 0
    rowspan = try container.decodeIfPresent(Int32.self, forKey: .rowspan) ?? 0
    if let align = try container.decodeIfPresent(RichHorizontalAlign.self, forKey: .align) {
      self.align = align
    }
    if let valign = try container.decodeIfPresent(RichVerticalAlign.self, forKey: .valign) {
      self.valign = valign
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(header, forKey: .header)
    try container.encode(colspan, forKey: .colspan)
    try container.encode(rowspan, forKey: .rowspan)
    try container.encodeIfPresent(hasAlign ? align : nil, forKey: .align)
    try container.encodeIfPresent(hasValign ? valign : nil, forKey: .valign)
  }
}

extension InlineProtocol.RichMathBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case source
    case display
    case fallback
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    display = try container.decodeIfPresent(Bool.self, forKey: .display) ?? false
    if let fallback = try container.decodeIfPresent(String.self, forKey: .fallback) {
      self.fallback = fallback
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(source, forKey: .source)
    try container.encode(display, forKey: .display)
    try container.encodeIfPresent(hasFallback ? fallback : nil, forKey: .fallback)
  }
}

extension InlineProtocol.RichMapBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case latitude
    case longitude
    case zoom
    case caption
    case title
    case address
    case openURL
    case aspectRatio
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    latitude = try container.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
    longitude = try container.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
    zoom = try container.decodeIfPresent(Int32.self, forKey: .zoom) ?? 0
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
    if let title = try container.decodeIfPresent(String.self, forKey: .title) {
      self.title = title
    }
    if let address = try container.decodeIfPresent(String.self, forKey: .address) {
      self.address = address
    }
    if let openURL = try container.decodeIfPresent(String.self, forKey: .openURL) {
      self.openURL = openURL
    }
    if let aspectRatio = try container.decodeIfPresent(Float.self, forKey: .aspectRatio) {
      self.aspectRatio = aspectRatio
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(latitude, forKey: .latitude)
    try container.encode(longitude, forKey: .longitude)
    try container.encode(zoom, forKey: .zoom)
    try container.encode(caption, forKey: .caption)
    try container.encodeIfPresent(hasTitle ? title : nil, forKey: .title)
    try container.encodeIfPresent(hasAddress ? address : nil, forKey: .address)
    try container.encodeIfPresent(hasOpenURL ? openURL : nil, forKey: .openURL)
    try container.encodeIfPresent(hasAspectRatio ? aspectRatio : nil, forKey: .aspectRatio)
  }
}

extension InlineProtocol.RichEmbedBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case url
    case html
    case poster
    case width
    case height
    case caption
    case fullWidth
    case allowScrolling
    case provider
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    if let url = try container.decodeIfPresent(String.self, forKey: .url) {
      self.url = url
    }
    if let html = try container.decodeIfPresent(String.self, forKey: .html) {
      self.html = html
    }
    if let poster = try container.decodeIfPresent(RichMediaRef.self, forKey: .poster) {
      self.poster = poster
    }
    if let width = try container.decodeIfPresent(Int32.self, forKey: .width) {
      self.width = width
    }
    if let height = try container.decodeIfPresent(Int32.self, forKey: .height) {
      self.height = height
    }
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
    fullWidth = try container.decodeIfPresent(Bool.self, forKey: .fullWidth) ?? false
    allowScrolling = try container.decodeIfPresent(Bool.self, forKey: .allowScrolling) ?? false
    if let provider = try container.decodeIfPresent(String.self, forKey: .provider) {
      self.provider = provider
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(hasURL ? url : nil, forKey: .url)
    try container.encodeIfPresent(hasHtml ? html : nil, forKey: .html)
    try container.encodeIfPresent(hasPoster ? poster : nil, forKey: .poster)
    try container.encodeIfPresent(hasWidth ? width : nil, forKey: .width)
    try container.encodeIfPresent(hasHeight ? height : nil, forKey: .height)
    try container.encode(caption, forKey: .caption)
    try container.encode(fullWidth, forKey: .fullWidth)
    try container.encode(allowScrolling, forKey: .allowScrolling)
    try container.encodeIfPresent(hasProvider ? provider : nil, forKey: .provider)
  }
}

extension InlineProtocol.RichEmbedPostBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case url
    case author
    case authorPhoto
    case date
    case blocks
    case caption
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
    if let authorPhoto = try container.decodeIfPresent(RichMediaRef.self, forKey: .authorPhoto) {
      self.authorPhoto = authorPhoto
    }
    if let date = try container.decodeIfPresent(Int64.self, forKey: .date) {
      self.date = date
    }
    blocks = try container.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
    try container.encode(author, forKey: .author)
    try container.encodeIfPresent(hasAuthorPhoto ? authorPhoto : nil, forKey: .authorPhoto)
    try container.encodeIfPresent(hasDate ? date : nil, forKey: .date)
    try container.encode(blocks, forKey: .blocks)
    try container.encode(caption, forKey: .caption)
  }
}

extension InlineProtocol.RichLinkPreviewBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case url
    case displayURL
    case siteName
    case title
    case description
    case media
    case mediaAspectRatio
    case compact
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    if let displayURL = try container.decodeIfPresent(String.self, forKey: .displayURL) {
      self.displayURL = displayURL
    }
    if let siteName = try container.decodeIfPresent(String.self, forKey: .siteName) {
      self.siteName = siteName
    }
    if let title = try container.decodeIfPresent(String.self, forKey: .title) {
      self.title = title
    }
    if let description = try container.decodeIfPresent(String.self, forKey: .description) {
      description_p = description
    }
    if let media = try container.decodeIfPresent(RichMediaRef.self, forKey: .media) {
      self.media = media
    }
    if let mediaAspectRatio = try container.decodeIfPresent(Float.self, forKey: .mediaAspectRatio) {
      self.mediaAspectRatio = mediaAspectRatio
    }
    compact = try container.decodeIfPresent(Bool.self, forKey: .compact) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
    try container.encodeIfPresent(hasDisplayURL ? displayURL : nil, forKey: .displayURL)
    try container.encodeIfPresent(hasSiteName ? siteName : nil, forKey: .siteName)
    try container.encodeIfPresent(hasTitle ? title : nil, forKey: .title)
    try container.encodeIfPresent(hasDescription_p ? description_p : nil, forKey: .description)
    try container.encodeIfPresent(hasMedia ? media : nil, forKey: .media)
    try container.encodeIfPresent(hasMediaAspectRatio ? mediaAspectRatio : nil, forKey: .mediaAspectRatio)
    try container.encode(compact, forKey: .compact)
  }
}

extension InlineProtocol.RichCollageBlock: Codable {
  private enum CodingKeys: String, CodingKey {
    case items
    case caption
    case layout
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    items = try container.decodeIfPresent([RichBlock].self, forKey: .items) ?? []
    caption = try container.decodeIfPresent([RichText].self, forKey: .caption) ?? []
    if let layout = try container.decodeIfPresent(RichCollageLayout.self, forKey: .layout) {
      self.layout = layout
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
    try container.encode(caption, forKey: .caption)
    try container.encodeIfPresent(hasLayout ? layout : nil, forKey: .layout)
  }
}

extension InlineProtocol.RichDirection: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.RichDirection(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.RichTextStyle: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.RichTextStyle(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.RichHorizontalAlign: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.RichHorizontalAlign(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.RichVerticalAlign: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.RichVerticalAlign(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.RichCollageLayout: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.RichCollageLayout(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.RichMessage {
  public var renderedFallbackText: String {
    if !fallbackText.isEmpty {
      return fallbackText
    }
    return blocks.enumerated()
      .map { index, block in block.renderedFallbackText(index: index, depth: 0) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }
}

extension InlineProtocol.RichBlock {
  public func renderedFallbackText(index: Int, depth: Int) -> String {
    switch block {
    case let .paragraph(value):
      return value.text.renderedPlainText
    case let .heading(value):
      return value.text.renderedPlainText
    case let .list(value):
      let start = value.start == 0 ? 1 : Int(value.start)
      return value.items.enumerated().map { itemIndex, item in
        let taskMarker = item.hasChecked ? (item.checked ? "[x] " : "[ ] ") : ""
        let prefix = value.ordered ? "\(start + itemIndex). \(taskMarker)" : "- \(taskMarker)"
        let body = item.blocks.enumerated()
          .map { childIndex, block in block.renderedFallbackText(index: childIndex, depth: depth + 1) }
          .filter { !$0.isEmpty }
          .joined(separator: "\n")
        return String(repeating: "  ", count: depth) + prefix + body
      }.joined(separator: "\n")
    case let .listItem(value):
      return value.blocks.enumerated()
        .map { childIndex, block in block.renderedFallbackText(index: childIndex, depth: depth) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    case let .quote(value):
      let body = value.blocks.enumerated()
        .map { childIndex, block in block.renderedFallbackText(index: childIndex, depth: depth + 1) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      return body.isEmpty ? "" : body.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "> \($0)" }
        .joined(separator: "\n")
    case let .code(value):
      return value.text
    case .divider:
      return "---"
    case let .thinking(value):
      let body = value.blocks.enumerated()
        .map { childIndex, block in block.renderedFallbackText(index: childIndex, depth: depth + 1) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      return body.isEmpty ? "Thinking" : "Thinking\n\(body)"
    case let .details(value):
      let title = value.title.renderedPlainText.isEmpty ? "Details" : value.title.renderedPlainText
      let body = value.blocks.enumerated()
        .map { childIndex, block in block.renderedFallbackText(index: childIndex, depth: depth + 1) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      return body.isEmpty ? title : "\(title)\n\(body)"
    case let .photo(value):
      return mediaFallback(kind: "Photo", media: value.media, caption: value.caption)
    case let .video(value):
      return mediaFallback(kind: "Video", media: value.media, caption: value.caption)
    case let .document(value):
      return mediaFallback(kind: "Document", media: value.media, caption: value.caption)
    case let .audio(value):
      let title = value.hasTitle ? value.title : "Audio"
      let caption = value.caption.renderedPlainText
      return caption.isEmpty ? title : "\(title)\n\(caption)"
    case let .table(value):
      return value.rows.map { row in
        row.cells.map { cell in cell.text.renderedPlainText }.joined(separator: "\t")
      }.joined(separator: "\n")
    case let .math(value):
      return value.hasFallback ? value.fallback : value.source
    case let .map(value):
      let title = value.hasTitle ? value.title : "Map"
      let caption = value.caption.renderedPlainText
      return caption.isEmpty ? title : "\(title)\n\(caption)"
    case let .embed(value):
      let label = value.hasProvider ? value.provider : "Embed"
      let caption = value.caption.renderedPlainText
      return caption.isEmpty ? label : "\(label)\n\(caption)"
    case let .embedPost(value):
      let body = value.blocks.enumerated()
        .map { childIndex, block in block.renderedFallbackText(index: childIndex, depth: depth + 1) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      return [value.author, body, value.caption.renderedPlainText].filter { !$0.isEmpty }.joined(separator: "\n")
    case let .linkPreview(value):
      return [value.title, value.description_p, value.url].filter { !$0.isEmpty }.joined(separator: "\n")
    case let .collage(value):
      let itemText = value.items.enumerated()
        .map { itemIndex, block in block.renderedFallbackText(index: itemIndex, depth: depth) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      return [itemText, value.caption.renderedPlainText].filter { !$0.isEmpty }.joined(separator: "\n")
    case nil:
      return ""
    }
  }

  private func mediaFallback(kind: String, media: RichMediaRef, caption: [RichText]) -> String {
    let label = media.alt.isEmpty ? kind : media.alt
    let captionText = caption.renderedPlainText
    return captionText.isEmpty ? label : "\(label)\n\(captionText)"
  }
}

extension Array where Element == InlineProtocol.RichText {
  public var renderedPlainText: String {
    map(\.renderedPlainText).joined()
  }
}

extension InlineProtocol.RichText {
  public var renderedPlainText: String {
    text + children.renderedPlainText
  }
}

extension InlineProtocol.RichMessage: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize RichMessage to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> RichMessage? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try RichMessage(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize RichMessage from database", error: error)
      return nil
    }
  }
}
