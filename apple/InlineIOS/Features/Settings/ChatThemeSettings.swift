import InlineTheme
import SwiftUI

struct ThemeSelectionView: View {
  @EnvironmentObject private var themeManager: ThemeManager
  @Environment(\.colorScheme) private var colorScheme

  private let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
  ]

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        ThemePreviewCard(snapshot: selectedSnapshot)

        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(AppThemePreset.allCases) { preset in
            ThemeCard(
              preset: preset,
              snapshot: .resolve(preset: preset, variant: variant),
              isSelected: preset == themeManager.selectedPreset
            ) {
              guard preset != themeManager.selectedPreset else { return }
              themeManager.switchToTheme(withID: preset.rawValue)
              UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
          }
        }
      }
      .padding(16)
    }
    .background(Color(.systemGroupedBackground))
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 6) {
          Image(systemName: "paintpalette.fill")
            .font(.callout)
          Text("Themes")
            .font(.headline)
        }
      }
    }
    .animation(.smooth(duration: 0.22), value: themeManager.selectedPreset)
  }

  private var variant: ThemeAppearanceVariant {
    ThemeAppearanceVariant(colorScheme: colorScheme)
  }

  private var selectedSnapshot: IOSThemeSnapshot {
    themeManager.snapshot(variant: variant)
  }
}

struct ThemeCard: View {
  let preset: AppThemePreset
  let snapshot: IOSThemeSnapshot
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 8) {
        ThemeMiniChat(snapshot: snapshot)
          .frame(height: 72)

        ZStack(alignment: .trailing) {
          Text(preset.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)

          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color(snapshot.primary.uiColor))
            .opacity(isSelected ? 1 : 0)
        }
      }
      .padding(9)
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(
            isSelected ? Color(snapshot.primary.uiColor) : Color(.separator).opacity(0.45),
            lineWidth: isSelected ? 2 : 0.5
          )
      }
    }
    .buttonStyle(.plain)
    .contentShape(.rect)
    .accessibilityLabel(preset.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct ThemeMiniChat: View {
  let snapshot: IOSThemeSnapshot

  var body: some View {
    VStack(spacing: 7) {
      ThemePreviewBubble(
        base: snapshot.incomingBubble,
        lighting: snapshot.incomingLighting,
        side: .leading,
        viewportRange: 0.16 ... 0.34
      )
        .frame(width: 78, height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)

      ThemePreviewBubble(
        base: snapshot.outgoingBubble,
        lighting: snapshot.outgoingLighting,
        side: .trailing,
        viewportRange: 0.64 ... 0.82
      )
        .frame(width: 94, height: 20)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 9)
    .background(Color(snapshot.chatCanvas.uiColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    }
  }
}

private struct ThemePreviewBubble: View {
  let base: ThemeColorValue
  let lighting: ThemeBubbleLightingAlphas
  let side: MessageBubbleTailSide
  let viewportRange: ClosedRange<Double>

  var body: some View {
    MessageBubbleShape(side: side)
      .fill(Color(base.uiColor))
      .overlay {
        MessageBubbleShape(side: side)
          .fill(LinearGradient(
            colors: [
              Color.white.opacity(alpha(at: viewportRange.lowerBound)),
              Color.white.opacity(alpha(at: viewportRange.upperBound)),
            ],
            startPoint: .top,
            endPoint: .bottom
          ))
      }
      .accessibilityHidden(true)
  }

  private func alpha(at viewportFraction: Double) -> Double {
    let fraction = min(max(viewportFraction, 0), 1)
    return lighting.top + (lighting.bottom - lighting.top) * fraction
  }
}

private struct ThemePreviewCard: View {
  let snapshot: IOSThemeSnapshot

  var body: some View {
    VStack(spacing: 10) {
      ThemePreviewMessage(
        text: "The new theme looks great.",
        base: snapshot.incomingBubble,
        textColor: snapshot.incomingText,
        lighting: snapshot.incomingLighting,
        side: .leading,
        viewportRange: 0.18 ... 0.34
      )
      ThemePreviewMessage(
        text: "And the bubbles share one light.",
        base: snapshot.outgoingBubble,
        textColor: .init(rgb: 0xFFFFFF),
        lighting: snapshot.outgoingLighting,
        side: .trailing,
        viewportRange: 0.62 ... 0.8
      )
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 16)
    .background(Color(snapshot.chatCanvas.uiColor), in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ThemePreviewMessage: View {
  let text: LocalizedStringKey
  let base: ThemeColorValue
  let textColor: ThemeColorValue
  let lighting: ThemeBubbleLightingAlphas
  let side: MessageBubbleTailSide
  let viewportRange: ClosedRange<Double>

  var body: some View {
    Text(text)
      .font(.subheadline)
      .padding(.leading, side == .leading ? 17 : 11)
      .padding(.trailing, side == .trailing ? 17 : 11)
      .padding(.vertical, 7)
      .foregroundStyle(Color(textColor.uiColor))
      .background {
        ThemePreviewBubble(
          base: base,
          lighting: lighting,
          side: side,
          viewportRange: viewportRange
        )
      }
      .frame(
        maxWidth: .infinity,
        alignment: side == .trailing ? .trailing : .leading
      )
  }
}

#Preview("Theme Selection") {
  NavigationStack {
    ThemeSelectionView()
  }
  .environmentObject(ThemeManager.shared)
}
