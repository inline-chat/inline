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
  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var tabsManager: TabsManager
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
      .background(.clear)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(content: {
        ToolbarItem(placement: .topBarLeading) {
          Text("Create a new supergroup (team)")
            .fontWeight(.bold)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(formState.isLoading ? "Creating..." : "Create") {
            submit()
          }
          .buttonStyle(.borderless)
          .disabled(name.isEmpty)
          .opacity(name.isEmpty ? 0.5 : 1)
        }
      })
      .onAppear {
        isFocused = true
      }
    }
  }

  func submit() {
    Task {
      do {
        formState.startLoading()
        let id = try await dataManager.createSpace(name: name)

        formState.succeeded()
        dismiss()

        if let id {
          tabsManager.setSelectedTab(.spaces)
          tabsManager.setActiveSpaceId(id)
        }

      } catch {
        // TODO: handle error
        Log.shared.error("Failed to create space", error: error)
      }
      dismiss()
    }
  }
}
