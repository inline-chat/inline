import InlineKit
import InlineUI
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Upload File Error Handling

enum UploadFileError: LocalizedError {
  case permissionDenied(String)
  case invalidFile(String)
  case unknown(Error)

  var errorDescription: String? {
    switch self {
      case let .permissionDenied(filename):
        "Cannot access '\(filename)'. Make sure you have permission to view this file."
      case let .invalidFile(filename):
        "'\(filename)' could not be opened. The file might be corrupted or in an unsupported format."
      case let .unknown(error):
        error.localizedDescription
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .permissionDenied:
        "Try selecting a different file or check the file permissions in Finder."
      case .invalidFile:
        "Please select a valid image file."
      case .unknown:
        "Please try again or select a different file."
    }
  }
}

// MARK: - Account Settings Photo View Model

@MainActor
final class AccountSettingsPhotoViewModel: ObservableObject {
  @Published private(set) var isUploading = false
  @Published var errorState: ErrorState?
  @Published var showUploadSheet = false

  private let maxFileSize = 10 * 1_024 * 1_024 // 10MB
  private let supportedImageTypes: Set<UTType> = [.jpeg, .png, .heic]

  struct ErrorState {
    let title: String
    let message: String
    let suggestion: String?
  }

  func uploadImage(from url: URL) async {
    guard !isUploading else { return }

    isUploading = true
    showUploadSheet = true

    do {
      guard url.startAccessingSecurityScopedResource() else {
        throw UploadFileError.permissionDenied(url.lastPathComponent)
      }

      defer {
        url.stopAccessingSecurityScopedResource()
      }

      // Verify file type
      guard let fileType = UTType(filenameExtension: url.pathExtension),
            supportedImageTypes.contains(fileType)
      else {
        throw UploadFileError.invalidFile(url.lastPathComponent)
      }

      // Verify file exists and get attributes
      let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
      guard let fileSize = resourceValues.fileSize,
            fileSize <= maxFileSize
      else {
        throw UploadFileError.invalidFile("\(url.lastPathComponent) exceeds maximum size of 10MB")
      }

      // Read file data
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        throw UploadFileError.permissionDenied(url.lastPathComponent)
      }

      try await uploadImageToServer(data, fileType: fileType)

      // Close sheet on success
      showUploadSheet = false
    } catch let error as UploadFileError {
      Log.shared.error("Failed to upload image", error: error)
      showError(error)
    } catch {
      Log.shared.error("Failed to upload image", error: error)
      showError(UploadFileError.unknown(error))
    }

    isUploading = false
  }

  private func uploadImageToServer(_ data: Data, fileType: UTType) async throws {
    let mimeType = switch fileType {
      case .jpeg:
        MIMEType.imageJpeg
      case .png:
        MIMEType.imagePng
      default:
        MIMEType.imageJpeg
    }

    let fileName = "profile_photo.\(fileType.preferredFilenameExtension ?? "jpg")"

    let result = try await ApiClient.shared
      .uploadFile(
        type: .photo,
        data: data,
        filename: fileName,
        mimeType: mimeType,
        progress: { _ in }
      )

    // call update profile photo method
    let result2 = try await ApiClient.shared.updateProfilePhoto(fileUniqueId: result.fileUniqueId)

    let _ = try await AppDatabase.shared.dbWriter.write { db in
      try result2.user.saveFull(db)
    }
  }

  private func showError(_ error: UploadFileError) {
    showUploadSheet = false
    errorState = ErrorState(
      title: "Upload Error",
      message: error.errorDescription ?? "An unknown error occurred",
      suggestion: error.recoverySuggestion
    )
  }
}

// MARK: - Account Settings Detail View

struct AccountSettingsDetailView: View {
  @EnvironmentObject private var root: RootData
  @Environment(\.logOut) private var logOut
  @StateObject private var photoViewModel = AccountSettingsPhotoViewModel()
  @State private var showImagePicker = false
  @State private var showLogoutConfirmation = false

  init() {}

  var body: some View {
    Form {
      Section("Profile") {
        if let user = root.currentUser {
          HStack(spacing: 12) {
            Button {
              showImagePicker = true
            } label: {
              UserAvatar(user: user, size: 48)
                .overlay(
                  Circle()
                    .stroke(.primary.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(photoViewModel.isUploading)

            VStack(alignment: .leading, spacing: 4) {
              Text(user.fullName)
                .font(.headline)

              Text(user.email ?? user.username ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Change Photo") {
              showImagePicker = true
            }
            .disabled(photoViewModel.isUploading)
          }
          .padding(.vertical, 8)
        }
      }

      Button("Sign Out", role: .destructive) {
        showLogoutConfirmation = true
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .environmentObject(root)
    .fileImporter(
      isPresented: $showImagePicker,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      Task {
        await handleImageSelection(result)
      }
    }
    .sheet(isPresented: $photoViewModel.showUploadSheet) {
      UploadProgressSheet()
        .environmentObject(photoViewModel)
    }
    .alert(
      photoViewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { photoViewModel.errorState != nil },
        set: { if !$0 { photoViewModel.errorState = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let errorState = photoViewModel.errorState {
        VStack(alignment: .leading, spacing: 8) {
          Text(errorState.message)
          if let suggestion = errorState.suggestion {
            Text(suggestion)
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .confirmationDialog(
      "Log Out",
      isPresented: $showLogoutConfirmation,
      titleVisibility: .visible
    ) {
      Button("Log Out", role: .destructive) {
        Task {
          await logOut()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Are you sure you want to log out?")
    }
  }

  private func handleImageSelection(_ result: Result<[URL], Error>) async {
    do {
      let urls = try result.get()
      guard let url = urls.first else { return }
      await photoViewModel.uploadImage(from: url)
    } catch {
      // Handle file selection error
      photoViewModel.errorState = AccountSettingsPhotoViewModel.ErrorState(
        title: "Selection Error",
        message: "Could not select the image file.",
        suggestion: "Please try selecting a different image."
      )
    }
  }
}

// MARK: - Upload Progress Sheet

struct UploadProgressSheet: View {
  @EnvironmentObject var photoViewModel: AccountSettingsPhotoViewModel

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        VStack(spacing: 16) {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(1.2)

          Text("Uploading Profile Photo...")
            .font(.headline)
        }

        Text("Please wait while your photo is being uploaded.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Spacer()
      }
      .padding()
      .frame(minWidth: 320, minHeight: 200)
      .navigationTitle("Upload Photo")
    }
    .presentationDetents([.height(280)])
    .interactiveDismissDisabled()
  }
}

#Preview {
  AccountSettingsDetailView()
    .previewsEnvironment(.populated)
}
