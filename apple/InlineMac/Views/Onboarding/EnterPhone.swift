import InlineKit
import Logger
import SwiftUI

struct OnboardingEnterPhone: View {
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel
  @FormState var formState

  enum Field {
    case codeField
  }

  @FocusState private var focusedField: Field?

  @State var phoneNumber = ""
  @State var country = Country.getCurrentCountry()

  var body: some View {
    VStack {
      Image(systemName: "checkmark.message.fill")
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
        .foregroundColor(.primary)
        .padding(.bottom, 4)

      Text("Continue with phone")
        .font(.system(size: 21.0, weight: .semibold))
        .foregroundStyle(.primary)

      PhoneNumberField(phoneNumber: $phoneNumber, country: $country)
        .disabled(formState.isLoading)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: 250)
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

  func sendCode() {
    formState.startLoading()

    Task {
      do {
        let fullPhoneNumber = country.dialCode + phoneNumber
        
        onboardingViewModel.phoneNumber = fullPhoneNumber
        onboardingViewModel.email = ""
        
        let data = try await ApiClient.shared.sendSmsCode(
          phoneNumber: fullPhoneNumber
        )

        onboardingViewModel.existingUser = data.existingUser
        onboardingViewModel.navigate(to: .enterCode)
      } catch {
        formState.failed(error: "Failed: \(error.localizedDescription)")
        Log.shared.error("Failed to send sms code", error: error)
      }
    }
  }
}

#Preview {
  OnboardingEnterPhone()
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
