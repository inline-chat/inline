import SwiftUI

struct GlassyActionButton: View {
    let title: String
    let loadingText: String?
    let action: () async -> Void
    @State private var isLoading = false

    var body: some View {
        Button {
            Task {
                isLoading = true
                await action()
                isLoading = false
            }
        } label: {
            HStack {
                if isLoading {
                    Text(loadingText ?? "Loading...")
                        .padding(.trailing, 6)

                } else {
                    Text(title)
                        .padding(.trailing, 6)
//                    Image(systemName: "chevron.right")
//                        .foregroundColor(.secondary)
//                        .font(.callout)
                }
            }
        }
        .buttonStyle(SimpleButtonStyle())
        .disabled(isLoading)
        .animation(.bouncy, value: isLoading)
    }
}

#Preview("GlassyActionButton States") {
    struct PreviewWrapper: View {
        @State private var isLoading = false

        var body: some View {
            VStack(spacing: 20) {
                GlassyActionButton(title: "Continue", loadingText: nil) {
                    // Simulating an async action
                    try? await Task.sleep(for: .seconds(2))
                }

                GlassyActionButton(title: "Loading", loadingText: "Loading") {
                    // This will never complete, simulating a long-running task
                    await withCheckedContinuation { _ in }
                }
                .onAppear { isLoading = true }

                GlassyActionButton(title: "Disabled", loadingText: nil) {}
                    .disabled(true)
            }
        }
    }

    return PreviewWrapper()
}
