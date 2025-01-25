import InlineKit
import InlineUI
import SwiftUI

struct UserProfileSection: View {
  let currentUser: User?

  var body: some View {
    Section(header: Text("Account")) {
      if let user = currentUser {
        ProfileRow(user: user)
      } else {
        Button("Set up profile") {
          // TODO: Add profile setup
        }
      }
    }
  }
}

struct ProfileRow: View {
  let user: User

  private var fullName: String {
    [user.firstName, user.lastName]
      .compactMap { $0 }
      .joined(separator: " ")
  }

  var body: some View {
    HStack {
      UserAvatar(user: user, size: 42)
        .padding(.trailing, 6)

      VStack(alignment: .leading) {
        Text(fullName)
          .font(.body)
          .fontWeight(.medium)

        Text(user.email ?? "")
          .font(.callout)
          .foregroundColor(.secondary)
      }
    }
  }
}
