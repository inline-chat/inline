import InlineKit
import InlineUI
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers
import Logger

// MARK: - Custom Errors

enum FileError: LocalizedError {
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

// MARK: - View Models

@MainActor
final class ProfilePhotoViewModel: ObservableObject {
  @Published private(set) var isUploading = false
  @Published var errorState: ErrorState?
  @Published var isDragging = false

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

    do {
      guard url.startAccessingSecurityScopedResource() else {
        throw FileError.permissionDenied(url.lastPathComponent)
      }

      defer {
        url.stopAccessingSecurityScopedResource()
      }

      // Verify file type
      guard let fileType = UTType(filenameExtension: url.pathExtension),
            supportedImageTypes.contains(fileType)
      else {
        throw FileError.invalidFile(url.lastPathComponent)
      }

      // Verify file exists and get attributes
      let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
      guard let fileSize = resourceValues.fileSize,
            fileSize <= maxFileSize
      else {
        throw FileError.invalidFile("\(url.lastPathComponent) exceeds maximum size of 10MB")
      }

      // Read file data
      let data: Data
      do {
        data = try Data(contentsOf: url)

      } catch {
        throw FileError.permissionDenied(url.lastPathComponent)
      }

      try await uploadImageToServer(data, fileType: fileType)
    } catch let error as FileError {
      Log.shared.error("Failed to upload image", error: error)
      showError(error)
    } catch {
      Log.shared.error("Failed to upload image", error: error)
      showError(FileError.unknown(error))
    }

    isUploading = false
  }

  func uploadImage(_ data: Data) async {
    guard !isUploading else { return }

    isUploading = true

    do {
      guard data.count <= maxFileSize else {
        throw FileError.invalidFile("File exceeds maximum size of 10MB")
      }

      try await uploadImageToServer(data, fileType: .jpeg)
    } catch let error as FileError {
      Log.shared.error("Failed to upload image", error: error)

      showError(error)
    } catch {
      Log.shared.error("Failed to upload image", error: error)

      showError(FileError.unknown(error))
    }

    isUploading = false
  }

  private func uploadImageToServer(_ data: Data, fileType: UTType) async throws {
    // TODO: ensure it's jpg or png

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

  private func showError(_ error: FileError) {
    errorState = ErrorState(
      title: "Upload Error",
      message: error.errorDescription ?? "An unknown error occurred",
      suggestion: error.recoverySuggestion
    )
  }
}

// MARK: - Profile Photo View

struct ProfilePhotoView: View {
  @StateObject private var viewModel = ProfilePhotoViewModel()
  @State private var showImagePicker = false
  let userInfo: UserInfo
  let size: CGFloat

  var body: some View {
    Button {
      showImagePicker = true
    } label: {
      ZStack {
        UserAvatar(userInfo: userInfo, size: size)
          .overlay(
            Group {
              if viewModel.isUploading {
                ProgressView()
                  .progressViewStyle(.circular)
                  .background(.ultraThinMaterial)
              }
            }
          )

        if viewModel.isDragging {
          RoundedRectangle(cornerRadius: size / 2)
            .stroke(.blue, lineWidth: 2)
            .background(.ultraThinMaterial)
        }
      }
    }
    .frame(width: size, height: size)
    .buttonStyle(.plain)
    .disabled(viewModel.isUploading)
    .dropDestination(
      for: Data.self,
      action: handleDrop,
      isTargeted: { isDragging in
        viewModel.isDragging = isDragging
      }
    )
    .fileImporter(
      isPresented: $showImagePicker,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      Task {
        await handleImageSelection(result)
      }
    }
    .alert(
      viewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { viewModel.errorState != nil },
        set: { if !$0 { viewModel.errorState = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let errorState = viewModel.errorState {
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
    .accessibilityLabel("Profile photo")
    .accessibilityHint("Double tap to change profile photo")
  }

  private func handleDrop(_ items: [Data], _ location: CGPoint) -> Bool {
    guard let data = items.first else { return false }

    Task {
      await viewModel.uploadImage(data)
    }
    return true
  }

  private func handleImageSelection(_ result: Result<[URL], Error>) async {
    do {
      let urls = try result.get()
      guard let url = urls.first else { return }
      await viewModel.uploadImage(from: url)
    } catch {
      await viewModel.uploadImage(from: URL(fileURLWithPath: ""))
    }
  }
}

// MARK: - User Profile View

struct UserProfile: View {
  var userInfo: UserInfo
  private let size: CGFloat = 36
  
  private var user: User {
    userInfo.user
  }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          ProfilePhotoView(userInfo: userInfo, size: size)

          VStack(alignment: .leading, spacing: 0) {
            Text(user.fullName)
              .font(.title3)

            if let username = user.username {
              Text("@\(username)")
                .foregroundColor(.secondary)
            } else if let email = user.email {
              Text(email)
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
    .frame(minWidth: 320)
    .formStyle(.grouped)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text("Profile")
      }
    }
  }
}
