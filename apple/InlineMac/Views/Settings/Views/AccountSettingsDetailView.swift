import SwiftUI
import InlineKit
import InlineUI

struct AccountSettingsDetailView: View {
  @EnvironmentStateObject private var root: RootData
  @Environment(\.logOut) private var logOut
  
  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }
  
  var body: some View {
    Form {
      Section("Profile") {
        if let user = root.currentUser {
          HStack(spacing: 12) {
            UserAvatar(user: user, size: 48)
            
            VStack(alignment: .leading, spacing: 4) {
              Text(user.fullName)
                .font(.headline)
              
              Text(user.email ?? user.username ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
          }
          .padding(.vertical, 8)
        }
      }
      
      Section("Account") {
        Button("Sign Out", role: .destructive) {
          Task {
            await logOut()
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
    .environmentObject(root)
  }
}

#Preview {
  AccountSettingsDetailView()
    .previewsEnvironment(.populated)
}