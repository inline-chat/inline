import InlineKit
import SwiftUI

struct OnboardingInviteCode: View {
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel
  @State private var code = ""
  @FormState var formState

  enum Field {
    case code
  }

  @FocusState private var focusedField: Field?

  private var normalizedCode: String {
    code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private var canContinue: Bool {
    normalizedCode.count == 8
  }

  var body: some View {
    VStack {
      Image(systemName: "ticket.fill")
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
        .foregroundColor(.primary)
        .padding(.bottom, 4)

      Text("Enter invite code")
        .font(.system(size: 21.0, weight: .semibold))
        .foregroundStyle(.primary)

      inviteField
        .focused($focusedField, equals: .code)
        .disabled(formState.isLoading)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onSubmit {
          submit()
        }
        .onChange(of: code) { newValue in
          code = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        }
        .onAppear {
          code = onboardingViewModel.inviteCode
          focusedField = .code
        }

      if let error = formState.error {
        Text(error)
          .font(.callout)
          .foregroundColor(.red)
          .multilineTextAlignment(.center)
          .frame(width: 260)
          .padding(.bottom, 8)
      }

      InlineButton {
        submit()
      } label: {
        if !formState.isLoading {
          Text("Continue").padding(.horizontal)
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(0.5)
        }
      }
      .disabled(!canContinue || formState.isLoading)
      .opacity((canContinue && !formState.isLoading) ? 1 : 0.5)
    }
    .padding()
  }

  @ViewBuilder var inviteField: some View {
    GrayTextField("Invite Code", text: $code, prompt: Text("A7K2PQ9X"))
      .frame(width: 260)
      .textContentType(.oneTimeCode)
  }

  func submit() {
    guard canContinue, !formState.isLoading else { return }

    formState.startLoading()

    Task {
      do {
        _ = try await ApiClient.shared.checkInviteCode(normalizedCode)
        formState.reset()
        onboardingViewModel.inviteCode = normalizedCode
        onboardingViewModel.navigate(to: .enterCode)
      } catch {
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}

#Preview {
  OnboardingInviteCode()
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
