import SwiftUI
import InlineKit

struct CreateSpaceSheet: View {
    @State private var spaceName: String = ""
    @FormState var formState
    @Environment(\.appDatabase) var db
    @Environment (\.dismiss) var dismiss

    
    var body: some View {
        VStack {
            Text("Create a new space").font(.headline)
                
            GrayTextField("Space Name", text: $spaceName)
                .frame(maxWidth: 200)
            GrayButton {
                Task {
                    do {
                        formState.startLoading()
                        let result = try await ApiClient.shared.createSpace(name: spaceName)
                        try await db.dbWriter.write { db in
                            try Space(from: result.space).save(db)
                            try Member(from: result.member).save(db)
                            try result.chats.forEach { chat in
                                try Chat(from: chat).save(db)
                            }
                            // ... save more stuff
                        }
                        formState.succeeded()
                        dismiss()
                    } catch {
                        formState.failed(error: error.localizedDescription)
                    }
                }
            } label: {
                if formState.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                } else {
                    Text("Create")
                }
            }

        }
        .padding()

    }
}

#Preview {
    CreateSpaceSheet()
        .previewsEnvironment(.empty)
}
