import InlineKit
import InlineUI
import SwiftUI

struct SearchParticipantsView: View {
  @Binding var searchText: String
  let searchResults: [UserInfo]
  let isSearching: Bool
  let onSearchTextChanged: (String) -> Void
  let onDebouncedInput: (String?) -> Void
  let onAddParticipant: (UserInfo) -> Void
  let onCancel: () -> Void
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var body: some View {
    NavigationView {
      VStack {
        if !searchResults.isEmpty {
          List {
            ForEach(searchResults, id: \.user.id) { userInfo in
              Button(action: { onAddParticipant(userInfo) }) {
                HStack(spacing: 9) {
                  UserAvatar(userInfo: userInfo, size: 32)
                  Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                }
              }
            }
          }
        } else {
          if isSearching {
            VStack {
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          } else {
            VStack(spacing: 4) {
              Text("🔍")
                .font(.largeTitle)
                .foregroundColor(.primary)
                .padding(.bottom, 14)
              Text("Search for people")
                .font(.headline)
                .foregroundColor(.primary)
              Text("Type a username to find someone to add. eg. dena, mo")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 45)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      .searchable(text: $searchText, prompt: "Find")
      .onChange(of: searchText) { _, newValue in
        searchDebouncer.input = newValue
      }
      .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
        onDebouncedInput(debouncedValue)
      }
      .navigationTitle("Add Participant")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
    }
  }
}
