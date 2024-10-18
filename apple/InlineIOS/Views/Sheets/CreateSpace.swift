import InlineKit
import SwiftUI

struct CreateSpace: View {
    @State private var animate: Bool = false
    @State private var name = ""
    @FocusState private var isFocused: Bool
    @FormState var formState

    @Environment(\.appDatabase) var database

    @Binding var showSheet: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AnimatedLabel(animate: $animate, text: "Create Space")

            TextField("eg. Acme HQ", text: $name)
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.vertical, 8)
                .onChange(of: isFocused) { _, newValue in
                    withAnimation(.smooth(duration: 0.15)) {
                        animate = newValue
                    }
                }
        }
        .onAppear {
            isFocused = true
        }
        .padding(.horizontal, 50)
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button(formState.isLoading ? "Creating..." : "Create") {
                    Task {
                        do {
                            formState.startLoading()
                            try await database.dbWriter.write { db in
                                let space = Space(name: name, createdAt: Date.now)

                                try space.insert(db)

                                let member = Member(createdAt: Date.now, userId: Auth.shared.getCurrentUserId()!, spaceId: space.id)
                                try member.insert(db)
                            }
                            formState.succeeded()
                            showSheet = false
                        } catch {
                            Log.shared.error("Failed to create space", error: error)
                        }
                    }
                }
                .buttonStyle(SimpleButtonStyle())
                .padding(.horizontal, OnboardingUtils.shared.hPadding)
                .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
                .disabled(name.isEmpty)
                .opacity(name.isEmpty ? 0.5 : 1)
            }
        }
    }
}
