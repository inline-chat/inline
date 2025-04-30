// ThemeSelectionView.swift
import SwiftUI

struct ThemeSelectionView: View {
  @StateObject private var themeManager = ThemeManager.shared
  @State private var selectedThemeId: String
    
  init() {
    _selectedThemeId = State(initialValue: ThemeManager.shared.selected.id)
  }
    
  var body: some View {
    List {
      ThemePreviewCard(theme: themeManager.selected)
        .listRowInsets(EdgeInsets())
        
      themeGrid
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack {
          Image(systemName: "paintpalette.fill")
            .foregroundColor(.secondary)
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
        ForEach(ThemeManager.themes, id: \.id) { theme in
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
    }
  }
    
  private func selectTheme(_ theme: ThemeConfig) {
    selectedThemeId = theme.id
    themeManager.switchToTheme(theme)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}

struct ThemeCard: View {
  let theme: ThemeConfig
  let isSelected: Bool
    
  var body: some View {
    VStack(alignment: .center) {
      Circle()
        .fill(Color(theme.bubbleBackground))
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
    
  private func messageBubble(outgoing: Bool, text: String) -> some View {
    HStack {
      if outgoing { Spacer() }
            
      Text(text)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          outgoing ? Color(theme.bubbleBackground) : Color(theme.incomingBubbleBackground)
        )
        .foregroundColor(outgoing ? .white : .primary)
        .cornerRadius(10)
            
      if !outgoing { Spacer() }
    }
  }
}

struct ThemePreviewCard: View {
  let theme: ThemeConfig
    
  var body: some View {
    VStack(spacing: 12) {
      messageBubble(outgoing: false, text: "Hey! Just pushed an update for users! Have you checked it out yet?")
      messageBubble(outgoing: true, text: "Nice. Cheking it out now.")
    }
    .padding()
    .background(Color(theme.backgroundColor).ignoresSafeArea())
  }
    
  private func messageBubble(outgoing: Bool, text: String) -> some View {
    HStack {
      if outgoing { Spacer() }
            
      Text(text)
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          outgoing ? Color(theme.bubbleBackground) : Color(theme.incomingBubbleBackground)
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
