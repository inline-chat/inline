import InlineKit
import InlineSearch
import InlineUI
import SwiftUI

/// State shared by the chat pane and its find bar.
///
/// Like Telegram, typing shows the matches as message previews under the field. While they
/// show, moving through them does not scroll the chat; hiding them jumps to the chosen match.
@MainActor
@Observable
final class InChatSearchBarState {
  /// Increments to move focus back to the field (⌘F while search is open).
  var focusRevision = 0

  private(set) var showsResults = false

  /// Scrolls the chat to a match.
  @ObservationIgnored var jump: ((InChatSearchSelection) -> Void)?
  @ObservationIgnored private var pending: InChatSearchSelection?

  /// Shows the match now, or once the previews are hidden.
  func show(_ selection: InChatSearchSelection) {
    if showsResults {
      pending = selection
    } else {
      pending = nil
      jump?(selection)
    }
  }

  /// A new query shows its previews; the old query's chosen match is dropped, not jumped to.
  func queryChanged(isEmpty: Bool) {
    pending = nil
    showsResults = !isEmpty
  }

  /// Hiding the previews jumps to the match chosen while they showed.
  func setShowsResults(_ shows: Bool) {
    guard shows != showsResults else { return }
    showsResults = shows
    guard !shows, let pending else { return }
    self.pending = nil
    jump?(pending)
  }
}

/// Floating find bar over the top of a chat: field, "3 of 47", older/newer, and message
/// previews of every match in a panel below.
struct InChatSearchBar: View {
  static let fieldHeight: CGFloat = 36

  let model: InChatSearchViewModel
  let state: InChatSearchBarState
  let onClose: () -> Void

  @State private var text = ""
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    InChatSearchGlassContainer {
      VStack(spacing: 6) {
        field
        if state.showsResults, !model.query.isEmpty {
          InChatSearchResultsPanel(model: model) { messageId in
            model.select(messageId: messageId)
            state.setShowsResults(false)
          }
          .transition(.opacity)
        }
      }
      // The hosting view grows and shrinks with the panel; pinned to its top, the field
      // never moves (centered, it slid up and down as the panel came and went).
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .animation(.easeOut(duration: 0.15), value: state.showsResults)
    .onChange(of: text) { _, newValue in
      let previousQuery = model.query
      model.setQuery(newValue)
      // Spaces at either end do not change the query or its results.
      guard model.query != previousQuery else { return }
      state.queryChanged(isEmpty: model.query.isEmpty)
    }
    .onChange(of: state.focusRevision) { _, _ in
      isFieldFocused = true
    }
    .onAppear {
      text = model.query
      isFieldFocused = true
    }
  }

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search in Chat", text: $text)
        .textFieldStyle(.plain)
        .focused($isFieldFocused)
        .onSubmit(submit)
        .onKeyPress(.return, phases: .down) { press in
          guard press.modifiers.contains(.shift) else { return .ignored }
          newer()
          return .handled
        }
        // Over the previews the arrows move through the list (newest on top); over the chat
        // up goes to older matches, like Telegram.
        .onKeyPress(.upArrow) {
          if state.showsResults { model.goNewer() } else { model.goOlder() }
          return .handled
        }
        .onKeyPress(.downArrow) {
          if state.showsResults { model.goOlder() } else { model.goNewer() }
          return .handled
        }
        .onExitCommand(perform: onClose)

      if model.isSearching || model.isCounting {
        ProgressView()
          .controlSize(.small)
      }

      if let counter = state.showsResults ? model.resultsText : model.counterText {
        Text(counter)
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      }

      HStack(spacing: 0) {
        Button(action: older) {
          InChatSearchIcon(systemName: "chevron.up")
        }
        .disabled(!model.canGoOlder)
        .help("Older Match (⌘G)")
        .accessibilityLabel("Older Match")

        Button(action: newer) {
          InChatSearchIcon(systemName: "chevron.down")
        }
        .disabled(!model.canGoNewer)
        .help("Newer Match (⇧⌘G)")
        .accessibilityLabel("Newer Match")

        Button {
          state.setShowsResults(!state.showsResults)
        } label: {
          InChatSearchIcon(systemName: state.showsResults ? "bubble.left" : "list.bullet")
        }
        .disabled(model.query.isEmpty)
        .help(state.showsResults ? "Show in Chat" : "Show as List")
        .accessibilityLabel(state.showsResults ? "Show in Chat" : "Show as List")

        // Escape closes from the field only; the composer keeps Escape for its own actions.
        Button(action: onClose) {
          InChatSearchIcon(systemName: "xmark")
        }
        .help("Close Search (Esc)")
        .accessibilityLabel("Close Search")
      }
      .buttonStyle(InChatSearchIconButtonStyle())
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .frame(height: Self.fieldHeight)
    .inChatSearchGlass(in: Capsule(), interactive: true)
  }

  /// Return jumps to the highlighted preview, or steps older over the chat.
  private func submit() {
    if state.showsResults, !model.matches.isEmpty {
      state.setShowsResults(false)
    } else {
      model.goOlder()
    }
  }

  private func older() {
    model.goOlder()
    state.setShowsResults(false)
  }

  private func newer() {
    model.goNewer()
    state.setShowsResults(false)
  }
}

/// Message previews for every match, newest first, under the find bar.
struct InChatSearchResultsPanel: View {
  let model: InChatSearchViewModel
  let onChoose: (Int64) -> Void

  private static let rowHeight: CGFloat = 54
  private static let footerHeight: CGFloat = 30
  private static let maxVisibleRows = 7
  private static let inset: CGFloat = 6
  /// Concentric corners: the highlight's radius is the panel's minus the gap between them.
  private static let cornerRadius: CGFloat = 18
  private static let rowCornerRadius: CGFloat = cornerRadius - inset

  var body: some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
      .inChatSearchGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
  }

  @ViewBuilder
  private var content: some View {
    if model.matches.isEmpty {
      Group {
        if model.isSearching {
          ProgressView().controlSize(.small)
        } else if model.remoteFailed {
          HStack {
            Text("Couldn’t search older messages.").foregroundStyle(.secondary)
            Button("Retry", action: model.retry)
          }
        } else {
          Text("No messages found").foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 0, idealHeight: 52, maxHeight: 52)
      .clipped()
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.matches) { hit in
              Button {
                onChoose(hit.messageId)
              } label: {
                InChatSearchResultRow(hit: hit, snippet: model.snippet(for: hit), query: model.query)
                  .padding(.horizontal, 8)
                  .frame(height: Self.rowHeight)
              }
              .buttonStyle(InChatSearchRowButtonStyle(
                isSelected: hit.messageId == model.currentMessageId,
                cornerRadius: Self.rowCornerRadius
              ))
              .id(hit.messageId)
              .onAppear { model.loadMoreIfNeeded(after: hit) }
            }
            footer
          }
        }
        // Ideal height fits up to seven rows; a short window shrinks the list to whatever fits
        // above the composer, so the panel never covers the composer's glass.
        // Margins, not padding, so scrolling a row into view keeps the same gap from the
        // panel's edge as the sides have.
        .contentMargins(Self.inset, for: .scrollContent)
        .frame(minHeight: 0, idealHeight: listHeight, maxHeight: listHeight)
        .modifier(InChatSearchScrollEdgeEffectHidden())
        .onChange(of: model.currentMessageId) { _, messageId in
          guard let messageId else { return }
          proxy.scrollTo(messageId)
        }
      }
    }
  }

  @ViewBuilder
  private var footer: some View {
    if model.isLoadingMore {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Searching older messages…").foregroundStyle(.secondary)
      }
      .font(.callout)
      .frame(height: Self.footerHeight)
    } else if model.remoteFailed {
      HStack {
        Text("Showing results on this Mac.").foregroundStyle(.secondary)
        Button("Retry", action: model.retry)
      }
      .font(.callout)
      .frame(height: Self.footerHeight)
    }
  }

  private var listHeight: CGFloat {
    let rows = CGFloat(min(model.matches.count, Self.maxVisibleRows))
    let footer = model.isLoadingMore || model.remoteFailed ? Self.footerHeight : 0
    return rows * Self.rowHeight + footer + Self.inset * 2
  }
}

/// A toolbar-size symbol (13 pt body font, regular weight) in a fixed square, so every
/// button has the same footprint. SF Symbols at one font size are optically matched.
private struct InChatSearchIcon: View {
  let systemName: String

  var body: some View {
    Image(systemName: systemName)
      .font(.body)
      .imageScale(.medium)
      .frame(width: 24, height: 24)
  }
}

/// Neutral icon buttons: primary when enabled, gray when disabled, dimmed while pressed.
private struct InChatSearchIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    InChatSearchIconButton(configuration: configuration)
  }
}

/// A soft gray circle under the icon on hover, a bit darker while pressed; disabled
/// buttons show none.
private struct InChatSearchIconButton: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background {
        Circle()
          .fill(Color.primary.opacity(fillOpacity))
      }
      .contentShape(Circle())
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
  }

  private var fillOpacity: Double {
    guard isEnabled else { return 0 }
    if configuration.isPressed { return 0.16 }
    return isHovered ? 0.08 : 0
  }
}

/// A result row: the selected one is a clear gray with a hairline edge (neutral like the bar's
/// buttons; the system accent is blue for most people), hover shows a lighter gray.
private struct InChatSearchRowButtonStyle: ButtonStyle {
  let isSelected: Bool
  let cornerRadius: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    InChatSearchRowButton(configuration: configuration, isSelected: isSelected, cornerRadius: cornerRadius)
  }
}

private struct InChatSearchRowButton: View {
  let configuration: ButtonStyleConfiguration
  let isSelected: Bool
  let cornerRadius: CGFloat
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    configuration.label
      .background {
        shape
          .fill(Color.primary.opacity(fillOpacity))
          .overlay {
            if isSelected {
              shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
          }
      }
      .contentShape(shape)
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }

  private var fillOpacity: Double {
    if isSelected || configuration.isPressed { return 0.14 }
    return isHovered ? 0.06 : 0
  }
}

/// No scroll edge fade inside the glass panel: on macOS 26 it paints a frosted band.
private struct InChatSearchScrollEdgeEffectHidden: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.scrollEdgeEffectHidden(true, for: .all)
    } else {
      content
    }
  }
}

/// Renders the bar's glass surfaces together on macOS 26.
private struct InChatSearchGlassContainer<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    if #available(macOS 26.0, *) {
      // Zero spacing: the field and panel render together but never melt into one shape.
      GlassEffectContainer(spacing: 0) { content }
    } else {
      content
    }
  }
}

private extension View {
  /// The Cmd+K / menu material: regular Liquid Glass over a light tint on macOS 26, the popover
  /// material before it. `interactive` adds the press response for controls.
  func inChatSearchGlass(in shape: some Shape, interactive: Bool = false) -> some View {
    modifier(InChatSearchGlassMaterial(shape: shape, interactive: interactive))
  }
}

private struct InChatSearchGlassMaterial<S: Shape>: ViewModifier {
  let shape: S
  let interactive: Bool
  @Environment(\.colorScheme) private var colorScheme

  /// The same tint Cmd+K uses under its glass.
  private var tint: Color {
    colorScheme == .dark ? Color.black.opacity(0.14) : Color.white.opacity(0.16)
  }

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .background(shape.fill(tint))
        .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      content
        .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
        .background(shape.fill(tint))
        .compositingGroup()
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
  }
}

struct InChatSearchResultRow: View {
  let hit: InChatSearchHit
  let snippet: String
  let query: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if let sender = hit.sender {
        UserAvatar(user: sender, size: 28)
      } else {
        Circle().fill(.quaternary).frame(width: 28, height: 28)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(hit.senderName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(InChatSearchDate.format(hit.date))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(InChatSearchSnippet.attributed(snippet, query: query))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .contentShape(Rectangle())
  }
}

enum InChatSearchSnippet {
  /// The snippet with each query word in primary color and semibold.
  static func attributed(_ snippet: String, query: String) -> AttributedString {
    var result = AttributedString(snippet)
    for word in query.split(whereSeparator: \.isWhitespace) {
      var searchStart = result.startIndex
      while searchStart < result.endIndex,
            let range = result[searchStart...].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive])
      {
        result[range].foregroundColor = .primary
        result[range].inlinePresentationIntent = .stronglyEmphasized
        searchStart = range.upperBound
      }
    }
    return result
  }
}

enum InChatSearchDate {
  static func format(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(date: .numeric, time: .omitted)
  }
}
