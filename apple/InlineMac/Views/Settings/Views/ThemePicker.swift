import MacTheme
import SwiftUI

struct ThemePicker: View {
  @Binding var selection: AppThemePreset
  let variant: ThemeAppearanceVariant
  let customizedPresets: Set<AppThemePreset>

  private static let columns = Array(
    repeating: GridItem(.flexible(minimum: 104, maximum: 128), spacing: 12),
    count: 4
  )

  var body: some View {
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
    .frame(maxWidth: .infinity, alignment: .leading)
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
      VStack(spacing: 6) {
        ThemePresetSwatch(preset: preset, variant: variant)
          .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(isSelected ? selectionColor : .clear, lineWidth: 2)
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

  private var selectionColor: Color {
    Color(nsColor: Theme.resolvedPalette(preset: preset, variant: variant).primary.nsColor)
  }
}

struct ThemePresetSwatch: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    CompactThemeVariantPreview(preset: preset, variant: variant)
      .frame(height: 62)
      .compositingGroup()
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.13), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
  }
}

private struct CompactThemeVariantPreview: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    let palette = Theme.resolvedPalette(preset: preset, variant: variant)
    let primary = Color(nsColor: palette.primary.nsColor)
    let canvas = Color(nsColor: Theme.resolvedWindowSurfaceColor(
      preset: preset,
      variant: variant
    ).nsColor)

    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        canvas

        Rectangle()
          .fill(primary.opacity(variant == .dark ? 0.06 : 0.035))
          .frame(width: geometry.size.width * 0.34)

        VStack(alignment: .leading, spacing: 4) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(primary.opacity(0.28))
            .frame(width: geometry.size.width * 0.23, height: 5)

          compactBubble(primary, width: geometry.size.width * 0.54, height: 8)
            .frame(maxWidth: .infinity, alignment: .trailing)

          compactBubble(primary, width: geometry.size.width * 0.39, height: 7)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 5)
        .padding(.top, 18)

        Circle()
          .fill(primary)
          .frame(width: 7, height: 7)
          .padding(.leading, 5)
          .padding(.top, 7)

        Circle()
          .fill(primary)
          .frame(width: 10, height: 10)
          .padding(.trailing, 5)
          .padding(.bottom, 5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
    }
    .frame(minWidth: 54)
  }

  private func compactBubble(_ primary: Color, width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(primary)
      .overlay {
        LinearGradient(
          colors: [.white.opacity(0.2), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      }
      .frame(width: width, height: height)
  }
}

struct ThemeCustomizationPreview: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    ThemeCustomizationVariantPreview(preset: preset, variant: variant)
      .aspectRatio(1.55, contentMode: .fit)
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.13), lineWidth: 1)
      }
      .compositingGroup()
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .shadow(color: .black.opacity(0.11), radius: 3, y: 1)
  }
}

private struct ThemeCustomizationVariantPreview: View {
  let preset: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    let palette = Theme.resolvedPalette(preset: preset, variant: variant)
    let primary = Color(nsColor: palette.primary.nsColor)
    let canvas = Color(nsColor: Theme.resolvedWindowSurfaceColor(
      preset: preset,
      variant: variant
    ).nsColor)
    let ink = variant == .dark ? Color.white : Color.black
    let incoming = Color(nsColor: Theme.resolvedSecondaryBubbleColor(
      preset: preset,
      variant: variant
    ).nsColor)

    GeometryReader { geometry in
      HStack(spacing: 0) {
        sidebar(
          width: geometry.size.width * 0.34,
          primary: primary,
          canvas: canvas,
          ink: ink
        )
        chat(primary: primary, canvas: canvas, incoming: incoming, ink: ink)
      }
    }
  }

  private func sidebar(
    width: CGFloat,
    primary: Color,
    canvas: Color,
    ink: Color
  ) -> some View {
    ZStack(alignment: .topLeading) {
      canvas
      primary.opacity(variant == .dark ? 0.04 : 0.025)

      VStack(spacing: 5) {
        HStack(spacing: 4) {
          Circle()
            .fill(primary)
            .frame(width: 8, height: 8)
          previewLine(width: width * 0.4, opacity: 0.42, ink: ink)
        }
        .padding(.bottom, 3)

        sidebarRow(width: width, primary: primary, ink: ink, selected: true, unread: true)
        sidebarRow(width: width, primary: primary, ink: ink, selected: false, unread: false)
        sidebarRow(width: width, primary: primary, ink: ink, selected: false, unread: true)
      }
      .padding(.horizontal, 7)
      .padding(.top, 10)
    }
    .frame(width: width)
    .overlay(alignment: .trailing) {
      Rectangle().fill(ink.opacity(0.09)).frame(width: 1)
    }
  }

  private func sidebarRow(
    width: CGFloat,
    primary: Color,
    ink: Color,
    selected: Bool,
    unread: Bool
  ) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(ink.opacity(0.18))
        .frame(width: 11, height: 11)
      previewLine(width: width * 0.42, opacity: selected ? 0.52 : 0.28, ink: ink)
      Spacer(minLength: 0)
      Circle()
        .fill(primary)
        .frame(width: 4, height: 4)
        .opacity(unread ? 1 : 0)
    }
    .padding(.horizontal, 4)
    .frame(height: 18)
    .background(primary.opacity(selected ? 0.16 : 0), in: .rect(cornerRadius: 5))
  }

  private func chat(primary: Color, canvas: Color, incoming: Color, ink: Color) -> some View {
    VStack(spacing: 0) {
      HStack {
        previewLine(width: 34, opacity: 0.5, ink: ink)
        Spacer(minLength: 0)
        Circle().fill(primary).frame(width: 8, height: 8)
      }
      .padding(.horizontal, 8)
      .frame(height: 24)
      .overlay(alignment: .bottom) {
        Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
      }

      VStack(spacing: 5) {
        previewBubble(color: incoming, width: 0.54, alignment: .leading)
        previewBubble(color: primary, width: 0.66, alignment: .trailing)
        previewBubble(color: primary, width: 0.43, alignment: .trailing)
      }
      .padding(.horizontal, 8)
      .padding(.top, 9)

      Spacer(minLength: 4)

      HStack(spacing: 5) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(ink.opacity(0.075))
          .frame(height: 14)
        Circle().fill(primary).frame(width: 14, height: 14)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 7)
    }
    .background(canvas)
  }

  private func previewBubble(
    color: Color,
    width: CGFloat,
    alignment: Alignment
  ) -> some View {
    GeometryReader { geometry in
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(color)
        .overlay {
          LinearGradient(
            colors: [.white.opacity(0.2), .clear],
            startPoint: .top,
            endPoint: .bottom
          )
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(width: geometry.size.width * width, height: 15)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
    .frame(height: 15)
  }

  private func previewLine(width: CGFloat, opacity: Double, ink: Color) -> some View {
    RoundedRectangle(cornerRadius: 2, style: .continuous)
      .fill(ink.opacity(opacity))
      .frame(width: width, height: 4)
  }
}

#Preview {
  @Previewable @State var selection = AppThemePreset.system
  ThemePicker(
    selection: $selection,
    variant: .light,
    customizedPresets: []
  )
  .frame(width: 540)
  .padding()
}
