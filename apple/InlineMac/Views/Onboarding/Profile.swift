import InlineKit
import SwiftUI

struct OnboardingProfile: View {
    @EnvironmentObject var onboardingViewModel: OnboardingViewModel
    @Environment(\.appDatabase) var database
    @FormState var formState
    @State var name: String = ""
    @State var username: String = ""

    enum Field {
        case name
        case username
    }
    
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack {
            Image(systemName: "person.and.background.dotted")
                .resizable(resizingMode: .tile)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundColor(.primary)
                .padding(.bottom, 4)
            
            Text("Set up your profile")
                .font(.system(size: 21.0, weight: .semibold))
                .foregroundStyle(.primary)
            
            self.nameField
                .focused(self.$focusedField, equals: .name)
                .disabled(self.formState.isLoading)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .onAppear {
                    self.focusedField = .name
                }
            
            self.usernameField
                .focused(self.$focusedField, equals: .name)
                .disabled(self.formState.isLoading)
                .padding(.bottom, 10)
                .onSubmit {
                    self.submit()
                }
            // todo .onChange start checking
            
            GrayButton {
                self.submit()
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
    
    @ViewBuilder var nameField: some View {
        let view = GrayTextField("Your Name", text: $name)
            .frame(width: 260)
        
        if #available(macOS 14.0, *) {
            view
                .textContentType(.name)
        } else {
            view
        }
    }
    
    @ViewBuilder var usernameField: some View {
        let view = GrayTextField("Username", text: $username)
            .frame(width: 260)
        
        if #available(macOS 14.0, *) {
            view
                .textContentType(.username)
        } else {
            view
        }
    }
    
    func submit() {
        Task {
            // todo
            let (firstName, lastName) = parseNameComponents(fullName: name)
            
            do {
                let result = try await ApiClient.shared
                    .updateProfile(firstName: firstName, lastName: lastName, username: username)
                
                // Todo: handle errors
                try await database.dbWriter.write { db in
                    try User(from: result.user).save(db)
                }
            } catch {
                formState.failed(error: error.localizedDescription)
            }
        }
    }
    
    fileprivate func parseNameComponents(fullName: String) -> (firstName: String, lastName: String?) {
        let formatter = PersonNameComponentsFormatter()
        if let components = formatter.personNameComponents(from: fullName) {
            if components.givenName == nil {
                return (fullName, nil)
            }
            return (firstName: components.givenName ?? fullName, lastName: components.familyName)
        }
        return (fullName, nil)
    }
}

#Preview {
    OnboardingProfile()
        .appDatabase(.empty())
        .environmentObject(OnboardingViewModel())
        .frame(width: 900, height: 600)
}
