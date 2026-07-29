import MacTheme
import SwiftUI

struct ThemePicker: View {
  @Binding var selection: AppThemePreset
  @Binding var systemAccent: SystemThemeAccent
  let variant: ThemeAppearanceVariant
  let customizedPresets: Set<AppThemePreset>

  private static let columns = Array(
    repeating: GridItem(.flexible(minimum: 104, maximum: 128), spacing: 12),
    count: 4
  )

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: Self.columns, spacing: 13) {
        ForEach(AppThemePreset.allCases) { preset in
          ThemePresetOption(
            preset: preset,
            variant: variant,
            isSelected: selection == preset,
            isCustomized: customizedPresets.contains(preset),
            action: { selection = preset }
          )
        }
      }

      if selection == .system {
        SystemAccentPicker(selection: $systemAccent, variant: variant)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SystemAccentPicker: View {
  @Binding var selection: SystemThemeAccent
  let variant: ThemeAppearanceVariant

  var body: some View {
    HStack(spacing: 10) {
      Text("Accent")
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(SystemThemeAccent.allCases) { accent in
        Button {
          selection = accent
        } label: {
          ZStack {
            swatch(accent)

            if selection == accent {
              Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
            }
          }
          .frame(width: 20, height: 20)
          .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .help(accent.title)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(selection == accent ? .isSelected : [])
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func swatch(_ accent: SystemThemeAccent) -> some View {
    if accent == .native {
      Circle()
        .fill(
          AngularGradient(
            colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
            center: .center
          )
        )
    } else {
      Circle()
        .fill(Color(nsColor: accent.colorValue(appearance: variant.nsAppearance).nsColor))
    }
  }
}

private struct ThemePresetOption: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant
  let isSelected: Bool
  let isCustomized: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        ThemePresetPreview(preset: preset, variant: variant)
          .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(
                isSelected ? Color(nsColor: Theme.accentColor) : Color.clear,
                lineWidth: 2
              )
          }

        VStack(spacing: 1) {
          Text(preset.title)
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)

          Text("Custom")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .opacity(isCustomized ? 1 : 0)
            .accessibilityHidden(!isCustomized)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .focusEffectDisabled(true)
    .accessibilityLabel(isCustomized ? "\(preset.title), Custom" : preset.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct ThemePresetPreview: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    ThemeVariantPreview(preset: preset, variant: variant)
      .frame(height: 62)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.13), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
  }
}

private struct ThemeVariantPreview: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    let palette = Theme.resolvedPalette(preset: preset, variant: variant)
    let accent = Color(nsColor: palette.accent.nsColor)
    let prominent = Color(nsColor: palette.prominent.nsColor)
    let bubble = Color(nsColor: palette.bubble.nsColor)
    let background = Color(nsColor: palette.background.nsColor)

    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        background

        Rectangle()
          .fill(prominent.opacity(variant == .dark ? 0.12 : 0.08))
          .frame(width: geometry.size.width * 0.34)

        VStack(alignment: .leading, spacing: 4) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(prominent.opacity(0.28))
            .frame(width: geometry.size.width * 0.23, height: 5)

          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(bubble)
            .frame(width: geometry.size.width * 0.54, height: 8)
            .frame(maxWidth: .infinity, alignment: .trailing)

          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(bubble.opacity(0.86))
            .frame(width: geometry.size.width * 0.39, height: 7)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.top, 18)

        Circle()
          .fill(prominent)
          .frame(width: 7, height: 7)
          .padding(.leading, 5)
          .padding(.top, 7)

        Circle()
          .fill(accent)
          .frame(width: 10, height: 10)
          .padding(.trailing, 5)
          .padding(.bottom, 5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
    }
    .frame(minWidth: 54)
  }
}

#Preview {
  @Previewable @State var selection = AppThemePreset.system
  @Previewable @State var systemAccent = SystemThemeAccent.native
  ThemePicker(
    selection: $selection,
    systemAccent: $systemAccent,
    variant: .light,
    customizedPresets: []
  )
    .frame(width: 540)
    .padding()
}
