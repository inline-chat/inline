import Auth
import GRDBQuery
import InlineKit
import Logger
import SwiftUI

struct SettingsView: View {
  @Query(CurrentUser()) var currentUser: UserInfo?
  @Environment(\.auth) var auth
  @EnvironmentObject private var navigation: Navigation
  @EnvironmentObject private var onboardingNavigation: OnboardingNavigation
  @EnvironmentObject private var mainRouter: MainViewRouter
  @EnvironmentObject private var fileUploadViewModel: FileUploadViewModel
  @State private var isClearing = false
  @State private var showClearCacheAlert = false
  @State private var clearCacheError: Error?
  @State private var showClearCacheError = false

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
              .background(Color.orange)
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
      NavigationLink(destination: ThemeSelectionView()) {
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

      Section {
        Button {
          showClearCacheAlert = true
        } label: {
          HStack {
            Image(systemName: "eraser.fill")
              .foregroundColor(.white)
              .frame(width: 25, height: 25)
              .background(Color.red)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Clear Cache")
              .foregroundColor(.primary)
              .padding(.leading, 4)
            Spacer()
            if isClearing {
              ProgressView()
                .padding(.trailing, 8)
            }
          }
          .padding(.vertical, 2)
        }
        .disabled(isClearing)
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
          do {
            // Create temporary file URL for the original image
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("profile_\(UUID().uuidString).jpg")

            // Save original image to temp file
            if let jpegData = image.jpegData(compressionQuality: 1.0) {
              try jpegData.write(to: tempURL)

              // Compress the image using ImageCompressor
              let compressedURL = try await ImageCompressor.shared.compressImage(
                at: tempURL,
                options: .defaultPhoto
              )

              // Read the compressed data and upload
              let compressedData = try Data(contentsOf: compressedURL)
              await fileUploadViewModel.uploadImage(compressedData, fileType: .jpeg)

              // Clean up temp files
              try? FileManager.default.removeItem(at: tempURL)
              try? FileManager.default.removeItem(at: compressedURL)
            }
          } catch {
            Log.scoped("Settings").error("Failed to compress profile image", error: error)
          }
        }
      }
    }
    .alert("Clear Cache", isPresented: $showClearCacheAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        clearCache()
      }
    } message: {
      Text("This will clear all locally cached images. Downloaded content will need to be re-downloaded.")
    }
    .alert("Error Clearing Cache", isPresented: $showClearCacheError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(clearCacheError?.localizedDescription ?? "An unknown error occurred")
    }
  }

  private func clearCache() {
    isClearing = true

    Task {
      do {
        navigation.pop()
        try await FileCache.shared.clearCache()
        Transactions.shared.clearAll()
        try? AppDatabase.clearDB()
        await MainActor.run {
          isClearing = false
        }
      } catch {
        await MainActor.run {
          clearCacheError = error
          showClearCacheError = true
          isClearing = false
        }
      }
    }
  }
}

#Preview("Settings") {
  SettingsView()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
}
