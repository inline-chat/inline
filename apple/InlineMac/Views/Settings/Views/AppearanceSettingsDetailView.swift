import AppKit
import InlineMacUI
import MacTheme
import SwiftUI
import TextProcessing
import UniformTypeIdentifiers

struct AppearanceSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      AppearanceAndThemeSettingsSection(settings: appSettings)

      Section {
        LabeledContent {
          Picker("Item Size", selection: $appSettings.sidebarItemSize) {
            ForEach(SidebarItemSize.allCases) { size in
              Text(size.title).tag(size)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        } label: {
          SettingsRowLabel("Item Size")
        }
      } header: {
        SettingsSectionHeader("Sidebar")
      }

      Section {
        LabeledContent {
          Picker("Message Style", selection: $appSettings.messageRenderStyle) {
            ForEach(MessageRenderStyle.allCases, id: \.self) { style in
              Text(style.title).tag(style)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 220, alignment: .trailing)
        } label: {
          SettingsRowLabel(
            "Message Style",
            description: "Choose how messages are arranged in newly opened chats."
          )
        }
      } header: {
        SettingsSectionHeader("Messages")
      }

      EmojiSkinToneSettingsSection(selection: $appSettings.preferredEmojiSkinTone)

      Section {
        LabeledContent {
          UnreadBadgeStylePicker(selection: $appSettings.unreadBadgeStyle)
        } label: {
          SettingsRowLabel("Unread Badge Style")
        }
      } header: {
        SettingsSectionHeader("Badges")
      }

      ToolbarSettingsSection(usesCompactToolbar: $appSettings.usesCompactToolbar)
    }
    .settingsFormStyle()
  }
}

private struct AppearanceAndThemeSettingsSection: View {
  @ObservedObject var settings: AppSettings
  @Environment(\.colorScheme) private var colorScheme
  @State private var showsThemePicker = false
  @State private var importsTheme = false
  @State private var exportsTheme = false
  @State private var exportDocument = ThemePaletteFileDocument()
  @State private var transferErrorMessage = ""
  @State private var showsTransferError = false
  @State private var clipboardStatus: LocalizedStringResource?
  @State private var showsThemeCustomization = false

  var body: some View {
    let customizedPresets = currentCustomizedPresets

    Section {
      LabeledContent {
        AppearancePicker(selection: $settings.appearance)
      } label: {
        SettingsRowLabel("Appearance")
      }

      LabeledContent {
        Button {
          clipboardStatus = nil
          showsThemePicker.toggle()
        } label: {
          ThemePickerSummary(
            preset: settings.appTheme,
            variant: previewVariant,
            isCustomized: customizedPresets.contains(settings.appTheme)
          )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsThemePicker, arrowEdge: .trailing) {
          ThemePickerPopover(
            selection: $settings.appTheme,
            systemAccent: $settings.systemThemeAccent,
            variant: previewVariant,
            customizedPresets: customizedPresets,
            clipboardStatus: clipboardStatus,
            importFromClipboardAction: importFromClipboard,
            importFromFileAction: prepareFileImport,
            copyToClipboardAction: copyToClipboard,
            exportToFileAction: prepareFileExport,
            customizeAction: customizeTheme
          )
        }
      } label: {
        SettingsRowLabel(
          "Theme",
          description: "Choose colors for the current light or dark appearance."
        )
      }
    } header: {
      SettingsSectionHeader("Appearance")
    }
    .fileImporter(
      isPresented: $importsTheme,
      allowedContentTypes: [.json]
    ) { result in
      importTheme(result)
    }
    .fileExporter(
      isPresented: $exportsTheme,
      document: exportDocument,
      contentType: .json,
      defaultFilename: "\(settings.appTheme.rawValue)-inline-theme"
    ) { result in
      if case let .failure(error) = result {
        presentTransferError(error)
      }
    }
    .alert("Theme Import or Export Error", isPresented: $showsTransferError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(transferErrorMessage)
    }
    .sheet(isPresented: $showsThemeCustomization) {
      ActiveThemeCustomizationView(
        preset: settings.appTheme,
        initialVariant: previewVariant
      )
    }
  }

  private var previewVariant: ThemeAppearanceVariant {
    switch settings.appearance {
    case .light:
      .light
    case .dark:
      .dark
    case .system:
      colorScheme == .dark ? .dark : .light
    }
  }

  private var currentCustomizedPresets: Set<AppThemePreset> {
    _ = settings.themeRevision
    return ThemePaletteOverrides.customizedPresets()
  }

  private func prepareFileImport() {
    showsThemePicker = false
    DispatchQueue.main.async {
      importsTheme = true
    }
  }

  private func prepareFileExport() {
    do {
      exportDocument = ThemePaletteFileDocument(
        data: try ThemePaletteOverrides.exportData(preset: settings.appTheme)
      )
      showsThemePicker = false
      DispatchQueue.main.async {
        exportsTheme = true
      }
    } catch {
      presentTransferError(error)
    }
  }

  private func importFromClipboard() {
    do {
      guard let value = NSPasteboard.general.string(forType: .string),
            let data = value.data(using: .utf8),
            data.isEmpty == false
      else {
        throw ThemeClipboardError.missingThemeJSON
      }
      try importTheme(data)
      clipboardStatus = "Imported"
    } catch {
      presentTransferError(error)
    }
  }

  private func copyToClipboard() {
    do {
      let data = try ThemePaletteOverrides.exportData(preset: settings.appTheme)
      guard let value = String(data: data, encoding: .utf8) else {
        throw ThemeClipboardError.encodingFailed
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(value, forType: .string) else {
        throw ThemeClipboardError.writeFailed
      }
      clipboardStatus = "Copied"
    } catch {
      presentTransferError(error)
    }
  }

  private func customizeTheme() {
    showsThemePicker = false
    DispatchQueue.main.async {
      showsThemeCustomization = true
    }
  }

  private func importTheme(_ result: Result<URL, any Error>) {
    do {
      let url = try result.get()
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }

      try importTheme(Data(contentsOf: url))
    } catch {
      presentTransferError(error)
    }
  }

  private func importTheme(_ data: Data) throws {
    let preset = try ThemePaletteOverrides.importData(data)
    if settings.appTheme == preset {
      settings.themePaletteDidChange()
    } else {
      settings.appTheme = preset
    }
  }

  private func presentTransferError(_ error: any Error) {
    transferErrorMessage = error.localizedDescription
    showsThemePicker = false
    DispatchQueue.main.async {
      showsTransferError = true
    }
  }
}

private struct ThemePickerSummary: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant
  let isCustomized: Bool

  var body: some View {
    HStack(spacing: 10) {
      ThemePresetPreview(preset: preset, variant: variant)
        .frame(width: 112)

      VStack(alignment: .leading, spacing: 2) {
        Text(preset.title)
          .fontWeight(.medium)

        Text(summarySubtitle)
          .font(isCustomized ? .caption2 : .caption)
          .foregroundStyle(isCustomized ? .tertiary : .secondary)
      }

      Image(systemName: "chevron.up.chevron.down")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(6)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    .contentShape(.rect)
  }

  private var summarySubtitle: LocalizedStringResource {
    isCustomized ? "Custom" : "Pick Theme…"
  }
}

private struct ThemePickerPopover: View {
  @Binding var selection: AppThemePreset
  @Binding var systemAccent: SystemThemeAccent
  let variant: ThemeAppearanceVariant
  let customizedPresets: Set<AppThemePreset>
  let clipboardStatus: LocalizedStringResource?
  let importFromClipboardAction: () -> Void
  let importFromFileAction: () -> Void
  let copyToClipboardAction: () -> Void
  let exportToFileAction: () -> Void
  let customizeAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pick Theme")
        .font(.headline)
        .foregroundStyle(.primary)

      ThemePicker(
        selection: $selection,
        systemAccent: $systemAccent,
        variant: variant,
        customizedPresets: customizedPresets
      )

      Divider()

      HStack(spacing: 8) {
        Menu {
          Button(
            "From Clipboard",
            systemImage: "clipboard",
            action: importFromClipboardAction
          )
          Button("From File…", systemImage: "document", action: importFromFileAction)
        } label: {
          Label("Import", systemImage: "square.and.arrow.down")
        }

        Menu {
          Button(
            "Copy to Clipboard",
            systemImage: "clipboard",
            action: copyToClipboardAction
          )
          Button("Save to File…", systemImage: "document", action: exportToFileAction)
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        }

        if let clipboardStatus {
          Text(clipboardStatus)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        Spacer()
        Button("Customize…", systemImage: "slider.horizontal.3", action: customizeAction)
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: 540)
  }
}

private enum ThemeClipboardError: LocalizedError {
  case missingThemeJSON
  case encodingFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .missingThemeJSON:
      String(localized: "The clipboard does not contain theme JSON.")
    case .encodingFailed:
      String(localized: "The theme JSON could not be encoded as text.")
    case .writeFailed:
      String(localized: "The theme JSON could not be copied to the clipboard.")
    }
  }
}

private struct ThemePaletteFileDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]

  var data: Data

  init(data: Data = Data()) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct ToolbarSettingsSection: View {
  @Binding var usesCompactToolbar: Bool

  var body: some View {
    Section {
      Toggle(isOn: $usesCompactToolbar) {
        SettingsRowLabel(
          "Compact Toolbar",
          description: "Use less vertical space in chat window toolbars."
        )
      }
    } header: {
      SettingsSectionHeader("Toolbar")
    }
  }
}

private struct EmojiSkinToneSettingsSection: View {
  @Binding var selection: EmojiSkinTone

  var body: some View {
    Section {
      LabeledContent {
        Picker("Skin Tone", selection: $selection) {
          ForEach(EmojiSkinTone.allCases) { tone in
            Text(tone.settingsLabel)
              .tag(tone)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
      } label: {
        SettingsRowLabel(
          "Preferred Skin Tone",
          description: "Apply this tone when selecting supported emoji. Explicit variants remain available."
        )
      }
    } header: {
      SettingsSectionHeader("Emoji")
    }
  }
}

private extension EmojiSkinTone {
  var settingsLabel: LocalizedStringResource {
    switch self {
    case .standard:
      "👋 Default"
    case .light:
      "👋🏻 Light"
    case .mediumLight:
      "👋🏼 Medium-Light"
    case .medium:
      "👋🏽 Medium"
    case .mediumDark:
      "👋🏾 Medium-Dark"
    case .dark:
      "👋🏿 Dark"
    }
  }
}

private struct AppearancePicker: View {
  @Binding var selection: AppAppearance

  var body: some View {
    HStack(spacing: 12) {
      ForEach(AppAppearance.pickerOrder) { appearance in
        AppearanceOption(
          appearance: appearance,
          isSelected: selection == appearance
        ) {
          selection = appearance
        }
      }
    }
  }
}

private struct AppearanceOption: View {
  let appearance: AppAppearance
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        AppearanceThumbnail(appearance: appearance)
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(
                isSelected ? Color(nsColor: Theme.accentColor) : Color.clear,
                lineWidth: 3
              )
          }

        Text(appearance.title)
          .font(.caption)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(appearance.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct AppearanceThumbnail: View {
  let appearance: AppAppearance

  var body: some View {
    ZStack {
      AppearanceWindowPreview(palette: .light)

      if appearance == .dark || appearance == .system {
        AppearanceWindowPreview(palette: .dark)
          .mask(alignment: .trailing) {
            Rectangle()
              .frame(width: appearance == .system ? 42 : 84)
          }
      }
    }
    .frame(width: 84, height: 54)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.black.opacity(0.14), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
  }
}

private struct AppearanceWindowPreview: View {
  let palette: AppearancePreviewPalette

  var body: some View {
    ZStack(alignment: .topLeading) {
      palette.contentBackground

      HStack(spacing: 0) {
        palette.sidebarBackground
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 4) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(palette.accent)
            .frame(width: 38, height: 7)

          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(palette.secondaryContent)
            .frame(width: 46, height: 5)
        }
        .padding(.top, 22)
        .padding(.leading, 7)
      }

      Rectangle()
        .fill(palette.titlebarBackground)
        .frame(height: 15)

      HStack(spacing: 3) {
        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
        Circle().fill(Color(red: 1, green: 0.75, blue: 0.10))
        Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.35))
      }
      .frame(width: 18, height: 4)
      .padding(.leading, 5)
      .padding(.top, 5)

      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(palette.accent)
        .frame(width: 20, height: 6)
        .padding(.leading, 4)
        .padding(.top, 23)
    }
    .frame(width: 84, height: 54)
  }
}

private struct AppearancePreviewPalette {
  let titlebarBackground: Color
  let sidebarBackground: Color
  let contentBackground: Color
  let secondaryContent: Color
  let accent: Color

  static let light = Self(
    titlebarBackground: Color(red: 0.86, green: 0.91, blue: 0.97),
    sidebarBackground: Color(red: 0.90, green: 0.92, blue: 0.94),
    contentBackground: .white,
    secondaryContent: Color.black.opacity(0.13),
    accent: Color(red: 0.05, green: 0.45, blue: 0.96)
  )

  static let dark = Self(
    titlebarBackground: Color(red: 0.10, green: 0.17, blue: 0.32),
    sidebarBackground: Color(red: 0.12, green: 0.13, blue: 0.16),
    contentBackground: Color(red: 0.08, green: 0.09, blue: 0.11),
    secondaryContent: Color.white.opacity(0.18),
    accent: Color(red: 0.08, green: 0.42, blue: 0.96)
  )
}

private struct UnreadBadgeStylePicker: View {
  @Binding var selection: UnreadBadgeStyle

  var body: some View {
    HStack(spacing: 8) {
      ForEach(UnreadBadgeStyle.allCases) { style in
        UnreadBadgeStyleOption(
          style: style,
          isSelected: selection == style
        ) {
          selection = style
        }
      }
    }
  }
}

private struct UnreadBadgeStyleOption: View {
  let style: UnreadBadgeStyle
  let isSelected: Bool
  let action: () -> Void

  private var title: LocalizedStringResource {
    switch style {
    case .dot:
      "Dot"
    case .numbered:
      "Numbered"
    }
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        HStack(spacing: 7) {
          if style == .dot {
            badge
          }

          Circle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 22, height: 22)
            .overlay {
              Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

          VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(Color.primary.opacity(0.48))
              .frame(width: 31, height: 5)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(Color.secondary.opacity(0.22))
              .frame(width: 40, height: 4)
          }

          Spacer(minLength: 0)

          if style == .numbered {
            badge
          }
        }
        .padding(.horizontal, 12)
        .frame(width: 122, height: 38)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
              isSelected ? Color(nsColor: Theme.accentColor) : Color.clear,
              lineWidth: 2
            )
        }

        Text(title)
          .font(.caption)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var badge: some View {
    UnreadBadge(
      unreadCount: 3,
      prominent: true,
      style: style,
      dotSize: 7
    )
  }
}

#Preview {
  AppearanceSettingsDetailView()
}
