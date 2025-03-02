import Auth
import GRDBQuery
import InlineKit
import SwiftUI

struct SettingsView: View {
  @Query(CurrentUser()) var currentUser: UserInfo?
  @Environment(\.auth) var auth
  @EnvironmentObject private var webSocket: WebSocketManager
  @EnvironmentObject private var navigation: Navigation
  @EnvironmentObject private var onboardingNavigation: OnboardingNavigation
  @EnvironmentObject private var mainRouter: MainViewRouter
  @EnvironmentObject private var fileUploadViewModel: FileUploadViewModel

  var body: some View {
    List {
      UserProfileSection(currentUser: currentUser)
      Section {
        Button {
          fileUploadViewModel.showImagePicker = true
        } label: {
          HStack {
            Image(systemName: "camera.fill")
              .font(.callout)
              .foregroundColor(.white)
              .frame(width: 25, height: 25)
              .background(Color.pink)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Change Profile Photo")
              .foregroundColor(.primary)
              .padding(.leading, 4)
            Spacer()
          }
          .padding(.vertical, 2)
        }
      }

      NavigationLink(destination: IntegrationsView()) {
        HStack {
          Image(systemName: "app.connected.to.app.below.fill")
            .foregroundColor(.white)
            .frame(width: 25, height: 25)
            .background(Color.purple)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text("Integrations")
            .foregroundColor(.primary)
            .padding(.leading, 4)
          Spacer()
        }
        .padding(.vertical, 2)
      }
      NavigationLink(destination: ThemeSection()) {
        HStack {
          Image(systemName: "paintbrush.fill")
            .foregroundColor(.white)
            .frame(width: 25, height: 25)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text("Appearance")
            .foregroundColor(.primary)
            .padding(.leading, 4)
          Spacer()
        }
        .padding(.vertical, 2)
      }

      LogoutSection()
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "settings", placement: .principal) {
        HStack {
          Image(systemName: "gearshape.fill")
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Settings")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
    .sheet(isPresented: $fileUploadViewModel.showImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        Task {
          if let pngData = image.pngData() {
            await fileUploadViewModel.uploadImage(pngData, fileType: .png)
          } else if let jpegData = image.jpegData(compressionQuality: 0.8) {
            await fileUploadViewModel.uploadImage(jpegData, fileType: .jpeg)
          }
        }
      }
    }
  }
}

#Preview("Settings") {
  SettingsView()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
}
