import AppKit
import InlineMacUI
import InlineUI
import MacTheme
import SwiftUI

/// Appearance › Messages: a live preview, message style, text size, and a
/// Customize sheet for fonts and spacing so the Appearance page stays short.
/// Every control applies immediately to open chats.
struct MessageTextSettingsSection: View {
  @ObservedObject var settings: AppSettings
  @State private var showsCustomization = false

  var body: some View {
    // Read through `settings` so SwiftUI re-renders on every change; the value
    // itself comes from the live snapshot the chats use.
    let _ = settings.chatTypographySource
    let typography = ChatTypography.current

    Section {
      MessageTextPreview(
        typography: typography,
        renderStyle: settings.messageRenderStyle,
        showsOtherScripts: !settings.chatFallbackFontFamily.isEmpty
      )
      .accessibilityHidden(true)

      LabeledContent {
        Picker("Message Style", selection: $settings.messageRenderStyle) {
          ForEach(MessageRenderStyle.allCases, id: \.self) { style in
            Text(style.title).tag(style)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 220, alignment: .trailing)
      } label: {
        SettingsRowLabel(
          .messageStyle,
          description: "Choose how messages are arranged in chats."
        )
      }
      .settingsSearchAnchor(.messageStyle)

      LabeledContent {
        MessageTextSizeSlider(settings: settings, pointSize: typography.pointSize)
      } label: {
        SettingsRowLabel(.fontSize)
      }
      .settingsSearchAnchor(.fontSize)

      LabeledContent {
        Button("Customize\u{2026}") {
          showsCustomization = true
        }
      } label: {
        SettingsRowLabel("Font & Spacing", dynamicDescription: Self.summary(typography))
      }
      .settingsSearchAnchor(.fonts)
    } header: {
      SettingsSectionHeader("Messages")
    } footer: {
      Text("Use \u{2318}+ and \u{2318}\u{2212} to change the size from any chat.")
        .foregroundStyle(.secondary)
        .font(.callout)
    }
    .sheet(isPresented: $showsCustomization) {
      MessageTextCustomizationSheet(settings: settings)
    }
  }

  /// One line naming the choices, so the row says what's set without opening it.
  static func summary(_ typography: ChatTypography) -> String {
    let font = typography.selectedSystemDesign?.title ?? typography.font.familyName ?? "System"
    var parts = [font, "\(lineSpacingTitle(typography.lineHeight)) spacing"]
    if let code = typography.codeFontFamilyName {
      parts.append("\(code) code")
    }
    return parts.joined(separator: " \u{00B7} ")
  }

  static func lineSpacingTitle(_ lineHeight: CGFloat) -> String {
    switch lineHeight {
    case 1.2: "Compact"
    case 1.28: "Standard"
    case 1.4: "Relaxed"
    case 1.55: "Spacious"
    default: "\(ChatTypography.format(lineHeight))\u{00D7}"
    }
  }
}

/// Font, fallback, code font and line spacing, with a live preview.
private struct MessageTextCustomizationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settings: AppSettings

  var body: some View {
    let _ = settings.chatTypographySource
    let typography = ChatTypography.current

    Form {
      Section {
        MessageTextPreview(
          typography: typography,
          renderStyle: settings.messageRenderStyle,
          showsOtherScripts: !settings.chatFallbackFontFamily.isEmpty
        )
        .accessibilityHidden(true)
      } header: {
        VStack(alignment: .leading, spacing: 3) {
          Text("Font & Spacing")
            .font(.headline)
          Text("Changes apply to open chats as you make them.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        LabeledContent {
          MessageFontMenu(settings: settings, typography: typography)
        } label: {
          SettingsRowLabel(.fonts)
        }

        LabeledContent {
          MessageFallbackFontMenu(settings: settings, typography: typography)
        } label: {
          SettingsRowLabel(
            .fallbackFont,
            description: "Used for characters the main font doesn\u{2019}t include, like other scripts."
          )
        }

        LabeledContent {
          MessageCodeFontMenu(settings: settings, typography: typography)
        } label: {
          SettingsRowLabel(.codeFont)
        }

        LabeledContent {
          Picker("Line Spacing", selection: lineSpacingSelection(typography)) {
            ForEach(lineSpacingOptions(typography), id: \.self) { lineHeight in
              Text(MessageTextSettingsSection.lineSpacingTitle(lineHeight)).tag(lineHeight)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        } label: {
          SettingsRowLabel(.lineSpacing)
        }
      }

      Section {
        HStack(spacing: 10) {
          Button("Restore Defaults") {
            settings.resetChatTextStyle()
          }
          .disabled(!settings.hasChatTextStyleOverrides)

          Spacer()

          Button("Done") {
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .settingsFormStyle()
    .frame(minWidth: 480, minHeight: 460)
  }

  private func lineSpacingSelection(_ typography: ChatTypography) -> Binding<CGFloat> {
    Binding(
      get: { typography.lineHeight },
      set: { settings.chatLineHeightValue = $0 }
    )
  }

  /// The presets, plus a hand-set value so the picker never shows a blank selection.
  private func lineSpacingOptions(_ typography: ChatTypography) -> [CGFloat] {
    var options = ChatTypography.lineHeightSteps
    if !options.contains(typography.lineHeight) {
      options.append(typography.lineHeight)
      options.sort()
    }
    return options
  }
}

// MARK: - Font

private enum MessageFontChoice: Hashable {
  case system(ChatTypography.SystemDesign)
  case family(String)
}

private struct MessageFontMenu: View {
  @ObservedObject var settings: AppSettings
  let typography: ChatTypography

  private var selection: MessageFontChoice {
    if let design = typography.selectedSystemDesign {
      return .system(design)
    }
    return .family(typography.font.familyName ?? typography.source.fontFamilies)
  }

  var body: some View {
    Menu {
      Picker("Font", selection: Binding(get: { selection }, set: select)) {
        ForEach(ChatTypography.SystemDesign.allCases, id: \.self) { design in
          Text(design.title).tag(MessageFontChoice.system(design))
        }
        if case let .family(family) = selection {
          Divider()
          Text(family).tag(MessageFontChoice.family(family))
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()

      Divider()

      Button("Show Fonts\u{2026}") {
        MessageFontPanelController.shared.show(selecting: typography.font) { font in
          applyPanelFont(font)
        }
      }
    } label: {
      Text(title)
    }
    .fixedSize()
  }

  private var title: String {
    switch selection {
    case let .system(design): design.title
    case let .family(family): family
    }
  }

  private func select(_ choice: MessageFontChoice) {
    switch choice {
    case .system(.standard):
      settings.chatPrimaryFontFamily = ""
    case let .system(design):
      settings.chatPrimaryFontFamily = design.token
    case let .family(family):
      settings.chatPrimaryFontFamily = family
    }
  }

  private func applyPanelFont(_ font: NSFont) {
    settings.chatPrimaryFontFamily = MessageFontPanelController.storedFamily(for: font)
    settings.chatPointSize = font.pointSize.rounded()
  }
}

// MARK: - Fallback font

private struct MessageFallbackFontMenu: View {
  @ObservedObject var settings: AppSettings
  let typography: ChatTypography

  var body: some View {
    let fallback = settings.chatFallbackFontFamily
    Menu {
      Picker("Fallback Font", selection: Binding(
        get: { fallback },
        set: { settings.chatFallbackFontFamily = $0 }
      )) {
        Text("None").tag("")
        if !fallback.isEmpty {
          Divider()
          Text(fallback).tag(fallback)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()

      Divider()

      Button("Show Fonts\u{2026}") {
        let current = NSFont(name: fallback, size: typography.pointSize)
          ?? NSFontManager.shared.font(
            withFamily: fallback, traits: [], weight: 5, size: typography.pointSize
          )
          ?? typography.font
        MessageFontPanelController.shared.show(selecting: current) { font in
          settings.chatFallbackFontFamily = MessageFontPanelController.storedFamily(for: font)
        }
      }
    } label: {
      Text(fallback.isEmpty ? "None" : fallback)
    }
    .fixedSize()
  }
}

// MARK: - Code font

private struct MessageCodeFontMenu: View {
  @ObservedObject var settings: AppSettings
  let typography: ChatTypography

  /// Installed monospaced families, read once when the menu first appears.
  @State private var families: [String] = []

  var body: some View {
    let selected = typography.codeFontFamilyName ?? ""
    Menu {
      Picker("Code Font", selection: Binding(
        get: { selected },
        set: { settings.chatCodeFontFamily = $0 }
      )) {
        Text("SF Mono").tag("")
        Divider()
        ForEach(options(selected: selected), id: \.self) { family in
          Text(family).tag(family)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()

      Divider()

      Button("Show Fonts\u{2026}") {
        MessageFontPanelController.shared.show(selecting: typography.codeFont(sized: typography.pointSize)) { font in
          let family = MessageFontPanelController.storedFamily(for: font)
          let systemMono = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular).familyName
          settings.chatCodeFontFamily = family == systemMono ? "" : family
        }
      }
    } label: {
      Text(selected.isEmpty ? "SF Mono" : selected)
    }
    .fixedSize()
    .onAppear {
      if families.isEmpty {
        families = ChatTypography.installedMonospacedFamilies()
      }
    }
  }

  private func options(selected: String) -> [String] {
    let systemMono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName
    var options = families.filter { $0 != systemMono }
    if !selected.isEmpty, !options.contains(selected) {
      options.append(selected)
      options.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    return options
  }
}

/// Drives the shared font panel (Format › Show Fonts in Mail and TextEdit) for
/// message text. Holds the font manager only while the panel is open, so the
/// composer's own font commands keep working afterwards.
@MainActor
final class MessageFontPanelController: NSObject, NSFontChanging {
  static let shared = MessageFontPanelController()

  private var onChange: ((NSFont) -> Void)?
  private var selectedFont: NSFont?
  private var closeObserver: NSObjectProtocol?

  /// The family to store for a font picked in the panel; empty for the system font.
  static func storedFamily(for font: NSFont) -> String {
    let systemFamily = NSFont.systemFont(ofSize: font.pointSize).familyName
    guard let family = font.familyName, family != systemFamily else { return "" }
    return family
  }

  func show(selecting font: NSFont, onChange: @escaping (NSFont) -> Void) {
    self.onChange = onChange
    selectedFont = font
    let manager = NSFontManager.shared
    manager.target = self
    manager.action = #selector(changeFont(_:))
    manager.setSelectedFont(font, isMultiple: false)

    let panel = manager.fontPanel(true)
    if closeObserver == nil, let panel {
      closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: panel,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.detach() }
      }
    }
    manager.orderFrontFontPanel(self)
  }

  func changeFont(_ sender: NSFontManager?) {
    guard let sender, let selectedFont else { return }
    let font = sender.convert(selectedFont)
    self.selectedFont = font
    onChange?(font)
  }

  func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
    [.collection, .face, .size]
  }

  private func detach() {
    if NSFontManager.shared.target === self {
      NSFontManager.shared.target = nil
    }
    onChange = nil
    selectedFont = nil
    if let closeObserver {
      NotificationCenter.default.removeObserver(closeObserver)
      self.closeObserver = nil
    }
  }
}

// MARK: - Size

private struct MessageTextSizeSlider: View {
  @ObservedObject var settings: AppSettings
  let pointSize: CGFloat

  private static let steps = ChatTypography.sizeSteps

  private var stepIndex: Binding<Double> {
    Binding(
      get: {
        let nearest = Self.steps.indices.min { abs(Self.steps[$0] - pointSize) < abs(Self.steps[$1] - pointSize) }
        return Double(nearest ?? 0)
      },
      set: { value in
        let index = min(max(Int(value.rounded()), 0), Self.steps.count - 1)
        guard Self.steps[index] != pointSize else { return }
        settings.chatPointSize = Self.steps[index]
      }
    )
  }

  var body: some View {
    HStack(spacing: 10) {
      Slider(value: stepIndex, in: 0 ... Double(Self.steps.count - 1), step: 1) {
        Text("Text Size")
      } minimumValueLabel: {
        Image(systemName: "textformat.size.smaller")
          .accessibilityLabel("Smaller")
      } maximumValueLabel: {
        Image(systemName: "textformat.size.larger")
          .accessibilityLabel("Larger")
      }
      .labelsHidden()
      .frame(width: 200)
      .accessibilityValue("\(ChatTypography.format(pointSize)) points")

      Text(sizeLabel)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minWidth: 52, alignment: .trailing)
    }
  }

  private var sizeLabel: String {
    pointSize == ChatTypography.defaultPointSize
      ? "Default"
      : "\(ChatTypography.format(pointSize)) pt"
  }
}

// MARK: - Preview

/// A short exchange drawn with the same font, size and line spacing the chats use.
/// A short conversation drawn like the chat: in Minimal, avatars, colored names
/// and times beside them; in Bubbles, bubbles with their time in the corner.
private struct MessageTextPreview: View {
  let typography: ChatTypography
  let renderStyle: MessageRenderStyle
  let showsOtherScripts: Bool

  private static let teammate = "Dena Park"
  private static let you = "Sam Lee"

  private var incoming: Text {
    Text("Did the new build fix the scroll jump? It felt a lot smoother in long threads on my side.")
  }

  private var followUp: Text {
    Text("No rush, just curious.")
  }

  private var outgoing: Text {
    let code = Text("v2.3")
      .font(Font(typography.codeFont(sized: ChatTypography.inlineCodePointSize(at: typography.pointSize))))
    return Text("Yes, it\u{2019}s gone. Shipping \(code) after lunch \u{1F680}")
  }

  private var otherScripts: Text {
    Text("\u{0633}\u{0644}\u{0627}\u{0645} \u{00B7} \u{3053}\u{3093}\u{306B}\u{3061}\u{306F} \u{00B7} \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}")
  }

  var body: some View {
    Group {
      switch renderStyle {
      case .bubble:
        VStack(spacing: 4) {
          bubble(incoming, time: "10:41", isOutgoing: false)
          bubble(showsOtherScripts ? otherScripts : followUp, time: "10:41", isOutgoing: false)
          bubble(outgoing, time: "10:43", isOutgoing: true)
            .padding(.top, Theme.messageGroupSpacing - 4)
        }
      case .minimal:
        VStack(alignment: .leading, spacing: MessageSizeCalculator.minimalGroupSpacing) {
          minimalGroup(name: Self.teammate, time: "10:41", messages: [
            incoming, showsOtherScripts ? otherScripts : followUp,
          ])
          minimalGroup(name: Self.you, time: "10:43", messages: [outgoing])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(
      Color(nsColor: Theme.windowContentBackgroundColor),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
    )
    .animation(.snappy(duration: 0.18), value: typography.revision)
    .animation(.snappy(duration: 0.18), value: renderStyle)
  }

  private func messageText(_ text: Text, color: Color) -> some View {
    text
      .font(Font(typography.font))
      .lineSpacing(typography.lineSpacing)
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var timeFont: Font { Font(MessageTimeAndState.font) }

  // MARK: Bubbles

  private func bubble(_ text: Text, time: String, isOutgoing: Bool) -> some View {
    let textColor = isOutgoing ? Color.white : Color(nsColor: Theme.messageBubbleSecondaryTextColor)
    let timeColor = isOutgoing ? Color.white.opacity(0.7) : Color(nsColor: .tertiaryLabelColor)
    // Room for the time on the last line, the way the chat wraps around it.
    let reserve = Text("\u{2002}\(time)").font(timeFont).foregroundStyle(.clear)
    return messageText(Text("\(text)\(reserve)"), color: textColor)
      .overlay(alignment: .bottomTrailing) {
        Text(time)
          .font(timeFont)
          .foregroundStyle(timeColor)
          .offset(y: 1)
      }
      .padding(.horizontal, Theme.messageBubbleContentHorizontalInset)
      .padding(.vertical, Theme.messageTextOnlyVerticalInsets)
      .background(
        Color(nsColor: isOutgoing ? Theme.messageBubblePrimaryBgColor : Theme.messageBubbleSecondaryBgColor),
        in: RoundedRectangle(cornerRadius: Theme.messageBubbleCornerRadius, style: .continuous)
      )
      .frame(maxWidth: 300, alignment: isOutgoing ? .trailing : .leading)
      .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
  }

  // MARK: Minimal

  /// A sender's run: avatar and name with the time beside it, then each message
  /// in the same text column.
  private func minimalGroup(name: String, time: String, messages: [Text]) -> some View {
    HStack(alignment: .top, spacing: Theme.messageHorizontalStackSpacing) {
      InitialsCircle(name: name, size: MessageSizeCalculator.minimalAvatarSize)
        .frame(
          width: MessageSizeCalculator.minimalAvatarSize,
          height: MessageSizeCalculator.minimalAvatarSize
        )
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: MessageSizeCalculator.minimalInlineTimeSpacing) {
          Text(name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(InitialsCircle.ColorPalette.color(for: name))
          Text(time)
            .font(timeFont)
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .frame(height: MessageSizeCalculator.minimalNameHeight)
        ForEach(messages.indices, id: \.self) { index in
          messageText(messages[index], color: Color(nsColor: .labelColor))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
