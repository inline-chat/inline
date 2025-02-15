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
  @Published var showImagePicker = false

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

  func uploadImage(_ data: Data, fileType: UTType) async {
    guard !isUploading else { return }
    isUploading = true

    do {
      guard data.count <= maxFileSize else {
        throw FileError.invalidFile("File exceeds maximum size of 10MB")
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

  private func uploadImageToServer(_ data: Data, fileType: UTType) async throws {
    let mimeType = switch fileType {
      case .jpeg: MIMEType.imageJpeg
      case .png: MIMEType.imagePng
      default: MIMEType.imageJpeg
    }

    let fileName = "profile_photo.\(fileType.preferredFilenameExtension ?? "png")"

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

struct ProfilePage: View {
  let userInfo: UserInfo
  private let size: CGFloat = 60
  @StateObject private var viewModel = ProfilePhotoViewModel()

  private var user: User {
    userInfo.user
  }

  var body: some View {
    NavigationView {
      Form {
        Section {
          HStack(spacing: 16) {
            ProfilePhotoView(viewModel: viewModel, userInfo: userInfo, size: size)

            VStack(alignment: .leading, spacing: 0) {
              Text(user.fullName)
                .font(.body.weight(.semibold))

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
        Section {
          Button {
            viewModel.showImagePicker = true
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
      }
      .navigationTitle("Profile")
      .navigationBarTitleDisplayMode(.inline)
      .formStyle(.grouped)
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
    }
  }
}

struct ProfilePhotoView: View {
  @ObservedObject var viewModel: ProfilePhotoViewModel
  let userInfo: UserInfo
  let size: CGFloat

  var body: some View {
    Button {
      viewModel.showImagePicker = true
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
      }
    }
    .frame(width: size, height: size)
    .buttonStyle(.plain)
    .disabled(viewModel.isUploading)
    .sheet(isPresented: $viewModel.showImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        Task {
          // Preserve transparency for PNGs
          if let pngData = image.pngData() {
            await viewModel.uploadImage(pngData, fileType: .png)
          } else if let jpegData = image.jpegData(compressionQuality: 0.8) {
            await viewModel.uploadImage(jpegData, fileType: .jpeg)
          }
        }
      }
    }
    .accessibilityLabel("Profile photo")
    .accessibilityHint("Double tap to change profile photo")
  }
}

struct ImagePicker: UIViewControllerRepresentable {
  var sourceType: UIImagePickerController.SourceType
  var completion: (UIImage) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = sourceType
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    let parent: ImagePicker

    init(_ parent: ImagePicker) {
      self.parent = parent
    }

    func imagePickerController(
      _ picker: UIImagePickerController,

      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        parent.completion(image)
      }
      picker.dismiss(animated: true)
    }
  }
}
