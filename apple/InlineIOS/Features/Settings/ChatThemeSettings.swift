import SwiftUI

struct ThemeSelectionView: View {
  @Bindable private var store = ThemeStore.shared
  @State private var selectedThemeId: String

  init() {
    _selectedThemeId = State(initialValue: ThemeStore.shared.current.id)
  }

  var body: some View {
    List {
      ThemePreviewCard(theme: store.current)
        .listRowInsets(EdgeInsets())

      themeGrid
        .listRowInsets(EdgeInsets())
    }
    .listStyle(.insetGrouped)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack {
          Image(systemName: "paintpalette.fill")
            .font(.callout)
          Text("Themes")
            .font(.headline)
        }
      }
    }
    .animation(.spring(response: 0.3), value: selectedThemeId)
  }

  private var themeGrid: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 12) {
        ForEach(AppTheme.allThemes) { theme in
          ThemeCard(
            theme: theme,
            isSelected: theme.id == selectedThemeId
          )
          .onTapGesture {
            selectTheme(theme)
          }
        }
      }
      .padding(.vertical)
      .padding(.horizontal, 12)
    }
  }

  private func selectTheme(_ theme: AppTheme) {
    selectedThemeId = theme.id
    store.select(theme)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}

struct ThemeCard: View {
  let theme: AppTheme
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .center) {
      Circle()
        .fill(theme.colors.bubbleOutgoingColor)
        .frame(width: 50)
        .padding(2)
        .background(
          Circle()
            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )

      Text(theme.name)
        .font(.footnote)
        .foregroundColor(isSelected ? .primary : .secondary)
        .lineLimit(1)
    }
    .frame(minWidth: 80)
  }
}

struct ThemePreviewCard: View {
  let theme: AppTheme

  var body: some View {
    VStack(spacing: 12) {
      messageBubble(
        outgoing: false,
        text: "Hey! Just pushed an update for users! Have you checked it out yet?"
      )
      messageBubble(
        outgoing: true,
        text: "Nice. Checking it out now."
      )
    }
    .padding()
    .background(theme.colors.backgroundColor.ignoresSafeArea())
  }

  private func messageBubble(outgoing: Bool, text: String) -> some View {
    HStack {
      if outgoing { Spacer() }

      Text(text)
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          outgoing
            ? theme.colors.bubbleOutgoingColor
            : theme.colors.bubbleIncomingColor
        )
        .foregroundColor(outgoing ? .white : .primary)
        .cornerRadius(18)
        .frame(maxWidth: 260, alignment: outgoing ? .trailing : .leading)

      if !outgoing { Spacer() }
    }
  }
}

#Preview("Theme Selection") {
  NavigationView {
    ThemeSelectionView()
  }
}
