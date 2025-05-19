import InlineKit
import SwiftUI

struct CreateSpaceSheet: View {
  @State private var spaceName: String = ""
  @FormState var formState
  @Environment(\.appDatabase) var db
  @Environment(\.dismiss) var dismiss
  @FocusState private var focusedField: Field?

  enum Field {
    case name
  }

  var body: some View {
    VStack {
      Text("Create a new supergroup (team)").font(.title2)

      GrayTextField("eg. AGI Fellows", text: $spaceName, size: .medium)
        .frame(maxWidth: 200)
        .disabled(formState.isLoading)
        .focused($focusedField, equals: .name)
        .onSubmit {
          submit()
        }
        .onAppear {
          focusedField = .name
        }

      InlineButton(size: .medium) {
        submit()
      } label: {
        if formState.isLoading {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(0.5)
        } else {
          Text("Done").padding(.horizontal)
        }
      }
    }
    .padding()
  }

  // MARK: Methods

  private func submit() {
    Task {
      if spaceName.isEmpty {
        return
      }
      
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
  }
}

#Preview {
  CreateSpaceSheet()
    .previewsEnvironment(.empty)
}
