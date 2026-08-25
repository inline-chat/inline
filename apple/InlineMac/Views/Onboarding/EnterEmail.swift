import InlineKit
import Logger
import SwiftUI

struct OnboardingEnterEmail: View {
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel
  @FormState var formState

  enum Field {
    case codeField
  }

  @FocusState private var focusedField: Field?

  var body: some View {
    VStack {
      Image(systemName: "at.circle.fill")
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
        .foregroundColor(.primary)
        .padding(.bottom, 4)

      Text("Sign in with email")
        .font(.system(size: 21.0, weight: .semibold))
        .foregroundStyle(.primary)

      emailField
        .focused($focusedField, equals: .codeField)
        .disabled(formState.isLoading)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onSubmit {
          sendCode()
        }
        .onChange(of: onboardingViewModel.email) { _, _ in
          if formState.error != nil {
            formState.reset()
          }
        }
        .onAppear {
          focusedField = .codeField
        }

      if let error = formState.error, !error.isEmpty {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(width: 260)
          .padding(.bottom, 8)
      }

      InlineButton {
        sendCode()
      } label: {
        if !formState.isLoading {
          Text("Continue").padding(.horizontal)
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(0.5)
        }
      }
      .disabled(formState.isLoading)
    }
    .padding()
  }

  @ViewBuilder var emailField: some View {
    let view = GrayTextField("Your Email", text: $onboardingViewModel.email)
      .frame(width: 260)

    if #available(macOS 14.0, *) {
      view
        .textContentType(.emailAddress)
    } else {
      view
    }
  }

  func sendCode() {
    formState.startLoading()

    Task {
      do {
        onboardingViewModel.phoneNumber = ""
        onboardingViewModel.emailChallengeToken = nil

        let data = try await ApiClient.shared.sendCode(email: onboardingViewModel.email)

        onboardingViewModel.existingUser = data.existingUser
        onboardingViewModel.emailChallengeToken = data.challengeToken
        onboardingViewModel.navigate(to: data.needsInviteCode == true ? .inviteCode : .enterCode)
      } catch {
        formState.failed(error: error.localizedDescription)
        Log.shared.error("Failed to send code", error: error)
      }
    }
  }
}

#Preview {
  OnboardingEnterEmail()
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
