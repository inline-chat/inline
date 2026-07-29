import AppKit
import MacTheme
import SwiftUI

struct ActiveThemeCustomizationView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var settings = AppSettings.shared
  let preset: AppThemePreset
  @State private var variant: ThemeAppearanceVariant

  init(preset: AppThemePreset, initialVariant: ThemeAppearanceVariant) {
    self.preset = preset
    _variant = State(initialValue: initialVariant)
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Appearance") {
          Picker("Appearance", selection: $variant) {
            ForEach(ThemeAppearanceVariant.allCases) { variant in
              Text(variant.title).tag(variant)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 180)
        }

        ThemePresetPreview(preset: preset, variant: variant)
          .frame(width: 280)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      } header: {
        VStack(alignment: .leading, spacing: 3) {
          Text("Customize \(preset.title)")
            .font(.headline)

          Text("Changes are stored on this Mac and update open windows live.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      ThemeColorEditorSection(preset: preset, variant: variant)

      Section {
        HStack(spacing: 10) {
          Button("Reset \(variant.title)") {
            ThemePaletteOverrides.reset(preset: preset, variant: variant)
            settings.themePaletteDidChange()
          }

          Spacer()

          Button("Done") {
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .settingsFormStyle()
    .frame(minWidth: 480, minHeight: preset == .system ? 380 : 470)
  }
}

private struct ThemeColorEditorSection: View {
  @ObservedObject private var settings = AppSettings.shared
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    Section {
      ForEach(editableRoles) { role in
        LabeledContent {
          HStack(spacing: 10) {
            Text(resolvedColor(role).hexRGB)
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(.secondary)

            ColorPicker(
              role.title,
              selection: binding(for: role),
              supportsOpacity: false
            )
            .labelsHidden()
          }
        } label: {
          Text(role.title)
        }
      }
    } header: {
      SettingsSectionHeader("Colors", subtitle: subtitle)
    }
  }

  private var editableRoles: [ThemeColorRole] {
    preset == .system ? [.bubble] : ThemeColorRole.allCases
  }

  private var subtitle: LocalizedStringResource {
    if preset == .system {
      "Choose the accent in the theme picker. Native surfaces remain unchanged."
    } else {
      "Foreground content remains white."
    }
  }

  private func resolvedColor(_ role: ThemeColorRole) -> ThemeColorValue {
    _ = settings.themeRevision
    return Theme.resolvedColor(role: role, preset: preset, variant: variant)
  }

  private func binding(for role: ThemeColorRole) -> Binding<Color> {
    Binding {
      Color(nsColor: resolvedColor(role).nsColor)
    } set: { color in
      ThemePaletteOverrides.setColor(
        ThemeColorValue(nsColor: NSColor(color), appearance: variant.nsAppearance),
        preset: preset,
        variant: variant,
        role: role
      )
      settings.themePaletteDidChange()
    }
  }
}

#if DEBUG || DEBUG_BUILD
struct ThemeWorkshopView: View {
  @ObservedObject private var settings = AppSettings.shared
  @State private var preset = AppSettings.shared.appTheme
  @State private var variant = ThemeAppearanceVariant.light

  var body: some View {
    Form {
      ThemeWorkshopSelectionSection(preset: $preset, variant: $variant)
      ThemeWorkshopPreviewSection(preset: preset, variant: variant)
      ThemeColorEditorSection(preset: preset, variant: variant)
      ThemeWorkshopActionsSection(preset: preset, variant: variant)
    }
    .settingsFormStyle()
    .frame(minWidth: 620, minHeight: 560)
    .navigationTitle("Theme Workshop")
    .onAppear {
      variant = ThemeAppearanceVariant(appearance: NSApp.effectiveAppearance)
    }
    .onChange(of: preset, initial: true) { _, preset in
      settings.appTheme = preset
    }
  }
}

private struct ThemeWorkshopSelectionSection: View {
  @Binding var preset: AppThemePreset
  @Binding var variant: ThemeAppearanceVariant

  var body: some View {
    Section {
      LabeledContent("Preset") {
        Picker("Preset", selection: $preset) {
          ForEach(AppThemePreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .labelsHidden()
        .frame(width: 180)
      }

      LabeledContent("Variant") {
        Picker("Variant", selection: $variant) {
          ForEach(ThemeAppearanceVariant.allCases) { variant in
            Text(variant.title).tag(variant)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 180)
      }
    } header: {
      SettingsSectionHeader(
        "Editing",
        subtitle: "Changes are local to this debug build and update open Inline windows live."
      )
    }
  }
}

private struct ThemeWorkshopPreviewSection: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    Section {
      ThemePresetPreview(preset: preset, variant: variant)
        .frame(width: 300)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    } header: {
      SettingsSectionHeader("Preview")
    }
  }
}

private struct ThemeWorkshopActionsSection: View {
  @ObservedObject private var settings = AppSettings.shared
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant
  @State private var copyConfirmation: String?

  var body: some View {
    Section {
      HStack(spacing: 10) {
        Button("Reset \(variant.title)") {
          ThemePaletteOverrides.reset(preset: preset, variant: variant)
          settings.themePaletteDidChange()
        }

        Button("Reset Theme") {
          ThemePaletteOverrides.reset(preset: preset)
          settings.themePaletteDidChange()
        }

        Spacer()

        if let copyConfirmation {
          Text(copyConfirmation)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button("Copy Palette JSON") {
          copyPalette()
        }
        .buttonStyle(.borderedProminent)
      }
    } footer: {
      Text("Paste the copied JSON back into the theming task for production palette updates.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func copyPalette() {
    let export = ThemePaletteOverrides.export(preset: preset)
    guard export.isEmpty == false else {
      copyConfirmation = "Export failed"
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(export, forType: .string) else {
      copyConfirmation = "Copy failed"
      return
    }
    copyConfirmation = "Copied"
  }
}

#Preview {
  ThemeWorkshopView()
}
#endif
