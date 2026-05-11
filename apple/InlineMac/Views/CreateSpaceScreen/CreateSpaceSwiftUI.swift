import InlineKit
import SwiftUI

struct CreateSpaceSwiftUI: View {
  @Environment(\.appDatabase) var db
  @EnvironmentObject var nav: Nav

  private let onComplete: ((Int64) -> Void)?

  @State private var spaceName: String = ""
  @FormState var formState
  @FocusState private var focusedField: Field?

  enum Field {
    case name
  }

  init(onComplete: ((Int64) -> Void)? = nil) {
    self.onComplete = onComplete
  }

  var body: some View {
    VStack(spacing: 12) {
      Text("Create Space").font(.title2)

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
          Text("Create").padding(.horizontal)
        }
      }
      .disabled(canSubmit == false)

      if let error = formState.error, error.isEmpty == false {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 240)
      }
    }
    .padding()
  }

  // MARK: Methods

  private var trimmedSpaceName: String {
    spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    formState.isLoading == false && trimmedSpaceName.isEmpty == false
  }

  private func submit() {
    guard canSubmit else { return }

    let name = trimmedSpaceName
    Task { @MainActor in
      do {
        formState.startLoading()
        let result = try await ApiClient.shared.createSpace(name: name)
        try await db.dbWriter.write { db in
          try Space(from: result.space).save(db)
          try Member(from: result.member).save(db)
          try result.chats.forEach { chat in
            try Chat(from: chat).save(db)
          }
          // ... save more stuff
        }
        formState.succeeded()

        if let onComplete {
          onComplete(result.space.id)
          return
        }

        // Navigate to the new space
        // nav.openSpace(result.space.id)

        // New way
        //nav.selectedSpaceId = result.space.id
        nav.selectedTab = .spaces
        nav.open(.empty)
      } catch {
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}

#Preview {
  CreateSpaceSwiftUI()
    .previewsEnvironment(.empty)
}
