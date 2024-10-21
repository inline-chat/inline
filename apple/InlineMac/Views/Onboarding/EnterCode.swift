import InlineKit
import SwiftUI

struct OnboardingEnterCode: View {
    @EnvironmentObject var onboardingViewModel: OnboardingViewModel
    @FormState var formState
    @State var code = ""
    
    enum Field {
        case codeField
    }
    
    @FocusState private var focusedField: Field?
    
    let codeLimit = 6
    
    var buttonLabel: String {
        switch onboardingViewModel.existingUser {
        case .none:
            return "Continue"
        case .some(true):
            return "Log In"
        case .some(false):
            return "Sign Up"
        }
    }
    
    var body: some View {
        VStack {
            Image(systemName: "numbers.rectangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundColor(.primary)
                .padding(.bottom, 4)
            
            Text("Enter confirmation code")
                .font(.system(size: 21.0, weight: .semibold))
                .foregroundStyle(.primary)
            
            self.emailField
                .focused($focusedField, equals: .codeField)
                .disabled(formState.isLoading)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .onSubmit {
                    self.submit()
                }
                .onChange(of: self.code) { newCode in
                    self.code = newCode.filter { $0.isNumber }
                    
//                    if newCode.count == codeLimit, !formState.isLoading {
//                        self.submit()
//                    } else {
//                    }
                }
                .onAppear {
                    focusedField = .codeField
                }
            
            GrayButton {
                self.submit()
            } label: {
                if !self.formState.isLoading {
                    Text(buttonLabel).padding(.horizontal)
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
        let view =
            GrayTextField("Code", text: $code, prompt: Text("123-456"))
                .frame(width: 260)
       
        if #available(macOS 14.0, *) {
            view
                .textContentType(.oneTimeCode)
        } else {
            view
        }
    }
    
    func submit() {
        formState.startLoading()
        
        Task {
            do {
                let result = try await ApiClient.shared.verifyCode(
                    code: self.code,
                    email: self.onboardingViewModel.email
                )
                
                switch result {
                case let .success(result) :
                    // self.formState.succeeded()
                    
                    Auth.shared.saveToken(result.token)
                    Auth.shared.saveCurrentUserId(userId: result.userId)
                    
                    // todo ...
                    
                    self.onboardingViewModel.navigateAfterLogin()
                case let .error(_, description):
                    self.formState.failed(error: description)
                }
            } catch {
                self.formState.failed(error: "Failed: \(error.localizedDescription)")
                Log.shared.error("Failed to send code", error: error)
            }
        }
    }
}

#Preview {
    OnboardingEnterCode()
        .environmentObject(OnboardingViewModel())
        .frame(width: 900, height: 600)
}
