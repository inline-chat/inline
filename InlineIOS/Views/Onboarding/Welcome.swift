//
//  Welcome.swift
//  Inline
//
//  Created by Dena Sohrabi on 9/27/24.
//

import CoreHaptics
import SwiftUI

struct Welcome: View {
  @EnvironmentObject var nav: OnboardingNavigation
  @State private var engine: CHHapticEngine?
  @State private var displayedText = ""
  @State private var showCaret = false
  @State private var animationCompleted = false

  let fullText = "Hey There."
  let typingSpeed: TimeInterval = 0.08

  var body: some View {
    VStack(alignment: .leading) {
      ZStack(alignment: .leading) {
        // Placeholder to maintain layout
        Text(fullText)
          .font(.largeTitle)
          .fontWeight(.bold)
          .opacity(0)

        // Animated text with caret
        HStack(alignment: .center, spacing: 2) {
          Text(animationCompleted ? fullText : displayedText)
            .font(.largeTitle)
            .fontWeight(.bold)

          Rectangle()
            .frame(width: 4, height: 28)
            .background(.secondary)
            .opacity(showCaret ? 1 : 0)
        }
      }

      Text("Ready for a new way to chat at work?")
        .foregroundColor(.secondary)
        .font(.title3)
        .multilineTextAlignment(.leading)
    }
    .onAppear {
      prepareHaptics()

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        animateText()
      }
    }

    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .safeAreaInset(edge: .bottom) {
      Button("Continue") {
        displayedText = ""
        nav.push(.email())
      }
      .buttonStyle(SimpleButtonStyle())
      .frame(maxWidth: .infinity)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
    }
    .safeAreaInset(edge: .top) {
      HStack {
        Image("OnboardingLogoType")
          .renderingMode(.template)
          .foregroundColor(.primary)
          .padding(.horizontal, OnboardingUtils.shared.hPadding)
          .padding(.top, 28)
        Spacer()
      }
    }
  }

  private func animateText() {
    guard !animationCompleted else { return }

    withAnimation(.bouncy) {
      showCaret = true
    }

    for (index, character) in fullText.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + typingSpeed * Double(index)) {
        displayedText += String(character)

        if !animationCompleted {
          playHapticFeedback()
        }

        if index == fullText.count - 1 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.bouncy) {
              showCaret = false
              animationCompleted = true
            }
          }
        }
      }
    }
  }

  private func prepareHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    do {
      engine = try CHHapticEngine()
      try engine?.start()
    } catch {
      print("There was an error creating the engine: \(error.localizedDescription)")
    }
  }

  private func playHapticFeedback() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics && !animationCompleted else {
      return
    }

    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5)
    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
    let event = CHHapticEvent(
      eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)

    do {
      let pattern = try CHHapticPattern(events: [event], parameters: [])
      let player = try engine?.makePlayer(with: pattern)
      try player?.start(atTime: 0)
    } catch {
      print("Failed to play pattern: \(error.localizedDescription).")
    }
  }
}

#Preview {
  Welcome()
    .environmentObject(Navigation())
}

struct TypingText: View {
  let fullText: String
  @State private var displayedText = ""
  let typingInterval: TimeInterval

  init(_ text: String, typingInterval: TimeInterval = 0.2) {
    fullText = text
    self.typingInterval = typingInterval
  }

  var body: some View {
    Text(displayedText)
      .onAppear { animateText() }
  }

  private func animateText() {
    for (index, character) in fullText.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + typingInterval * Double(index)) {
        displayedText += String(character)
      }
    }
  }
}
