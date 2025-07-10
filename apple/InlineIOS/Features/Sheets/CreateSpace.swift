import InlineKit
import InlineUI
import Logger
import SwiftUI

struct CreateSpace: View {
  @State private var animate: Bool = false
  @State private var name = ""
  @FocusState private var isFocused: Bool
  @FormState var formState

  @EnvironmentObject var nav: Navigation
  @Environment(\.appDatabase) var database
  @Environment(\.dismiss) var dismiss
  @Environment(Router.self) private var router
  @EnvironmentObject var dataManager: DataManager

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            InitialsCircle(name: name, size: 40)
            TextField("eg. AGL Fellows", text: $name)
              .focused($isFocused)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .onSubmit {
                submit()
              }
          }
        }
      }
      .themedListStyle()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(content: {
        ToolbarItem(placement: .principal) {
          Text("Create a new space (team)")
            .themedPrimaryText()
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(formState.isLoading ? "Creating..." : "Create") {
            submit()
          }
          .disabled(name.isEmpty)
          .opacity(name.isEmpty ? 0.5 : 1)
        }
      })
      .onAppear {
        isFocused = true
      }
    }
    .themedSheet()
  }

  func submit() {
    Task {
      do {
        formState.startLoading()
        let id = try await dataManager.createSpace(name: name)

        formState.succeeded()
        dismiss()

        if let id {
          router.selectedTab = .spaces
          router.push(.space(id: id))
        }

      } catch {
        // TODO: handle error
        Log.shared.error("Failed to create space", error: error)
        formState.failed(error: error.localizedDescription)
      }
    }
  }
}
