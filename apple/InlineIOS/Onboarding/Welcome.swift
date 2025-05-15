import CoreHaptics
import SwiftUI

struct Welcome: View {
  let fullText = NSLocalizedString("Welcome to Inline", comment: "Welcome to Inline")
  let typingSpeed: TimeInterval = 0.08

  @State private var engine: CHHapticEngine?
  @State private var displayedText = ""
  @State private var showCaret = false
  @State private var animationCompleted = false
  @State private var viewIsVisible = false
  @State private var hasRunAnimation = false

  @EnvironmentObject var nav: OnboardingNavigation

  var body: some View {
    VStack(alignment: .leading) {
      heading
      subheading
    }
    .onAppear {
      viewIsVisible = true

      if !hasRunAnimation {
        prepareHaptics()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          if viewIsVisible {
            animateText()
          }
        }
      }
    }
    .onDisappear {
      viewIsVisible = false
      stopHapticEngine()
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .safeAreaInset(edge: .bottom) {
      bottomArea
    }
    .safeAreaInset(edge: .top) {
      topArea
    }
    .navigationBarBackButtonHidden()
  }
}

// MARK: - Views

extension Welcome {
  @ViewBuilder
  var heading: some View {
    ZStack(alignment: .leading) {
      // Placeholder to maintain layout
      Text(fullText)
        .font(.largeTitle)
        .fontWeight(.bold)
        .opacity(0)

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
  }

  @ViewBuilder
  var subheading: some View {
    Text("It's an all new way to chat with your team.")
      .foregroundColor(.secondary)
      .font(.title3)
      .multilineTextAlignment(.leading)
  }

  @ViewBuilder
  var bottomArea: some View {
    VStack {
      Button("Continue with Email") {
        submitToEmailRoute()
      }
      .buttonStyle(SimpleButtonStyle())
      
      .frame(maxWidth: .infinity)

      Button("Continue with Phone Number") {
        submitToPhoneNumberRoute()
      }
      .buttonStyle(SimpleWhiteButtonStyle())
      
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
  }

  @ViewBuilder
  var topArea: some View {
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

// MARK: - Helper Methods

extension Welcome {
  private func submitToEmailRoute() {
    hasRunAnimation = true

    stopHapticEngine()

    displayedText = ""
    nav.push(.email())
  }

  private func submitToPhoneNumberRoute() {
    hasRunAnimation = true

    stopHapticEngine()

    displayedText = ""
    nav.push(.phoneNumber())
  }

  private func animateText() {
    guard !animationCompleted, viewIsVisible else { return }

    withAnimation(.bouncy) {
      showCaret = true
    }

    hasRunAnimation = true

    for (index, character) in fullText.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + typingSpeed * Double(index)) {
        guard viewIsVisible else { return }

        displayedText += String(character)

        if !animationCompleted, viewIsVisible {
          playHapticFeedback()
        }

        if index == fullText.count - 1 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard viewIsVisible else { return }

            withAnimation(.bouncy) {
              showCaret = false
              animationCompleted = true
            }
          }
        }
      }
    }
  }
}

// MARK: - Haptic setup

extension Welcome {
  private func prepareHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

    do {
      engine = try CHHapticEngine()

      // Add engine reset handler
      engine?.resetHandler = { [self] in
        do {
          try engine?.start()
        } catch {
          print("Failed to restart the engine: \(error.localizedDescription)")
        }
      }

      // Add engine stopped handler
      engine?.stoppedHandler = { reason in
        print("The engine stopped: \(reason)")
      }

      try engine?.start()
    } catch {
      print("There was an error creating the engine: \(error.localizedDescription)")
    }
  }

  private func stopHapticEngine() {
    engine?.stop(completionHandler: { error in
      if let error {
        print("Error stopping haptic engine: \(error.localizedDescription)")
      }
    })
  }

  private func playHapticFeedback() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
          !animationCompleted,
          viewIsVisible
    else {
      return
    }

    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5)
    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
    let event = CHHapticEvent(
      eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0
    )

    do {
      let pattern = try CHHapticPattern(events: [event], parameters: [])
      let player = try engine?.makePlayer(with: pattern)
      try player?.start(atTime: 0)
    } catch {
      print("Failed to play pattern: \(error.localizedDescription).")
    }
  }
}
