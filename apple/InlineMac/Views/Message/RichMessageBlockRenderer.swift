import AppKit
import InlineKit
import InlineProtocol
import Observation
import SwiftUI

@MainActor
@Observable
final class RichMessageRenderState {
  private var expandedOverrides: [String: Bool] = [:]
  private var revealedSpoilers: Set<String> = []
  @ObservationIgnored var onChange: ((RichMessageBlockStateSnapshot) -> Void)?

  init(snapshot: RichMessageBlockStateSnapshot = .initial) {
    expandedOverrides = snapshot.overrides
    revealedSpoilers = snapshot.revealedSpoilers
  }

  func apply(snapshot: RichMessageBlockStateSnapshot) {
    guard expandedOverrides != snapshot.overrides || revealedSpoilers != snapshot.revealedSpoilers else { return }
    expandedOverrides = snapshot.overrides
    revealedSpoilers = snapshot.revealedSpoilers
  }

  func isExpanded(id: String, defaultExpanded: Bool) -> Bool {
    expandedOverrides[id] ?? defaultExpanded
  }

  func toggle(id: String, defaultExpanded: Bool) {
    expandedOverrides[id] = !(expandedOverrides[id] ?? defaultExpanded)
    onChange?(snapshot)
  }

  func isSpoilerRevealed(id: String) -> Bool {
    revealedSpoilers.contains(id)
  }

  func toggleSpoiler(id: String) {
    if revealedSpoilers.contains(id) {
      revealedSpoilers.remove(id)
    } else {
      revealedSpoilers.insert(id)
    }
    onChange?(snapshot)
  }

  var snapshot: RichMessageBlockStateSnapshot {
    RichMessageBlockStateSnapshot(overrides: expandedOverrides, revealedSpoilers: revealedSpoilers)
  }
}

struct RichMessageBlockStateSnapshot: Hashable {
  var overrides: [String: Bool] = [:]
  var revealedSpoilers: Set<String> = []

  static let initial = RichMessageBlockStateSnapshot()

  func isExpanded(id: String, defaultExpanded: Bool) -> Bool {
    overrides[id] ?? defaultExpanded
  }

  func isSpoilerRevealed(id: String) -> Bool {
    revealedSpoilers.contains(id)
  }

  mutating func toggleSpoiler(id: String) {
    if revealedSpoilers.contains(id) {
      revealedSpoilers.remove(id)
    } else {
      revealedSpoilers.insert(id)
    }
  }

  var signature: String {
    guard !overrides.isEmpty || !revealedSpoilers.isEmpty else { return "initial" }
    let expanded = overrides
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value ? 1 : 0)" }
      .joined(separator: ",")
    let spoilers = revealedSpoilers
      .sorted()
      .joined(separator: ",")

    return "expanded[\(expanded)]|spoilers[\(spoilers)]"
  }

  var layoutSignature: String {
    guard !overrides.isEmpty else { return "initial" }
    let expanded = overrides
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value ? 1 : 0)" }
      .joined(separator: ",")
    return "expanded[\(expanded)]"
  }

  func renderSignature(forSubtree id: String) -> String {
    let expanded = overrides
      .filter { Self.isStateID($0.key, inside: id) }
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value ? 1 : 0)" }
      .joined(separator: ",")
    let spoilers = revealedSpoilers
      .filter { Self.isStateID($0, inside: id) }
      .sorted()
      .joined(separator: ",")

    guard !expanded.isEmpty || !spoilers.isEmpty else { return "initial" }
    return "expanded[\(expanded)]|spoilers[\(spoilers)]"
  }

  private static func isStateID(_ stateID: String, inside subtreeID: String) -> Bool {
    stateID == subtreeID || stateID.hasPrefix("\(subtreeID).")
  }
}

struct RichMessageBlockStyle {
  let baseFont: NSFont
  let codeFont: NSFont
  let primary: NSColor
  let secondary: NSColor
  let link: NSColor
  let border: NSColor
  let fill: NSColor
  let codeFill: NSColor
  let accent: NSColor

  static func message(
    fontSize: CGFloat,
    primary: NSColor,
    secondary: NSColor,
    link: NSColor,
    accent: NSColor = .controlAccentColor
  ) -> RichMessageBlockStyle {
    RichMessageBlockStyle(
      baseFont: .systemFont(ofSize: fontSize),
      codeFont: .monospacedSystemFont(ofSize: fontSize * 0.94, weight: .regular),
      primary: primary,
      secondary: secondary,
      link: link,
      border: NSColor.separatorColor.withAlphaComponent(0.32),
      fill: NSColor.controlBackgroundColor.withAlphaComponent(0.26),
      codeFill: primary.withAlphaComponent(0.045),
      accent: accent
    )
  }
}

struct RichMessageBlockRenderer: View {
  let richText: RichMessage
  let availableWidth: CGFloat
  let style: RichMessageBlockStyle
  let stateSnapshot: RichMessageBlockStateSnapshot
  let stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?

  @State private var state = RichMessageRenderState()

  init(
    richText: RichMessage,
    availableWidth: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot = .initial,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)? = nil
  ) {
    self.richText = richText
    self.availableWidth = availableWidth
    self.style = style
    self.stateSnapshot = state
    self.stateDidChange = stateDidChange
    _state = State(initialValue: RichMessageRenderState(snapshot: state))
  }

  var body: some View {
    let plan = RichMessageBlockSizeCalculator.layout(
      for: richText,
      width: availableWidth,
      style: style,
      state: state.snapshot
    )
    RichBlocksView(
      layout: plan.root,
      style: style,
      state: state
    )
    .frame(width: plan.size.width, height: plan.size.height, alignment: alignment(for: richText.direction))
    .environment(\.layoutDirection, layoutDirection(for: richText.direction))
    .onAppear {
      state.onChange = stateDidChange
      state.apply(snapshot: stateSnapshot)
    }
    .onChange(of: stateSnapshot) { _, snapshot in
      state.onChange = stateDidChange
      state.apply(snapshot: snapshot)
    }
  }

  private var contentWidth: CGFloat {
    RichMessageBlockSizeCalculator.contentWidth(for: availableWidth)
  }
}

private struct RichBlocksView: View {
  let nodes: [RichBlockNode]
  let availableWidth: CGFloat
  let layout: RichBlocksLayoutPlan?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  init(
    blocks: [RichBlock],
    path: String,
    availableWidth: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageRenderState
  ) {
    nodes = blocks.enumerated().map { index, block in
      RichBlockNode(block: block, index: index, path: path)
    }
    self.availableWidth = availableWidth
    layout = nil
    self.style = style
    self.state = state
  }

  init(
    layout: RichBlocksLayoutPlan?,
    blocks: [RichBlock],
    path: String,
    availableWidth: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageRenderState
  ) {
    if let layout {
      nodes = layout.items.map(\.node)
      self.availableWidth = layout.size.width
      self.layout = layout
    } else {
      nodes = blocks.enumerated().map { index, block in
        RichBlockNode(block: block, index: index, path: path)
      }
      self.availableWidth = availableWidth
      self.layout = nil
    }
    self.style = style
    self.state = state
  }

  init(
    layout: RichBlocksLayoutPlan,
    style: RichMessageBlockStyle,
    state: RichMessageRenderState
  ) {
    nodes = layout.items.map(\.node)
    availableWidth = layout.size.width
    self.layout = layout
    self.style = style
    self.state = state
  }

  var body: some View {
    if let layout {
      ZStack(alignment: .topLeading) {
        ForEach(layout.items) { item in
          RichBlockView(
            node: item.node,
            availableWidth: item.frame.width,
            layout: item,
            style: style,
            state: state
          )
          .frame(width: item.frame.width, height: item.frame.height, alignment: .topLeading)
          .position(x: item.frame.midX, y: item.frame.midY)
        }
      }
      .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(nodes) { node in
          RichBlockView(
            node: node,
            availableWidth: availableWidth,
            layout: nil,
            style: style,
            state: state
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct RichBlockNode: Identifiable {
  let id: String
  let block: RichBlock
  let index: Int

  init(block: RichBlock, index: Int, path: String) {
    self.block = block
    self.index = index
    id = block.blockID.isEmpty ? "\(path).\(index)" : block.blockID
  }
}

private struct RichBlockView: View {
  let node: RichBlockNode
  let availableWidth: CGFloat
  let layout: RichBlockLayoutItem?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: blockAlignment, spacing: 0) {
      switch node.block.block {
      case let .paragraph(block):
        RichInlineText(nodes: block.text, font: style.baseFont, style: style)
          .fixedSize(horizontal: false, vertical: true)
      case let .heading(block):
        RichInlineText(
          nodes: block.text,
          font: headingFont(level: block.level),
          style: style
        )
        .fixedSize(horizontal: false, vertical: true)
      case let .list(block):
        RichListView(
          block: block,
          nodeID: node.id,
          availableWidth: availableWidth,
          itemLayouts: layout?.children,
          style: style,
          state: state
        )
      case let .listItem(block):
        RichBlocksView(
          blocks: block.blocks,
          path: "\(node.id).item",
          availableWidth: availableWidth,
          style: style,
          state: state
        )
      case let .quote(block):
        RichQuoteView(
          block: block,
          nodeID: node.id,
          availableWidth: availableWidth,
          childLayout: layout?.children["quote"],
          style: style,
          state: state
        )
      case let .code(block):
        RichCodeView(block: block, availableWidth: availableWidth, style: style)
      case .divider:
        Rectangle()
          .fill(Color(nsColor: style.border.withAlphaComponent(0.55)))
          .frame(height: 0.5)
          .padding(.vertical, 3)
      case let .thinking(block):
        RichThinkingView(
          block: block,
          nodeID: node.id,
          availableWidth: availableWidth,
          childLayout: layout?.children["thinking"],
          style: style,
          state: state
        )
      case let .details(block):
        RichDetailsView(
          block: block,
          nodeID: node.id,
          availableWidth: availableWidth,
          childLayout: layout?.children["details"],
          style: style,
          state: state
        )
      case let .photo(block):
        RichMediaBlockView(kind: "Photo", media: block.media, caption: block.caption, availableWidth: availableWidth, style: style)
      case let .video(block):
        RichMediaBlockView(kind: "Video", media: block.media, caption: block.caption, availableWidth: availableWidth, style: style)
      case let .document(block):
        RichMediaBlockView(kind: "Document", media: block.media, caption: block.caption, availableWidth: availableWidth, style: style)
      case let .audio(block):
        RichAudioBlockView(block: block, style: style)
      case let .table(block):
        RichTableView(block: block, style: style)
      case let .math(block):
        RichMathView(block: block, style: style)
      case let .map(block):
        RichMapView(block: block, style: style)
      case let .embed(block):
        RichEmbedView(block: block, style: style)
      case let .embedPost(block):
        RichEmbedPostView(
          block: block,
          nodeID: node.id,
          availableWidth: availableWidth,
          childLayout: layout?.children["post"],
          style: style,
          state: state
        )
      case let .linkPreview(block):
        RichLinkPreviewView(block: block, style: style)
      case let .collage(block):
        RichCollageView(
          block: block,
          nodeID: node.id,
          availableWidth: availableWidth,
          itemLayouts: layout?.children,
          style: style,
          state: state
        )
      case nil:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity, alignment: blockFrameAlignment)
    .environment(\.layoutDirection, layoutDirection(for: node.block.direction))
  }

  private var blockAlignment: HorizontalAlignment {
    node.block.direction == .directionRtl ? .trailing : .leading
  }

  private var blockFrameAlignment: Alignment {
    alignment(for: node.block.direction)
  }

  private func headingFont(level: Int32) -> NSFont {
    let base = style.baseFont.pointSize
    let size: CGFloat = switch level {
    case 1: base + 7
    case 2: base + 5
    case 3: base + 3
    default: base + 1
    }
    return .systemFont(ofSize: size, weight: .semibold)
  }
}

private struct RichInlineText: View {
  let nodes: [RichText]
  let font: NSFont
  let style: RichMessageBlockStyle

  var body: some View {
    Text(RichTextAttributedStringBuilder.attributedString(nodes: nodes, font: font, style: style))
      .foregroundStyle(Color(nsColor: style.primary))
      .textSelection(.enabled)
      .lineSpacing(1.5)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct RichListView: View {
  let block: RichListBlock
  let nodeID: String
  let availableWidth: CGFloat
  let itemLayouts: [String: RichBlocksLayoutPlan]?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(items) { item in
        HStack(alignment: .top, spacing: metrics.markerGap) {
          markerView(item)
            .frame(width: metrics.markerWidth, height: 20, alignment: .trailing)
          RichBlocksView(
            layout: itemLayouts?[item.id],
            blocks: item.blocks,
            path: item.id,
            availableWidth: metrics.childWidth,
            style: style,
            state: state
          )
        }
      }
    }
  }

  @ViewBuilder
  private func markerView(_ item: RichListItem) -> some View {
    if let checked = item.checked, block.ordered {
      HStack(spacing: 7) {
        Text(item.marker)
          .font(.system(size: style.baseFont.pointSize, weight: .medium))
          .foregroundStyle(Color(nsColor: style.secondary))
          .frame(width: 34, alignment: .trailing)
        Image(systemName: checked ? "checkmark.square.fill" : "square")
          .font(.system(size: max(12, style.baseFont.pointSize - 1), weight: .regular))
          .foregroundStyle(Color(nsColor: checked ? style.accent : style.secondary))
          .frame(width: 20, alignment: .center)
      }
    } else if let checked = item.checked {
      Image(systemName: checked ? "checkmark.square.fill" : "square")
        .font(.system(size: max(12, style.baseFont.pointSize - 1), weight: .regular))
        .foregroundStyle(Color(nsColor: checked ? style.accent : style.secondary))
    } else {
      Text(item.marker)
        .font(.system(size: style.baseFont.pointSize, weight: .medium))
        .foregroundStyle(Color(nsColor: style.secondary))
    }
  }

  private var metrics: RichListLayoutMetrics {
    RichMessageBlockSizeCalculator.listMetrics(for: block, width: availableWidth)
  }

  private var items: [RichListItem] {
    let start = block.start == 0 ? 1 : Int(block.start)
    return block.items.enumerated().map { index, item in
      RichListItem(
        id: "\(nodeID).\(index)",
        marker: block.ordered ? "\(start + index)." : "•",
        blocks: item.blocks,
        checked: item.hasChecked ? item.checked : nil
      )
    }
  }
}

private struct RichListItem: Identifiable {
  let id: String
  let marker: String
  let blocks: [RichBlock]
  let checked: Bool?
}

private struct RichQuoteView: View {
  let block: RichQuoteBlock
  let nodeID: String
  let availableWidth: CGFloat
  let childLayout: RichBlocksLayoutPlan?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 9) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color(nsColor: style.accent.withAlphaComponent(0.55)))
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 6) {
          RichBlocksView(
            layout: childLayout,
            blocks: visibleBlocks,
            path: "\(nodeID).quote",
            availableWidth: max(1, availableWidth - 12),
            style: style,
            state: state
          )
          if block.expandable {
            Button(expanded ? "Show less" : "Show more") {
              state.toggle(id: nodeID, defaultExpanded: !block.initiallyCollapsed)
            }
            .buttonStyle(.plain)
            .font(.system(size: max(11, style.baseFont.pointSize - 2), weight: .medium))
            .foregroundStyle(Color(nsColor: style.link))
          }
        }
      }
    }
  }

  private var expanded: Bool {
    state.isExpanded(id: nodeID, defaultExpanded: !block.initiallyCollapsed)
  }

  private var visibleBlocks: [RichBlock] {
    if expanded || block.blocks.count <= 1 {
      return block.blocks
    }
    return Array(block.blocks.prefix(1))
  }
}

private struct RichCodeView: View {
  let block: RichCodeBlock
  let availableWidth: CGFloat
  let style: RichMessageBlockStyle
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if block.hasLanguage, !block.language.isEmpty {
          Text(block.language.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(nsColor: style.secondary))
        }
        Spacer(minLength: 8)
        Button {
          copyCode()
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: style.secondary))
        .help(copied ? "Copied" : "Copy code")
      }
      .padding(.horizontal, 10)
      .padding(.top, 7)
      .padding(.bottom, 2)
      ScrollView(.horizontal) {
        Text(block.text.isEmpty ? " " : block.text)
          .font(.custom(style.codeFont.fontName, size: style.codeFont.pointSize))
          .foregroundStyle(Color(nsColor: style.primary))
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.top, block.hasLanguage ? 2 : 8)
          .padding(.bottom, 9)
          .frame(minWidth: availableWidth, alignment: .leading)
      }
    }
    .background(Color(nsColor: style.codeFill))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .contextMenu {
      Button("Copy Code") {
        copyCode()
      }
    }
  }

  private func copyCode() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(block.text, forType: .string)
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      copied = false
    }
  }
}

private struct RichThinkingView: View {
  let block: RichThinkingBlock
  let nodeID: String
  let availableWidth: CGFloat
  let childLayout: RichBlocksLayoutPlan?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        state.toggle(id: nodeID, defaultExpanded: !block.initiallyCollapsed)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
          Text("Thinking")
            .font(.system(size: style.baseFont.pointSize, weight: .medium))
        }
        .foregroundStyle(Color(nsColor: style.secondary))
      }
      .buttonStyle(.plain)

      if expanded {
        RichBlocksView(
          layout: childLayout,
          blocks: block.blocks,
          path: "\(nodeID).thinking",
          availableWidth: availableWidth,
          style: style,
          state: state
        )
        .padding(.leading, 12)
      }
    }
    .padding(9)
    .background(Color(nsColor: style.fill))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var expanded: Bool {
    state.isExpanded(id: nodeID, defaultExpanded: !block.initiallyCollapsed)
  }
}

private struct RichDetailsView: View {
  let block: RichDetailsBlock
  let nodeID: String
  let availableWidth: CGFloat
  let childLayout: RichBlocksLayoutPlan?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        state.toggle(id: nodeID, defaultExpanded: block.initiallyOpen)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
          RichInlineText(
            nodes: titleNodes,
            font: .systemFont(ofSize: style.baseFont.pointSize, weight: .medium),
            style: style
          )
        }
      }
      .buttonStyle(.plain)

      if expanded {
        RichBlocksView(
          layout: childLayout,
          blocks: block.blocks,
          path: "\(nodeID).details",
          availableWidth: availableWidth,
          style: style,
          state: state
        )
      }
    }
    .padding(9)
    .background(Color(nsColor: style.fill))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(nsColor: style.border), lineWidth: 0.5)
    )
  }

  private var expanded: Bool {
    state.isExpanded(id: nodeID, defaultExpanded: block.initiallyOpen)
  }

  private var titleNodes: [RichText] {
    block.title.isEmpty ? [RichText.with { $0.text = "Details" }] : block.title
  }
}

private struct RichMediaBlockView: View {
  let kind: String
  let media: RichMediaRef
  let caption: [RichText]
  let availableWidth: CGFloat
  let style: RichMessageBlockStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      mediaBody
        .frame(width: mediaSize.width, height: mediaSize.height)
        .background(Color(nsColor: style.fill))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: style.border), lineWidth: 0.5)
        )

      if !caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: caption, font: style.baseFont, style: style)
      }
    }
  }

  @ViewBuilder private var mediaBody: some View {
    if let url = publicURL {
      AsyncImage(url: url) { phase in
        switch phase {
        case let .success(image):
          image
            .resizable()
            .scaledToFit()
        case .failure:
          placeholder(label: "Unable to load \(kind.lowercased())")
        case .empty:
          placeholder(label: "Loading \(kind.lowercased())")
        @unknown default:
          placeholder(label: kind)
        }
      }
    } else {
      placeholder(label: mediaLabel)
    }
  }

  private func placeholder(label: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 24, weight: .regular))
      Text(label)
        .font(.system(size: max(11, style.baseFont.pointSize - 1), weight: .medium))
    }
    .foregroundStyle(Color(nsColor: style.secondary))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var publicURL: URL? {
    guard case let .publicURL(value)? = media.media else { return nil }
    return RichMediaURLPolicy.safeRemoteMediaURL(from: value)
  }

  private var mediaLabel: String {
    if !media.alt.isEmpty {
      return media.alt
    }
    return switch media.media {
    case let .photoID(id): "Photo #\(id)"
    case let .videoID(id): "Video #\(id)"
    case let .documentID(id): "Document #\(id)"
    case let .voiceID(id): "Voice #\(id)"
    case let .publicURL(url): url
    case nil: kind
    }
  }

  private var mediaSize: CGSize {
    RichMessageBlockSizeCalculator.mediaSize(
      for: media,
      availableWidth: availableWidth,
      hasCaption: !caption.renderedPlainText.isEmpty
    )
  }

  private var icon: String {
    switch kind {
    case "Video": "play.rectangle"
    case "Document": "doc"
    default: "photo"
    }
  }
}

private struct RichAudioBlockView: View {
  let block: RichAudioBlock
  let style: RichMessageBlockStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "waveform")
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(Color(nsColor: style.accent))
        VStack(alignment: .leading, spacing: 2) {
          Text(block.hasTitle ? block.title : "Audio")
            .font(.system(size: style.baseFont.pointSize, weight: .medium))
            .foregroundStyle(Color(nsColor: style.primary))
          if block.hasPerformer {
            Text(block.performer)
              .font(.system(size: max(11, style.baseFont.pointSize - 2)))
              .foregroundStyle(Color(nsColor: style.secondary))
          }
        }
      }
      .padding(10)
      .background(Color(nsColor: style.fill))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      if !block.caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: block.caption, font: style.baseFont, style: style)
      }
    }
  }
}

private struct RichTableView: View {
  let block: RichTableBlock
  let style: RichMessageBlockStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            HStack(alignment: .top, spacing: 0) {
              ForEach(row.cells) { cell in
                RichInlineText(
                  nodes: cell.cell.text,
                  font: cell.cell.header
                    ? .systemFont(ofSize: style.baseFont.pointSize, weight: .semibold)
                    : style.baseFont,
                  style: style
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minWidth: 92, maxWidth: 180, alignment: alignment(for: cell.cell.align))
                .background(Color(nsColor: background(for: row.index)))
                .border(Color(nsColor: style.border), width: block.bordered ? 0.5 : 0)
              }
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(nsColor: style.border), lineWidth: 0.5)
      )

      if !block.caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: block.caption, font: style.baseFont, style: style)
      }
    }
  }

  private var rows: [RichTableRowNode] {
    block.rows.enumerated().map { rowIndex, row in
      RichTableRowNode(
        id: "row.\(rowIndex)",
        index: rowIndex,
        cells: row.cells.enumerated().map { cellIndex, cell in
          RichTableCellNode(id: "row.\(rowIndex).cell.\(cellIndex)", cell: cell)
        }
      )
    }
  }

  private func background(for index: Int) -> NSColor {
    block.striped && index.isMultiple(of: 2) ? style.fill : .clear
  }
}

private struct RichTableRowNode: Identifiable {
  let id: String
  let index: Int
  let cells: [RichTableCellNode]
}

private struct RichTableCellNode: Identifiable {
  let id: String
  let cell: RichTableCell
}

private struct RichMathView: View {
  let block: RichMathBlock
  let style: RichMessageBlockStyle

  var body: some View {
    Text(block.hasFallback ? block.fallback : block.source)
      .font(.custom(style.codeFont.fontName, size: style.codeFont.pointSize))
      .foregroundStyle(Color(nsColor: style.primary))
      .textSelection(.enabled)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: style.codeFill))
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

private struct RichMapView: View {
  let block: RichMapBlock
  let style: RichMessageBlockStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "map")
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(Color(nsColor: style.accent))
        VStack(alignment: .leading, spacing: 2) {
          Text(block.hasTitle ? block.title : "Map")
            .font(.system(size: style.baseFont.pointSize, weight: .medium))
            .foregroundStyle(Color(nsColor: style.primary))
          Text(block.hasAddress ? block.address : "\(block.latitude), \(block.longitude)")
            .font(.system(size: max(11, style.baseFont.pointSize - 2)))
            .foregroundStyle(Color(nsColor: style.secondary))
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: style.fill))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      if !block.caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: block.caption, font: style.baseFont, style: style)
      }
    }
  }
}

private struct RichEmbedView: View {
  let block: RichEmbedBlock
  let style: RichMessageBlockStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "safari")
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(Color(nsColor: style.accent))
        VStack(alignment: .leading, spacing: 2) {
          Text(block.hasProvider ? block.provider : "Embed")
            .font(.system(size: style.baseFont.pointSize, weight: .medium))
            .foregroundStyle(Color(nsColor: style.primary))
          if block.hasURL {
            Text(block.url)
              .font(.system(size: max(11, style.baseFont.pointSize - 2)))
              .foregroundStyle(Color(nsColor: style.secondary))
              .lineLimit(1)
          }
        }
      }
      .padding(10)
      .background(Color(nsColor: style.fill))
      .clipShape(RoundedRectangle(cornerRadius: 6))

      if !block.caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: block.caption, font: style.baseFont, style: style)
      }
    }
  }
}

private struct RichEmbedPostView: View {
  let block: RichEmbedPostBlock
  let nodeID: String
  let availableWidth: CGFloat
  let childLayout: RichBlocksLayoutPlan?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "person.crop.circle")
          .foregroundStyle(Color(nsColor: style.secondary))
        Text(block.author.isEmpty ? "Embedded post" : block.author)
          .font(.system(size: style.baseFont.pointSize, weight: .medium))
          .foregroundStyle(Color(nsColor: style.primary))
      }
      RichBlocksView(
        layout: childLayout,
        blocks: block.blocks,
        path: "\(nodeID).post",
        availableWidth: availableWidth,
        style: style,
        state: state
      )
      if !block.caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: block.caption, font: style.baseFont, style: style)
      }
    }
    .padding(10)
    .background(Color(nsColor: style.fill))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

private struct RichLinkPreviewView: View {
  let block: RichLinkPreviewBlock
  let style: RichMessageBlockStyle

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      RoundedRectangle(cornerRadius: 2)
        .fill(Color(nsColor: style.accent.withAlphaComponent(0.55)))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 3) {
        if block.hasSiteName {
          Text(block.siteName)
            .font(.system(size: max(11, style.baseFont.pointSize - 2), weight: .medium))
            .foregroundStyle(Color(nsColor: style.secondary))
        }
        Text(block.hasTitle ? block.title : block.url)
          .font(.system(size: style.baseFont.pointSize, weight: .semibold))
          .foregroundStyle(Color(nsColor: style.primary))
        if block.hasDescription_p {
          Text(block.description_p)
            .font(.system(size: max(11, style.baseFont.pointSize - 1)))
            .foregroundStyle(Color(nsColor: style.secondary))
            .lineLimit(3)
        }
        Text(block.hasDisplayURL ? block.displayURL : block.url)
          .font(.system(size: max(10, style.baseFont.pointSize - 3)))
          .foregroundStyle(Color(nsColor: style.link))
          .lineLimit(1)
      }
    }
    .padding(10)
    .background(Color(nsColor: style.fill))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

private struct RichCollageView: View {
  let block: RichCollageBlock
  let nodeID: String
  let availableWidth: CGFloat
  let itemLayouts: [String: RichBlocksLayoutPlan]?
  let style: RichMessageBlockStyle
  let state: RichMessageRenderState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(nodes) { item in
          RichBlockView(
            node: item,
            availableWidth: cellWidth,
            layout: nil,
            style: style,
            state: state
          )
        }
      }
      if !block.caption.renderedPlainText.isEmpty {
        RichInlineText(nodes: block.caption, font: style.baseFont, style: style)
      }
    }
  }

  private var nodes: [RichBlockNode] {
    block.items.enumerated().map { index, block in
      RichBlockNode(block: block, index: index, path: "\(nodeID).collage")
    }
  }

  private var columns: [GridItem] {
    [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
  }

  private var cellWidth: CGFloat {
    max(1, (availableWidth - 6) / 2)
  }
}

struct RichMessageLayoutPlan {
  let size: CGSize
  let root: RichBlocksLayoutPlan
}

struct RichBlocksLayoutPlan {
  let size: CGSize
  let items: [RichBlockLayoutItem]
}

struct RichBlockLayoutItem: Identifiable {
  let id: String
  let node: RichBlockNode
  let frame: CGRect
  let children: [String: RichBlocksLayoutPlan]
  let mediaLayout: RichMediaLayoutPlan?
  let embedLayout: RichEmbedLayoutPlan?
  let embedPostLayout: RichEmbedPostLayoutPlan?
  let linkPreviewLayout: RichLinkPreviewLayoutPlan?
  let quoteLayout: RichQuoteLayoutPlan?
  let collapsibleLayout: RichCollapsibleLayoutPlan?
  let tableLayout: RichTableLayoutPlan?
}

struct RichMediaLayoutPlan {
  let size: CGSize
  let mediaFrame: CGRect
  let captionFrame: CGRect?
}

struct RichLinkPreviewLayoutPlan {
  let size: CGSize
  let ruleFrame: CGRect
  let textFrame: CGRect
  let mediaFrame: CGRect?
}

struct RichEmbedLayoutPlan {
  let size: CGSize
  let cardFrame: CGRect
  let mediaFrame: CGRect?
  let captionFrame: CGRect?
}

struct RichEmbedPostLayoutPlan {
  let size: CGSize
  let headerFrame: CGRect
  let authorPhotoFrame: CGRect?
  let childFrame: CGRect?
  let captionFrame: CGRect?
}

struct RichListLayoutMetrics {
  let markerWidth: CGFloat
  let markerGap: CGFloat
  let childX: CGFloat
  let childWidth: CGFloat
}

struct RichQuoteLayoutPlan {
  let size: CGSize
  let ruleFrame: CGRect
  let childFrame: CGRect
  let buttonFrame: CGRect?
}

struct RichCollapsibleLayoutPlan {
  let size: CGSize
  let buttonFrame: CGRect
  let childFrame: CGRect?
}

struct RichCodeLayoutPlan {
  let size: CGSize
  let languageFrame: CGRect?
  let copyFrame: CGRect
  let textFrame: CGRect
}

enum RichCodeBlockText {
  static func attributedString(
    _ text: String,
    font: NSFont,
    color: NSColor? = nil
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byCharWrapping
    paragraph.lineSpacing = 0

    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .paragraphStyle: paragraph,
    ]
    if let color {
      attributes[.foregroundColor] = color
    }
    return NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
  }
}

struct RichTableLayoutPlan {
  struct Cell: Identifiable {
    let id: String
    let row: Int
    let column: Int
    let cell: RichTableCell
    let frame: CGRect
    let textFrame: CGRect
  }

  let size: CGSize
  let viewportSize: CGSize
  let contentSize: CGSize
  let captionFrame: CGRect?
  let columnWidths: [CGFloat]
  let rowHeights: [CGFloat]
  let cells: [Cell]
}

enum RichMessageBlockSizeCalculator {
  static let maxContentWidth: CGFloat = 700
  static let maxMediaSide: CGFloat = 320
  static let maxMediaHeight: CGFloat = 320
  static let fallbackMediaSize = CGSize(width: 320, height: 180)
  static let minMediaSize = CGSize(width: 40, height: 40)
  private static let linkPreviewPadding: CGFloat = 10
  private static let linkPreviewRuleWidth: CGFloat = 3
  private static let linkPreviewRuleGap: CGFloat = 9
  private static let linkPreviewMediaGap: CGFloat = 10
  private static let linkPreviewCompactMediaHeight: CGFloat = 72
  private static let linkPreviewMediaHeight: CGFloat = 96
  private static let embedCardHeight: CGFloat = 54
  private static let embedPosterSpacing: CGFloat = 8
  private static let embedCaptionSpacing: CGFloat = 6
  private static let embedPostHeaderHeight: CGFloat = 34
  private static let embedPostAuthorPhotoSize: CGFloat = 24
  private static let embedPostAuthorPhotoInset: CGFloat = 5
  private static let embedPostChildX: CGFloat = 10
  private static let embedPostBottomPadding: CGFloat = 4
  private static let embedPostCaptionSpacing: CGFloat = 10
  private static let tableMinColumnWidth: CGFloat = 72
  private static let tableMaxColumnWidth: CGFloat = 260
  private static let tableCellHorizontalPadding: CGFloat = 8
  private static let tableCellVerticalPadding: CGFloat = 6
  private static let tableMinRowHeight: CGFloat = 30
  private static let tableCaptionSpacing: CGFloat = 6
  private static let tableHorizontalScrollerHeight: CGFloat = 12
  private static let quoteRuleWidth: CGFloat = 3
  private static let quoteRuleRadius: CGFloat = 1.5
  private static let quoteContentX: CGFloat = 12
  private static let quoteButtonTopSpacing: CGFloat = 4
  private static let quoteButtonHeight: CGFloat = 18
  private static let quoteButtonWidth: CGFloat = 112
  private static let collapsibleButtonFrame = CGRect(x: 9, y: 7, width: 0, height: 20)
  private static let collapsibleChildX: CGFloat = 12
  private static let collapsibleChildTop: CGFloat = 35
  private static let collapsibleBottomPadding: CGFloat = 8

  private struct TablePlacement {
    let row: Int
    let cellIndex: Int
    let column: Int
    let colspan: Int
    let rowspan: Int
    let cell: RichTableCell
  }

  private struct MeasuredTablePlacement {
    let placement: TablePlacement
    let textHeight: CGFloat
  }

  static func contentWidth(for width: CGFloat) -> CGFloat {
    max(1, min(maxContentWidth, width))
  }

  static func listMetrics(for block: RichListBlock, width: CGFloat) -> RichListLayoutMetrics {
    let hasChecklist = block.items.contains { $0.hasChecked }
    let markerGap: CGFloat = 7
    let markerWidth: CGFloat = if block.ordered {
      hasChecklist ? 61 : 34
    } else if hasChecklist {
      20
    } else {
      16
    }
    let childX = markerWidth + markerGap

    return RichListLayoutMetrics(
      markerWidth: markerWidth,
      markerGap: markerGap,
      childX: childX,
      childWidth: max(1, width - childX)
    )
  }

  static var quoteRuleCornerRadius: CGFloat {
    quoteRuleRadius
  }

  static func size(
    for richText: RichMessage,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot = .initial
  ) -> CGSize {
    layout(for: richText, width: width, style: style, state: state).size
  }

  static func layout(
    for richText: RichMessage,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot = .initial
  ) -> RichMessageLayoutPlan {
    let contentWidth = contentWidth(for: width)
    let root = blocksLayout(
      richText.blocks,
      path: "root",
      width: contentWidth,
      style: style,
      state: state
    )
    return RichMessageLayoutPlan(size: root.size, root: root)
  }

  static func blocksLayoutForAppKit(
    _ blocks: [RichBlock],
    path: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> RichBlocksLayoutPlan {
    blocksLayout(
      blocks,
      path: path,
      width: width,
      style: style,
      state: state
    )
  }

  static func embedPostLayoutForAppKit(
    _ block: RichEmbedPostBlock,
    id: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> (layout: RichEmbedPostLayoutPlan, child: RichBlocksLayoutPlan?) {
    embedPostLayout(for: block, id: id, width: width, style: style, state: state)
  }

  static func aspectRatio(for media: RichMediaRef, fallback: CGFloat) -> CGFloat {
    guard media.hasWidth, media.hasHeight, media.width > 0, media.height > 0 else {
      return fallback
    }
    return max(0.4, min(3, CGFloat(media.width) / CGFloat(media.height)))
  }

  static func mediaSize(for media: RichMediaRef, availableWidth: CGFloat, hasCaption: Bool) -> CGSize {
    let maxWidth = max(minMediaSize.width, min(maxMediaSide, ceil(availableWidth)))
    let maxHeight = max(minMediaSize.height, maxMediaHeight)

    guard media.hasWidth, media.hasHeight, media.width > 0, media.height > 0 else {
      let width = min(maxWidth, fallbackMediaSize.width)
      let height = min(maxHeight, ceil(width / (fallbackMediaSize.width / fallbackMediaSize.height)))
      return CGSize(width: width, height: height)
    }

    let sourceWidth = CGFloat(media.width)
    let sourceHeight = CGFloat(media.height)
    let scale = min(maxWidth / sourceWidth, maxHeight / sourceHeight)
    let cappedScale = min(1, scale)
    let width = max(minMediaSize.width, ceil(sourceWidth * cappedScale))
    let height = max(minMediaSize.height, ceil(width / aspectRatio(for: media, fallback: 16 / 9)))

    if height <= maxHeight {
      return CGSize(width: width, height: height)
    }

    let heightScale = min(1, scale)
    let boundedHeight = max(minMediaSize.height, ceil(sourceHeight * heightScale))
    let boundedWidth = max(minMediaSize.width, ceil(boundedHeight * aspectRatio(for: media, fallback: 16 / 9)))
    return CGSize(width: min(maxWidth, boundedWidth), height: min(maxHeight, boundedHeight))
  }

  static func mediaLayout(
    for media: RichMediaRef,
    caption: [RichText],
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichMediaLayoutPlan {
    let hasCaption = !caption.renderedPlainText.isEmpty
    let mediaSize = mediaSize(for: media, availableWidth: width, hasCaption: hasCaption)
    let captionHeight = hasCaption ? textHeight(caption, width: mediaSize.width, font: style.baseFont, style: style) : 0
    let captionFrame = hasCaption
      ? CGRect(x: 0, y: mediaSize.height + 6, width: mediaSize.width, height: captionHeight)
      : nil
    let totalHeight = mediaSize.height + (hasCaption ? captionHeight + 6 : 0)

    return RichMediaLayoutPlan(
      size: CGSize(width: mediaSize.width, height: ceil(totalHeight)),
      mediaFrame: CGRect(origin: .zero, size: mediaSize),
      captionFrame: captionFrame
    )
  }

  static func linkPreviewLayout(
    for block: RichLinkPreviewBlock,
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichLinkPreviewLayoutPlan {
    let cardWidth = max(1, width)
    let contentX = linkPreviewPadding + linkPreviewRuleWidth + linkPreviewRuleGap
    let contentY = linkPreviewPadding
    let contentWidth = max(1, cardWidth - contentX - linkPreviewPadding)
    let ruleFrame = CGRect(
      x: linkPreviewPadding,
      y: linkPreviewPadding,
      width: linkPreviewRuleWidth,
      height: 1
    )

    guard block.hasMedia else {
      let textHeight = measure(linkPreviewAttributedString(for: block, style: style), width: contentWidth).height
      let textFrame = CGRect(x: contentX, y: contentY, width: contentWidth, height: textHeight)
      return RichLinkPreviewLayoutPlan(
        size: CGSize(width: cardWidth, height: ceil(textFrame.maxY + linkPreviewPadding)),
        ruleFrame: CGRect(
          x: ruleFrame.minX,
          y: ruleFrame.minY,
          width: ruleFrame.width,
          height: max(1, textFrame.height)
        ),
        textFrame: textFrame,
        mediaFrame: nil
      )
    }

    let mediaSize = linkPreviewMediaSize(for: block, contentWidth: contentWidth)
    let canPlaceSideBySide = contentWidth >= mediaSize.width + linkPreviewMediaGap + 120
    let textWidth = canPlaceSideBySide
      ? max(1, contentWidth - mediaSize.width - linkPreviewMediaGap)
      : contentWidth
    let textHeight = measure(linkPreviewAttributedString(for: block, style: style), width: textWidth).height

    let textFrame: CGRect
    let mediaFrame: CGRect
    if canPlaceSideBySide {
      mediaFrame = CGRect(
        x: contentX + textWidth + linkPreviewMediaGap,
        y: contentY,
        width: mediaSize.width,
        height: mediaSize.height
      )
      textFrame = CGRect(x: contentX, y: contentY, width: textWidth, height: textHeight)
    } else {
      mediaFrame = CGRect(x: contentX, y: contentY, width: mediaSize.width, height: mediaSize.height)
      textFrame = CGRect(
        x: contentX,
        y: mediaFrame.maxY + 8,
        width: textWidth,
        height: textHeight
      )
    }

    let contentHeight = max(textFrame.maxY, mediaFrame.maxY) - contentY
    return RichLinkPreviewLayoutPlan(
      size: CGSize(width: cardWidth, height: ceil(contentY + contentHeight + linkPreviewPadding)),
      ruleFrame: CGRect(
        x: ruleFrame.minX,
        y: ruleFrame.minY,
        width: ruleFrame.width,
        height: max(1, contentHeight)
      ),
      textFrame: textFrame,
      mediaFrame: mediaFrame
    )
  }

  private static func linkPreviewMediaSize(
    for block: RichLinkPreviewBlock,
    contentWidth: CGFloat
  ) -> CGSize {
    let fallbackRatio = block.hasMediaAspectRatio && block.mediaAspectRatio > 0
      ? CGFloat(block.mediaAspectRatio)
      : 16 / 9
    let ratio = aspectRatio(for: block.media, fallback: fallbackRatio)
    let height = block.compact ? linkPreviewCompactMediaHeight : linkPreviewMediaHeight
    let maxWidth = min(contentWidth, block.compact ? 108 : max(108, contentWidth * 0.38))
    let width = min(maxWidth, max(minMediaSize.width, ceil(height * ratio)))
    return CGSize(
      width: ceil(width),
      height: ceil(max(minMediaSize.height, width / ratio))
    )
  }

  static func embedLayout(
    for block: RichEmbedBlock,
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichEmbedLayoutPlan {
    let cardWidth = max(1, width)
    let cardFrame = CGRect(x: 0, y: 0, width: cardWidth, height: embedCardHeight)
    let mediaFrame: CGRect?
    var y = cardFrame.maxY

    if block.hasPoster {
      let mediaSize = mediaSize(for: block.poster, availableWidth: cardWidth, hasCaption: !block.caption.renderedPlainText.isEmpty)
      let frame = CGRect(
        x: 0,
        y: y + embedPosterSpacing,
        width: mediaSize.width,
        height: mediaSize.height
      )
      mediaFrame = frame
      y = frame.maxY
    } else {
      mediaFrame = nil
    }

    let hasCaption = !block.caption.renderedPlainText.isEmpty
    let captionFrame: CGRect?
    if hasCaption {
      let captionWidth = mediaFrame?.width ?? cardWidth
      let captionY = y + embedCaptionSpacing
      let captionHeight = textHeight(block.caption, width: captionWidth, font: style.baseFont, style: style)
      captionFrame = CGRect(x: 0, y: captionY, width: captionWidth, height: captionHeight)
      y = captionFrame?.maxY ?? y
    } else {
      captionFrame = nil
    }

    return RichEmbedLayoutPlan(
      size: CGSize(width: cardWidth, height: ceil(max(cardFrame.maxY, y))),
      cardFrame: cardFrame,
      mediaFrame: mediaFrame,
      captionFrame: captionFrame
    )
  }

  static func documentLayout(
    for _: RichMediaRef,
    caption: [RichText],
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichMediaLayoutPlan {
    let hasCaption = !caption.renderedPlainText.isEmpty
    let baseWidth = min(width, Theme.documentViewWidth)
    let captionWidth = hasCaption
      ? min(width, max(baseWidth, textSize(caption, width: width, font: style.baseFont, style: style).width))
      : baseWidth
    let documentWidth = max(1, ceil(captionWidth))
    let documentSize = CGSize(width: documentWidth, height: Theme.documentViewHeight)
    let captionHeight = hasCaption ? textHeight(caption, width: documentWidth, font: style.baseFont, style: style) : 0
    let captionFrame = hasCaption
      ? CGRect(x: 0, y: documentSize.height + 6, width: documentWidth, height: captionHeight)
      : nil
    let totalHeight = documentSize.height + (hasCaption ? captionHeight + 6 : 0)

    return RichMediaLayoutPlan(
      size: CGSize(width: documentWidth, height: ceil(totalHeight)),
      mediaFrame: CGRect(origin: .zero, size: documentSize),
      captionFrame: captionFrame
    )
  }

  static func audioLayout(
    for block: RichAudioBlock,
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichMediaLayoutPlan {
    let hasCaption = !block.caption.renderedPlainText.isEmpty
    let baseWidth = min(width, Theme.voiceMessageViewWidth)
    let captionWidth = hasCaption
      ? min(width, max(baseWidth, textSize(block.caption, width: width, font: style.baseFont, style: style).width))
      : baseWidth
    let audioWidth = max(1, ceil(captionWidth))
    let audioSize = CGSize(width: audioWidth, height: Theme.voiceMessageViewHeight)
    let captionHeight = hasCaption ? textHeight(block.caption, width: audioWidth, font: style.baseFont, style: style) : 0
    let captionFrame = hasCaption
      ? CGRect(x: 0, y: audioSize.height + 6, width: audioWidth, height: captionHeight)
      : nil
    let totalHeight = audioSize.height + (hasCaption ? captionHeight + 6 : 0)

    return RichMediaLayoutPlan(
      size: CGSize(width: audioWidth, height: ceil(totalHeight)),
      mediaFrame: CGRect(origin: .zero, size: audioSize),
      captionFrame: captionFrame
    )
  }

  private static func embedPostLayout(
    for block: RichEmbedPostBlock,
    id: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> (layout: RichEmbedPostLayoutPlan, child: RichBlocksLayoutPlan?) {
    let cardWidth = max(1, width)
    let headerFrame = CGRect(x: 0, y: 0, width: cardWidth, height: embedPostHeaderHeight)
    let authorPhotoFrame = block.hasAuthorPhoto
      ? CGRect(
        x: embedPostAuthorPhotoInset,
        y: ceil((embedPostHeaderHeight - embedPostAuthorPhotoSize) / 2),
        width: embedPostAuthorPhotoSize,
        height: embedPostAuthorPhotoSize
      )
      : nil
    let child = block.blocks.isEmpty
      ? nil
      : blocksLayout(
        block.blocks,
        path: "\(id).post",
        width: embedPostChildWidth(for: cardWidth),
        style: style,
        state: state
      )
    let childFrame = child.map {
      CGRect(
        x: embedPostChildX,
        y: headerFrame.maxY,
        width: $0.size.width,
        height: $0.size.height
      )
    }
    let contentBottom = childFrame?.maxY ?? headerFrame.maxY

    let hasCaption = !block.caption.renderedPlainText.isEmpty
    let captionFrame: CGRect?
    let height: CGFloat
    if hasCaption {
      let captionY = contentBottom + embedPostCaptionSpacing
      let captionHeight = textHeight(block.caption, width: cardWidth, font: style.baseFont, style: style)
      captionFrame = CGRect(x: 0, y: captionY, width: cardWidth, height: captionHeight)
      height = captionFrame?.maxY ?? captionY
    } else {
      captionFrame = nil
      height = contentBottom + embedPostBottomPadding
    }

    return (
      RichEmbedPostLayoutPlan(
        size: CGSize(width: cardWidth, height: ceil(max(headerFrame.height, height))),
        headerFrame: headerFrame,
        authorPhotoFrame: authorPhotoFrame,
        childFrame: childFrame,
        captionFrame: captionFrame
      ),
      child
    )
  }

  private static func quoteLayout(
    for block: RichQuoteBlock,
    id: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> (layout: RichQuoteLayoutPlan, child: RichBlocksLayoutPlan) {
    let expanded = state.isExpanded(id: id, defaultExpanded: !block.initiallyCollapsed)
    let visible = expanded || block.blocks.count <= 1 ? block.blocks : Array(block.blocks.prefix(1))
    let child = blocksLayout(
      visible,
      path: "\(id).quote",
      width: max(1, width - quoteContentX),
      style: style,
      state: state
    )
    let childFrame = CGRect(x: quoteContentX, y: 0, width: child.size.width, height: child.size.height)
    let buttonFrame = block.expandable
      ? CGRect(x: quoteContentX, y: childFrame.maxY + quoteButtonTopSpacing, width: quoteButtonWidth, height: quoteButtonHeight)
      : nil
    let height = ceil(max(childFrame.maxY, buttonFrame?.maxY ?? 0, 1))

    return (
      RichQuoteLayoutPlan(
        size: CGSize(width: width, height: height),
        ruleFrame: CGRect(x: 0, y: 0, width: quoteRuleWidth, height: height),
        childFrame: childFrame,
        buttonFrame: buttonFrame
      ),
      child
    )
  }

  private static func collapsibleLayout(
    blocks: [RichBlock],
    path: String,
    width: CGFloat,
    expanded: Bool,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> (layout: RichCollapsibleLayoutPlan, child: RichBlocksLayoutPlan?) {
    let buttonFrame = CGRect(
      x: collapsibleButtonFrame.minX,
      y: collapsibleButtonFrame.minY,
      width: max(1, width - collapsibleButtonFrame.minX * 2),
      height: collapsibleButtonFrame.height
    )

    guard expanded else {
      return (
        RichCollapsibleLayoutPlan(
          size: CGSize(width: width, height: ceil(buttonFrame.maxY + collapsibleBottomPadding)),
          buttonFrame: buttonFrame,
          childFrame: nil
        ),
        nil
      )
    }

    let child = blocksLayout(
      blocks,
      path: path,
      width: max(1, width - collapsibleChildX - collapsibleButtonFrame.minX),
      style: style,
      state: state
    )
    let childFrame = CGRect(
      x: collapsibleChildX,
      y: collapsibleChildTop,
      width: child.size.width,
      height: child.size.height
    )
    let height = ceil(max(buttonFrame.maxY, childFrame.maxY + collapsibleBottomPadding))

    return (
      RichCollapsibleLayoutPlan(
        size: CGSize(width: width, height: height),
        buttonFrame: buttonFrame,
        childFrame: childFrame
      ),
      child
    )
  }

  static func tableLayout(
    for block: RichTableBlock,
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichTableLayoutPlan {
    let availableWidth = max(1, width)
    let placements = tablePlacements(for: block)
    let columnCount = max(1, placements.map { $0.column + $0.colspan }.max() ?? 1)

    var columnWidths = Array(repeating: tableMinColumnWidth, count: columnCount)
    for placement in placements {
      let font = placement.cell.header
        ? NSFont.systemFont(ofSize: style.baseFont.pointSize, weight: .semibold)
        : style.baseFont
      let textWidth = textSize(placement.cell.text, width: 10_000, font: font, style: style).width
      let desired = min(tableMaxColumnWidth, max(tableMinColumnWidth, ceil(textWidth) + tableCellHorizontalPadding * 2))
      let perColumn = ceil(desired / CGFloat(placement.colspan))
      for offset in 0..<placement.colspan where placement.column + offset < columnWidths.count {
        columnWidths[placement.column + offset] = max(columnWidths[placement.column + offset], perColumn)
      }
    }

    let measured = placements.map { placement in
      let font = placement.cell.header
        ? NSFont.systemFont(ofSize: style.baseFont.pointSize, weight: .semibold)
        : style.baseFont
      let cellWidth = tableColumnWidth(columnWidths, column: placement.column, span: placement.colspan)
      let textWidth = max(1, cellWidth - tableCellHorizontalPadding * 2)
      let textHeight = textSize(placement.cell.text, width: textWidth, font: font, style: style).height
      return MeasuredTablePlacement(placement: placement, textHeight: max(1, textHeight))
    }

    let rowCount = max(1, max(block.rows.count, placements.map { $0.row + $0.rowspan }.max() ?? 0))
    var rowHeights = Array(repeating: tableMinRowHeight, count: rowCount)

    for item in measured where item.placement.rowspan <= 1 {
      let desired = ceil(item.textHeight) + tableCellVerticalPadding * 2
      rowHeights[item.placement.row] = max(rowHeights[item.placement.row], desired)
    }

    for item in measured where item.placement.rowspan > 1 {
      let range = item.placement.row..<min(rowHeights.count, item.placement.row + item.placement.rowspan)
      guard !range.isEmpty else { continue }
      let desired = ceil(item.textHeight) + tableCellVerticalPadding * 2
      let current = range.reduce(CGFloat(0)) { total, row in total + rowHeights[row] }
      guard desired > current else { continue }

      let extra = ceil((desired - current) / CGFloat(range.count))
      for row in range {
        rowHeights[row] += extra
      }
    }

    let rowOrigins = tableRowOrigins(rowHeights)
    var cells: [RichTableLayoutPlan.Cell] = []

    for item in measured {
      let placement = item.placement
      let rowRange = placement.row..<min(rowHeights.count, placement.row + placement.rowspan)
      guard !rowRange.isEmpty else { continue }

      let frame = CGRect(
        x: tableColumnX(columnWidths, column: placement.column),
        y: rowOrigins[placement.row],
        width: tableColumnWidth(columnWidths, column: placement.column, span: placement.colspan),
        height: rowRange.reduce(CGFloat(0)) { total, row in total + rowHeights[row] }
      )
      let textY = frame.minY + verticalTextOffset(for: placement.cell, rowHeight: frame.height, textHeight: item.textHeight)
      let textFrame = CGRect(
        x: frame.minX + tableCellHorizontalPadding,
        y: textY,
        width: max(1, frame.width - tableCellHorizontalPadding * 2),
        height: item.textHeight
      )
      cells.append(RichTableLayoutPlan.Cell(
        id: "row.\(placement.row).cell.\(placement.cellIndex)",
        row: placement.row,
        column: placement.column,
        cell: placement.cell,
        frame: frame,
        textFrame: textFrame
      ))
    }

    let contentWidth = max(columnWidths.reduce(CGFloat(0), +), tableMinColumnWidth)
    let contentHeight = rowHeights.reduce(CGFloat(0), +)
    let needsHorizontalScroll = contentWidth > availableWidth
    let viewportWidth = min(contentWidth, availableWidth)
    let viewportHeight = contentHeight + (needsHorizontalScroll ? tableHorizontalScrollerHeight : 0)
    let captionHeight = block.caption.isEmpty
      ? 0
      : textHeight(block.caption, width: viewportWidth, font: style.baseFont, style: style)
    let captionFrame = captionHeight > 0
      ? CGRect(x: 0, y: viewportHeight + tableCaptionSpacing, width: viewportWidth, height: captionHeight)
      : nil
    let totalHeight = viewportHeight + (captionFrame == nil ? 0 : tableCaptionSpacing + captionHeight)

    return RichTableLayoutPlan(
      size: CGSize(width: viewportWidth, height: ceil(totalHeight)),
      viewportSize: CGSize(width: viewportWidth, height: ceil(viewportHeight)),
      contentSize: CGSize(width: contentWidth, height: ceil(contentHeight)),
      captionFrame: captionFrame,
      columnWidths: columnWidths,
      rowHeights: rowHeights,
      cells: cells
    )
  }

  private static func tablePlacements(for block: RichTableBlock) -> [TablePlacement] {
    var occupiedUntil: [Int] = []
    var placements: [TablePlacement] = []

    for (rowIndex, row) in block.rows.enumerated() {
      var column = 0
      for (cellIndex, cell) in row.cells.enumerated() {
        while column < occupiedUntil.count, occupiedUntil[column] > rowIndex {
          column += 1
        }

        let colspan = tableSpan(cell.colspan)
        let rowspan = tableSpan(cell.rowspan)
        if occupiedUntil.count < column + colspan {
          occupiedUntil.append(contentsOf: Array(repeating: 0, count: column + colspan - occupiedUntil.count))
        }

        placements.append(TablePlacement(
          row: rowIndex,
          cellIndex: cellIndex,
          column: column,
          colspan: colspan,
          rowspan: rowspan,
          cell: cell
        ))

        for offset in 0..<colspan {
          occupiedUntil[column + offset] = max(occupiedUntil[column + offset], rowIndex + rowspan)
        }
        column += colspan
      }
    }

    return placements
  }

  private static func tableSpan(_ value: Int32) -> Int {
    max(1, min(50, Int(value == 0 ? 1 : value)))
  }

  private static func tableColumnX(_ widths: [CGFloat], column: Int) -> CGFloat {
    guard column > 0 else { return 0 }
    return widths.prefix(min(column, widths.count)).reduce(CGFloat(0), +)
  }

  private static func tableColumnWidth(_ widths: [CGFloat], column: Int, span: Int) -> CGFloat {
    guard !widths.isEmpty else { return tableMinColumnWidth }
    let end = min(widths.count, column + max(1, span))
    guard column < end else { return tableMinColumnWidth }
    return widths[column..<end].reduce(CGFloat(0), +)
  }

  private static func tableRowOrigins(_ heights: [CGFloat]) -> [CGFloat] {
    var origins: [CGFloat] = []
    var y = CGFloat(0)
    for height in heights {
      origins.append(y)
      y += height
    }
    return origins
  }

  private static func heightForBlock(
    _ block: RichBlock,
    id: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> CGFloat {
    switch block.block {
    case let .paragraph(value):
      return textHeight(value.text, width: width, font: style.baseFont, style: style)
    case let .heading(value):
      return textHeight(
        value.text,
        width: width,
        font: .systemFont(ofSize: style.baseFont.pointSize + headingDelta(value.level), weight: .semibold),
        style: style
      )
    case let .list(value):
      let metrics = listMetrics(for: value, width: width)
      return value.items.enumerated().reduce(CGFloat(0)) { total, pair in
        let itemHeight = blocksHeight(
          pair.element.blocks,
          path: "\(id).\(pair.offset)",
          width: metrics.childWidth,
          style: style,
          state: state
        )
        return total + itemHeight + (pair.offset == value.items.count - 1 ? 0 : 6)
      }
    case let .listItem(value):
      return blocksHeight(value.blocks, path: "\(id).item", width: width, style: style, state: state)
    case let .quote(value):
      return quoteLayout(for: value, id: id, width: width, style: style, state: state).layout.size.height
    case let .code(value):
      return codeLayout(for: value, width: width, style: style).size.height
    case .divider:
      return 9
    case let .thinking(value):
      return collapsibleLayout(
        blocks: value.blocks,
        path: "\(id).thinking",
        width: width,
        expanded: state.isExpanded(id: id, defaultExpanded: !value.initiallyCollapsed),
        style: style,
        state: state
      ).layout.size.height
    case let .details(value):
      return collapsibleLayout(
        blocks: value.blocks,
        path: "\(id).details",
        width: width,
        expanded: state.isExpanded(id: id, defaultExpanded: value.initiallyOpen),
        style: style,
        state: state
      ).layout.size.height
    case let .photo(value):
      return mediaHeight(value.media, caption: value.caption, width: width, style: style)
    case let .video(value):
      return mediaHeight(value.media, caption: value.caption, width: width, style: style)
    case let .document(value):
      return documentLayout(for: value.media, caption: value.caption, width: width, style: style).size.height
    case let .audio(value):
      return audioLayout(for: value, width: width, style: style).size.height
    case let .table(value):
      return tableLayout(for: value, width: width, style: style).size.height
    case let .math(value):
      return measure(value.hasFallback ? value.fallback : value.source, width: max(1, width - 20), font: style.codeFont).height + 20
    case let .map(value):
      return 54 + (value.caption.isEmpty ? 0 : textHeight(value.caption, width: width, font: style.baseFont, style: style) + 6)
    case let .embed(value):
      return embedLayout(for: value, width: width, style: style).size.height
    case let .embedPost(value):
      return embedPostLayout(for: value, id: id, width: width, style: style, state: state).layout.size.height
    case let .linkPreview(value):
      return linkPreviewLayout(for: value, width: width, style: style).size.height
    case let .collage(value):
      let itemWidth = max(1, (width - 6) / 2)
      let itemHeights = value.items.enumerated().map { itemIndex, item in
        heightForBlock(item, id: "\(id).collage.\(itemIndex)", width: itemWidth, style: style, state: state)
      }
      let rows = stride(from: 0, to: itemHeights.count, by: 2).map { index in
        max(itemHeights[index], index + 1 < itemHeights.count ? itemHeights[index + 1] : 0)
      }
      let gridHeight = rows.reduce(CGFloat(0), +) + CGFloat(max(0, rows.count - 1)) * 6
      let captionHeight = value.caption.isEmpty ? 0 : textHeight(value.caption, width: width, font: style.baseFont, style: style) + 6
      return gridHeight + captionHeight
    case nil:
      return 0
    }
  }

  private static func blocksLayout(
    _ blocks: [RichBlock],
    path: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> RichBlocksLayoutPlan {
    var items: [RichBlockLayoutItem] = []
    var y = CGFloat(0)

    for (index, block) in blocks.enumerated() {
      let node = RichBlockNode(block: block, index: index, path: path)
      let plan = blockLayout(
        block,
        node: node,
        width: width,
        style: style,
        state: state
      )
      items.append(
        RichBlockLayoutItem(
          id: node.id,
          node: node,
          frame: CGRect(x: 0, y: y, width: width, height: plan.height),
          children: plan.children,
          mediaLayout: plan.media,
          embedLayout: plan.embed,
          embedPostLayout: plan.embedPost,
          linkPreviewLayout: plan.linkPreview,
          quoteLayout: plan.quote,
          collapsibleLayout: plan.collapsible,
          tableLayout: plan.table
        )
      )
      y += plan.height
      if index != blocks.count - 1 {
        y += 8
      }
    }

    return RichBlocksLayoutPlan(
      size: CGSize(width: width, height: ceil(max(1, y))),
      items: items
    )
  }

  private static func blockLayout(
    _ block: RichBlock,
    node: RichBlockNode,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> (
    height: CGFloat,
    children: [String: RichBlocksLayoutPlan],
    media: RichMediaLayoutPlan?,
    embed: RichEmbedLayoutPlan?,
    embedPost: RichEmbedPostLayoutPlan?,
    linkPreview: RichLinkPreviewLayoutPlan?,
    quote: RichQuoteLayoutPlan?,
    collapsible: RichCollapsibleLayoutPlan?,
    table: RichTableLayoutPlan?
  ) {
    switch block.block {
    case let .list(value):
      let metrics = listMetrics(for: value, width: width)
      var children: [String: RichBlocksLayoutPlan] = [:]
      for (index, item) in value.items.enumerated() {
        let itemID = "\(node.id).\(index)"
        children[itemID] = blocksLayout(
          item.blocks,
          path: itemID,
          width: metrics.childWidth,
          style: style,
          state: state
        )
      }
      return (heightForBlock(block, id: node.id, width: width, style: style, state: state), children, nil, nil, nil, nil, nil, nil, nil)
    case let .listItem(value):
      let child = blocksLayout(
        value.blocks,
        path: "\(node.id).item",
        width: width,
        style: style,
        state: state
      )
      return (child.size.height, ["item": child], nil, nil, nil, nil, nil, nil, nil)
    case let .quote(value):
      let measured = quoteLayout(for: value, id: node.id, width: width, style: style, state: state)
      return (measured.layout.size.height, ["quote": measured.child], nil, nil, nil, nil, measured.layout, nil, nil)
    case let .thinking(value):
      let measured = collapsibleLayout(
        blocks: value.blocks,
        path: "\(node.id).thinking",
        width: width,
        expanded: state.isExpanded(id: node.id, defaultExpanded: !value.initiallyCollapsed),
        style: style,
        state: state
      )
      var children: [String: RichBlocksLayoutPlan] = [:]
      if let child = measured.child {
        children["thinking"] = child
      }
      return (measured.layout.size.height, children, nil, nil, nil, nil, nil, measured.layout, nil)
    case let .details(value):
      let measured = collapsibleLayout(
        blocks: value.blocks,
        path: "\(node.id).details",
        width: width,
        expanded: state.isExpanded(id: node.id, defaultExpanded: value.initiallyOpen),
        style: style,
        state: state
      )
      var children: [String: RichBlocksLayoutPlan] = [:]
      if let child = measured.child {
        children["details"] = child
      }
      return (measured.layout.size.height, children, nil, nil, nil, nil, nil, measured.layout, nil)
    case let .photo(value):
      let media = mediaLayout(for: value.media, caption: value.caption, width: width, style: style)
      return (media.size.height, [:], media, nil, nil, nil, nil, nil, nil)
    case let .video(value):
      let media = mediaLayout(for: value.media, caption: value.caption, width: width, style: style)
      return (media.size.height, [:], media, nil, nil, nil, nil, nil, nil)
    case let .document(value):
      let media = documentLayout(for: value.media, caption: value.caption, width: width, style: style)
      return (media.size.height, [:], media, nil, nil, nil, nil, nil, nil)
    case let .audio(value):
      let media = audioLayout(for: value, width: width, style: style)
      return (media.size.height, [:], media, nil, nil, nil, nil, nil, nil)
    case let .table(value):
      let table = tableLayout(for: value, width: width, style: style)
      return (table.size.height, [:], nil, nil, nil, nil, nil, nil, table)
    case let .linkPreview(value):
      let linkPreview = linkPreviewLayout(for: value, width: width, style: style)
      return (linkPreview.size.height, [:], nil, nil, nil, linkPreview, nil, nil, nil)
    case let .embed(value):
      let embed = embedLayout(for: value, width: width, style: style)
      return (embed.size.height, [:], nil, embed, nil, nil, nil, nil, nil)
    case let .embedPost(value):
      let measured = embedPostLayout(for: value, id: node.id, width: width, style: style, state: state)
      var children: [String: RichBlocksLayoutPlan] = [:]
      if let child = measured.child {
        children["post"] = child
      }
      return (measured.layout.size.height, children, nil, nil, measured.layout, nil, nil, nil, nil)
    case let .collage(value):
      let childWidth = max(1, (width - 6) / 2)
      var children: [String: RichBlocksLayoutPlan] = [:]
      for (index, item) in value.items.enumerated() {
        let itemID = "\(node.id).collage.\(index)"
        children[itemID] = blocksLayout(
          [item],
          path: "\(node.id).collage",
          width: childWidth,
          style: style,
          state: state
        )
      }
      return (heightForBlock(block, id: node.id, width: width, style: style, state: state), children, nil, nil, nil, nil, nil, nil, nil)
    default:
      return (heightForBlock(block, id: node.id, width: width, style: style, state: state), [:], nil, nil, nil, nil, nil, nil, nil)
    }
  }

  private static func blocksHeight(
    _ blocks: [RichBlock],
    path: String,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> CGFloat {
    blocks.enumerated().reduce(CGFloat(0)) { total, pair in
      let id = pair.element.blockID.isEmpty ? "\(path).\(pair.offset)" : pair.element.blockID
      return total + heightForBlock(pair.element, id: id, width: width, style: style, state: state)
        + (pair.offset == blocks.count - 1 ? 0 : 8)
    }
  }

  static func codeLayout(
    for block: RichCodeBlock,
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> RichCodeLayoutPlan {
    let hasLanguage = block.hasLanguage && !block.language.isEmpty
    let headerHeight: CGFloat = hasLanguage ? 24 : 28
    let text = block.text.isEmpty ? " " : block.text
    let textWidth = max(1, width - 20)
    let measured = measure(
      RichCodeBlockText.attributedString(text, font: style.codeFont),
      width: textWidth
    )
    let textFrame = CGRect(
      x: 10,
      y: headerHeight,
      width: textWidth,
      height: max(1, measured.height)
    )
    let size = CGSize(width: width, height: textFrame.maxY + 8)

    return RichCodeLayoutPlan(
      size: size,
      languageFrame: hasLanguage
        ? CGRect(x: 10, y: 6, width: max(1, width - 48), height: 14)
        : nil,
      copyFrame: CGRect(x: max(0, width - 30), y: 4, width: 22, height: 20),
      textFrame: textFrame
    )
  }

  static func embedPostChildWidth(for width: CGFloat) -> CGFloat {
    max(1, width - 20)
  }

  private static func mediaHeight(
    _ media: RichMediaRef,
    caption: [RichText],
    width: CGFloat,
    style: RichMessageBlockStyle
  ) -> CGFloat {
    let hasCaption = !caption.renderedPlainText.isEmpty
    let mediaSize = mediaSize(for: media, availableWidth: width, hasCaption: hasCaption)
    let captionHeight = hasCaption ? textHeight(caption, width: mediaSize.width, font: style.baseFont, style: style) + 6 : 0
    return mediaSize.height + captionHeight
  }

  private static func textHeight(
    _ nodes: [RichText],
    width: CGFloat,
    font: NSFont,
    style: RichMessageBlockStyle
  ) -> CGFloat {
    let attributed = RichTextAttributedStringBuilder.nsAttributedString(nodes: nodes, font: font, style: style)
    return measure(attributed, width: width).height
  }

  private static func textSize(
    _ nodes: [RichText],
    width: CGFloat,
    font: NSFont,
    style: RichMessageBlockStyle
  ) -> CGSize {
    let attributed = RichTextAttributedStringBuilder.nsAttributedString(nodes: nodes, font: font, style: style)
    return measure(attributed, width: width)
  }

  private static func verticalTextOffset(for cell: RichTableCell, rowHeight: CGFloat, textHeight: CGFloat) -> CGFloat {
    let available = max(0, rowHeight - textHeight)
    switch cell.hasValign ? cell.valign : .verticalAlignTop {
    case .verticalAlignMiddle:
      return ceil(available / 2)
    case .verticalAlignBottom:
      return max(tableCellVerticalPadding, available - tableCellVerticalPadding)
    default:
      return tableCellVerticalPadding
    }
  }

  private static func measure(_ text: String, width: CGFloat, font: NSFont) -> CGSize {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    return measure(attributed, width: width)
  }

  private static func measure(_ attributed: NSAttributedString, width: CGFloat) -> CGSize {
    let rect = attributed.boundingRect(
      with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return CGSize(width: ceil(rect.width), height: ceil(rect.height))
  }

  static func linkPreviewAttributedString(
    for block: RichLinkPreviewBlock,
    style: RichMessageBlockStyle
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2

    let lines: [(String, [NSAttributedString.Key: Any])] = [
      (
        block.siteName,
        [
          .font: NSFont.systemFont(ofSize: max(11, style.baseFont.pointSize - 2), weight: .medium),
          .foregroundColor: style.secondary,
          .paragraphStyle: paragraph,
        ]
      ),
      (
        block.hasTitle ? block.title : block.url,
        [
          .font: NSFont.systemFont(ofSize: style.baseFont.pointSize, weight: .semibold),
          .foregroundColor: style.primary,
          .paragraphStyle: paragraph,
        ]
      ),
      (
        block.description_p,
        [
          .font: NSFont.systemFont(ofSize: max(11, style.baseFont.pointSize - 1)),
          .foregroundColor: style.secondary,
          .paragraphStyle: paragraph,
        ]
      ),
      (
        block.hasDisplayURL ? block.displayURL : block.url,
        [
          .font: NSFont.systemFont(ofSize: max(10, style.baseFont.pointSize - 3)),
          .foregroundColor: style.link,
          .paragraphStyle: paragraph,
        ]
      ),
    ]

    let result = NSMutableAttributedString()
    for (text, attrs) in lines where !text.isEmpty {
      if result.length > 0 {
        result.append(NSAttributedString(string: "\n", attributes: attrs))
      }
      result.append(NSAttributedString(string: text, attributes: attrs))
    }

    if result.length == 0 {
      result.append(NSAttributedString(string: " ", attributes: [
        .font: style.baseFont,
        .foregroundColor: style.primary,
        .paragraphStyle: paragraph,
      ]))
    }

    return result
  }

  private static func headingDelta(_ level: Int32) -> CGFloat {
    switch level {
    case 1: 7
    case 2: 5
    case 3: 3
    default: 1
    }
  }
}

enum RichTextAttributedStringBuilder {
  static func attributedString(
    nodes: [RichText],
    font: NSFont,
    style: RichMessageBlockStyle,
    spoilerBaseID: String? = nil,
    state: RichMessageBlockStateSnapshot = .initial
  ) -> AttributedString {
    AttributedString(nsAttributedString(nodes: nodes, font: font, style: style, spoilerBaseID: spoilerBaseID, state: state))
  }

  static func nsAttributedString(
    nodes: [RichText],
    font: NSFont,
    style: RichMessageBlockStyle,
    spoilerBaseID: String? = nil,
    state: RichMessageBlockStateSnapshot = .initial
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for node in nodes {
      append(node, to: result, inheritedStyles: [], inheritedURL: nil, font: font, style: style)
    }
    if result.length == 0 {
      result.append(NSAttributedString(string: " ", attributes: [.font: font, .foregroundColor: style.primary]))
    }
    applySpoilers(to: result, baseID: spoilerBaseID, state: state, style: style)
    return result
  }

  private static func append(
    _ node: RichText,
    to result: NSMutableAttributedString,
    inheritedStyles: [RichTextStyle],
    inheritedURL: String?,
    font: NSFont,
    style: RichMessageBlockStyle
  ) {
    let styles = merge(inheritedStyles, node.styles)
    let url = node.hasURL ? node.url : inheritedURL
    if !node.text.isEmpty {
      result.append(NSAttributedString(string: node.text, attributes: attributes(for: styles, url: url, font: font, style: style)))
    }
    for child in node.children {
      append(child, to: result, inheritedStyles: styles, inheritedURL: url, font: font, style: style)
    }
  }

  private static func attributes(
    for styles: [RichTextStyle],
    url: String?,
    font: NSFont,
    style: RichMessageBlockStyle
  ) -> [NSAttributedString.Key: Any] {
    let effectiveFont = effectiveFont(base: font, styles: styles)
    var attrs: [NSAttributedString.Key: Any] = [
      .font: effectiveFont,
      .foregroundColor: style.primary,
    ]
    if styles.contains(.styleUnderline) {
      attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if styles.contains(.styleStrikethrough) {
      attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    if styles.contains(.styleCode) {
      attrs[.font] = style.codeFont.withSize(font.pointSize * 0.94)
      attrs[.backgroundColor] = style.codeFill
    }
    if styles.contains(.styleSpoiler) {
      attrs[.richSpoiler] = true
    }
    if let url, let linkURL = URL(string: url) {
      attrs[.link] = linkURL
      attrs[.foregroundColor] = style.link
    }
    return attrs
  }

  private static func applySpoilers(
    to result: NSMutableAttributedString,
    baseID: String?,
    state: RichMessageBlockStateSnapshot,
    style: RichMessageBlockStyle
  ) {
    guard result.length > 0 else { return }

    let ranges = spoilerRanges(in: result)
    for (index, range) in ranges.enumerated() {
      let spoilerID = baseID.map { "\($0).spoiler.\(index)" }
      let revealed = spoilerID.map { state.isSpoilerRevealed(id: $0) } ?? false
      if let spoilerID {
        result.addAttribute(.richSpoilerID, value: spoilerID, range: range)
      }
      result.addAttribute(.richSpoilerHidden, value: !revealed, range: range)

      if revealed {
        result.addAttribute(.backgroundColor, value: style.primary.withAlphaComponent(0.08), range: range)
        continue
      }

      result.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
      result.addAttribute(.backgroundColor, value: style.primary.withAlphaComponent(0.18), range: range)
      result.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
    }
  }

  private static func spoilerRanges(in result: NSAttributedString) -> [NSRange] {
    guard result.length > 0 else { return [] }

    var ranges: [NSRange] = []
    var start: Int?

    for index in 0..<result.length {
      let isSpoiler = (result.attribute(.richSpoiler, at: index, effectiveRange: nil) as? Bool) == true
      if isSpoiler, start == nil {
        start = index
      }

      let isLast = index == result.length - 1
      if let runStart = start, (!isSpoiler || isLast) {
        let end = isSpoiler && isLast ? index + 1 : index
        if end > runStart {
          ranges.append(NSRange(location: runStart, length: end - runStart))
        }
        start = isSpoiler ? index : nil
      }
    }

    return ranges
  }

  private static func effectiveFont(base: NSFont, styles: [RichTextStyle]) -> NSFont {
    var font = base
    if styles.contains(.styleBold) {
      font = .systemFont(ofSize: base.pointSize, weight: .semibold)
    }
    if styles.contains(.styleItalic) {
      font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
    return font
  }

  private static func merge(_ base: [RichTextStyle], _ extra: [RichTextStyle]) -> [RichTextStyle] {
    var result = base
    for style in extra where !result.contains(style) {
      result.append(style)
    }
    return result
  }
}

extension NSAttributedString.Key {
  static let richSpoiler = NSAttributedString.Key("inline.richText.spoiler")
  static let richSpoilerID = NSAttributedString.Key("inline.richText.spoilerID")
  static let richSpoilerHidden = NSAttributedString.Key("inline.richText.spoilerHidden")
}

private func layoutDirection(for direction: RichDirection) -> LayoutDirection {
  direction == .directionRtl ? .rightToLeft : .leftToRight
}

private func alignment(for direction: RichDirection) -> Alignment {
  direction == .directionRtl ? .trailing : .leading
}

private func alignment(for align: RichHorizontalAlign) -> Alignment {
  switch align {
  case .horizontalAlignCenter:
    return .center
  case .horizontalAlignRight:
    return .trailing
  default:
    return .leading
  }
}
