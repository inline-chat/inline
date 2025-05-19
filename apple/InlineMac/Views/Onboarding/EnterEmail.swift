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
        .onAppear {
          focusedField = .codeField
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
        let data = try await ApiClient.shared.sendCode(email: onboardingViewModel.email)

        onboardingViewModel.existingUser = data.existingUser
        onboardingViewModel.navigate(to: .enterCode)
      } catch {
        formState.failed(error: "Failed: \(error.localizedDescription)")
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
