import InlineKit
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
            
            self.emailField
                .focused($focusedField, equals: .codeField)
                .disabled(formState.isLoading)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .onSubmit {
                    self.sendCode()
                }
                .onAppear {
                    focusedField = .codeField
                }
            
            GrayButton {
                self.sendCode()
            } label: {
                if !self.formState.isLoading {
                    Text("Continue").padding(.horizontal)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                }
            }
            
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
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
        self.formState.startLoading()
        
        Task {
            do {
                let result = try await ApiClient.shared.sendCode(email: self.onboardingViewModel.email)
                
                if result.ok {
                    // self.formState.succeeded()
                    self.onboardingViewModel.existingUser = result.existingUser;
                    self.onboardingViewModel.navigate(to: .enterCode)
                } else {
                    self.formState.failed(error: result.description)
                }
            } catch {
                self.formState.failed(error: "Failed: \(error.localizedDescription)")
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
