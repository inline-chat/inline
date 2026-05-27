import InlineKit
import SwiftUI

struct InviteCode: View {
  enum Destination: Hashable {
    case email(email: String, challengeToken: String?)
    case phone(phoneNumber: String)
  }

  let destination: Destination

  @State private var code = ""
  @State private var errorMsg = ""
  @State private var isChecking = false
  @FocusState private var isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject var api: ApiClient

  private var normalizedCode: String {
    code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private var isInputValid: Bool {
    normalizedCode.count == 8
  }

  private var focusColor: Color {
    if colorScheme == .dark {
      Color(hex: "#8b77dc")
    } else {
      Color(hex: "#a28cf2")
    }
  }

  var body: some View {
    VStack(spacing: 20) {
      Spacer()

      VStack(spacing: 12) {
        Image(systemName: "ticket.fill")
          .resizable()
          .scaledToFit()
          .frame(width: 34, height: 34)
          .foregroundColor(.primary)

        Text(NSLocalizedString("Enter invite code", comment: "Invite code input title"))
          .font(.system(size: 21.0, weight: .semibold))
          .foregroundStyle(.primary)
      }

      VStack(spacing: 8) {
        codeInput

        if !errorMsg.isEmpty {
          Text(errorMsg)
            .font(.callout)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, OnboardingUtils.shared.hPadding)

      Spacer()
    }
    .safeAreaInset(edge: .bottom) {
      Button(isChecking ? NSLocalizedString("Checking...", comment: "Checking invite code button loading state") : NSLocalizedString("Continue", comment: "Continue button")) {
        submit()
      }
      .buttonStyle(SimpleButtonStyle())
      .frame(maxWidth: .infinity)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
      .disabled(!isInputValid || isChecking)
      .opacity((isInputValid && !isChecking) ? 1 : 0.5)
    }
    .onAppear {
      isFocused = true
    }
  }

  @ViewBuilder
  var codeInput: some View {
    TextField(NSLocalizedString("Invite Code", comment: "Invite code input placeholder"), text: $code)
      .focused($isFocused)
      .textInputAutocapitalization(.characters)
      .autocorrectionDisabled(true)
      .monospaced()
      .font(.title2)
      .fontWeight(.semibold)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                isFocused ? focusColor : Color(.systemGray4),
                lineWidth: isFocused ? 2 : 0.5
              )
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .animation(.easeInOut(duration: 0.2), value: isFocused)
      .onSubmit {
        submit()
      }
      .onChange(of: code) { _, newValue in
        code = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        errorMsg = ""
      }
  }

  func submit() {
    guard isInputValid, !isChecking else {
      errorMsg = NSLocalizedString("Enter the 8-character invite code.", comment: "Invite code validation error")
      return
    }

    isChecking = true
    errorMsg = ""

    Task {
      do {
        _ = try await api.checkInviteCode(normalizedCode)
        isChecking = false
        switch destination {
          case let .email(email, challengeToken):
            nav.push(.code(email: email, challengeToken: challengeToken, inviteCode: normalizedCode))
          case let .phone(phoneNumber):
            nav.push(.phoneNumberCode(phoneNumber: phoneNumber, inviteCode: normalizedCode))
        }
      } catch let error as APIError {
        isChecking = false
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
      } catch {
        isChecking = false
        errorMsg = error.localizedDescription
      }
    }
  }
}

#Preview("Invite Code") {
  InviteCode(destination: .email(email: "user@example.com", challengeToken: nil))
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}
