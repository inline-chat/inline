import Auth
import GRDBQuery
import InlineKit
import Logger
import SwiftUI
import Translation

struct SettingsView: View {
  @Query(CurrentUser()) var currentUser: UserInfo?
  @Environment(\.auth) var auth
  @Environment(Router.self) private var router
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var onboardingNavigation: OnboardingNavigation
  @EnvironmentObject private var mainRouter: MainViewRouter
  @EnvironmentObject private var fileUploadViewModel: FileUploadViewModel

  @State private var isClearing = false
  @State private var showClearCacheAlert = false
  @State private var clearCacheError: Error?
  @State private var showClearCacheError = false
  @State private var pickedImage: UIImage? = nil
  @State private var showCropper: Bool = false

  var body: some View {
    List {
      UserProfileSection(currentUser: currentUser)

      Section {
        Button {
          fileUploadViewModel.showImagePicker = true
        } label: {
          SettingsItem(
            icon: "camera.fill",
            iconColor: .orange,
            title: "Change Profile Photo"
          )
        }
      }

      // Integrations are now managed per-space (Linear/Notion are space-scoped).
      // Global Integrations UI is temporarily disabled.

      NavigationLink(destination: ThemeSelectionView()) {
        SettingsItem(
          icon: "paintbrush.fill",
          iconColor: .blue,
          title: "Appearance"
        )
      }

      NavigationLink(destination: DebugView()) {
        SettingsItem(
          icon: "ladybug.fill",
          iconColor: .green,
          title: "Debug"
        )
      }

      NavigationLink(destination: ExperimentalView()) {
        SettingsItem(
          icon: "testtube.2",
          iconColor: .orange,
          title: "Experimental"
        )
      }

      Section {
        Button {
          showClearCacheAlert = true
        } label: {
          SettingsItem(
            icon: "eraser.fill",
            iconColor: .red,
            title: "Clear Cache"
          ) {
            if isClearing {
              ProgressView()
                .padding(.trailing, 8)
            }
          }
        }
        .disabled(isClearing)

        Button {
          TranslationAlertDismiss.shared.resetAllDismissStates()
        } label: {
          SettingsItem(
            icon: "bell.badge.slash.fill",
            iconColor: .orange,
            title: "Reset Translation Alerts"
          )
        }
      }

      LogoutSection()
    }
    .listStyle(.insetGrouped)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbarRole(.editor)
    .toolbar(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItem(id: "settings", placement: .principal) {
        HStack {
          Image(systemName: "gearshape.fill")
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Settings")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }

      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismissSettings()
        } label: {
          Image(systemName: "xmark")
            .fontWeight(.semibold)
        }
      }
    }
    .sheet(isPresented: $fileUploadViewModel.showImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        pickedImage = image
        showCropper = true
      }
    }
    .sheet(isPresented: $showCropper, onDismiss: { pickedImage = nil }) {
      if let image = pickedImage {
        CircularCropView(image: image) { croppedImage in
          Task {
            do {
              // Create temporary file URL for the cropped image
              let tempDir = FileManager.default.temporaryDirectory
              let tempURL = tempDir.appendingPathComponent("profile_\(UUID().uuidString)_cropped.jpg")

              // Save cropped image to temp file
              if let jpegData = croppedImage.jpegData(compressionQuality: 1.0) {
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
              Log.scoped("Settings").error("Failed to compress/crop profile image", error: error)
            }
            pickedImage = nil
            showCropper = false
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
    dismissSettings()

    Task {
      do {
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

  private func dismissSettings() {
    router.dismissSheet()
    dismiss()
  }
}

#Preview("Settings") {
  SettingsView()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
    .environmentObject(OnboardingNavigation())
    .environmentObject(MainViewRouter())
    .environmentObject(FileUploadViewModel())
    .environment(Router(initialTab: .chats))
}
