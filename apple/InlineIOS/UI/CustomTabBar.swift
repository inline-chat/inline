import CoreHaptics
import SwiftUI

struct CustomTabBar: View {
  @Binding var selectedTab: TabItem
  @Namespace private var animation
  @State private var engine: CHHapticEngine?

  var body: some View {
    HStack(spacing: 0) {
      ForEach([TabItem.contacts, .home, .settings], id: \.self) { tab in
        VStack(spacing: 4) {
          ZStack {
            if selectedTab == tab {
              Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 8, height: 8)
                .matchedGeometryEffect(id: "TAB", in: animation)
                .offset(y: -4)
            }
          }
          .frame(height: 8)

          Image(systemName: tab.icon)
            .font(.system(size: 22))
            .foregroundColor(selectedTab == tab ? .blue : .gray)
            .scaleEffect(selectedTab == tab ? 1.1 : 1.0)
            .frame(height: 24)

          Text(tab.title)
            .font(.caption)
            .fontWeight(selectedTab == tab ? .semibold : .medium)
            .foregroundColor(selectedTab == tab ? .blue : .gray)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
          if selectedTab != tab {
            playHapticFeedback()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
              selectedTab = tab
            }
          }
        }
      }
    }
    .padding(.vertical, 12)
    .background(.ultraThinMaterial)
    .cornerRadius(24)
    .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: -2)
    .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 2)
    .padding(.horizontal, 24)
    .padding(.bottom, 8)
    .onAppear(perform: prepareHaptics)
  }

  private func prepareHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    do {
      engine = try CHHapticEngine()
      try engine?.start()
    } catch {
      print("Haptics not available: \(error.localizedDescription)")
    }
  }

  private func playHapticFeedback() {
    // Simple light haptic feedback that works on all devices
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
  }
}
