import InlineKit
import InlineUI
import SwiftUI

struct SearchParticipantsView: View {
  @Binding var searchText: String
  let searchResults: [UserInfo]
  let groupResults: [UserGroup]
  let isSearching: Bool
  let onSearchTextChanged: (String) -> Void
  let onDebouncedInput: (String?) -> Void
  let onAddParticipant: (UserInfo) -> Void
  let onAddGroup: (UserGroup) -> Void
  let onCancel: () -> Void
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var body: some View {
    NavigationView {
      VStack {
        if !searchResults.isEmpty || !groupResults.isEmpty {
          List {
            if !groupResults.isEmpty {
              Section("Groups") {
                ForEach(groupResults) { group in
                  Button(action: { onAddGroup(group) }) {
                    HStack(spacing: 9) {
                      Image(systemName: "person.3.fill")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor)
                        .clipShape(Circle())

                      VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                          .fontWeight(.medium)
                          .foregroundColor(.primary)
                        Text(groupSubtitle(group))
                          .font(.footnote)
                          .foregroundStyle(.secondary)
                          .lineLimit(1)
                      }
                    }
                  }
                }
              }
            }

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
              Text("Search for people or groups")
                .font(.headline)
                .foregroundColor(.primary)
              Text("Type a username or group name to find access to add.")
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

  private func groupSubtitle(_ group: UserGroup) -> String {
    let count = group.memberCount == 1 ? "1 person" : "\(group.memberCount) people"
    guard let description = group.description, !description.isEmpty else {
      return count
    }
    return "\(description) - \(count)"
  }
}
