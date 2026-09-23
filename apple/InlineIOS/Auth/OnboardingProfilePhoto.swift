import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingProfilePhoto {
  enum FileFormat {
    case jpeg
    case png
  }

  let data: Data
  let image: UIImage
  let xHandle: String?
  let fileFormat: FileFormat
  var isUploaded = false

  init(data: Data, xHandle: String? = nil, fileFormat: FileFormat = .png) throws {
    guard let image = UIImage(data: data) else { throw OnboardingProfilePhotoError.invalidImage }
    self.data = data
    self.image = image
    self.xHandle = xHandle
    self.fileFormat = fileFormat
  }
}

enum OnboardingProfilePhotoError: LocalizedError {
  case invalidImage
  case imageTooLarge
  case notFound
  case unavailable
  case previewUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidImage: "That photo could not be opened. Please choose another image."
    case .imageTooLarge: "Choose a photo smaller than 10 MB."
    case .notFound: "No public profile photo was found for that X username."
    case .unavailable: "X photo lookup is temporarily unavailable. Try again or choose a photo from your library."
    case .previewUnavailable: "X lookup is unavailable in this offline preview. You can still choose a photo from your library."
    }
  }
}

enum OnboardingProfilePhotoProcessor {
  static func prepare(_ data: Data, cropToSquare: Bool = true) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      guard data.count <= 10 * 1_024 * 1_024 else { throw OnboardingProfilePhotoError.imageTooLarge }
      guard let source = CGImageSourceCreateWithData(data as CFData, [
        kCGImageSourceShouldCache: false,
      ] as CFDictionary),
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1_024,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
      else { throw OnboardingProfilePhotoError.invalidImage }

      let output: CGImage
      if cropToSquare {
        let side = min(thumbnail.width, thumbnail.height)
        guard let cropped = thumbnail.cropping(to: CGRect(
          x: (thumbnail.width - side) / 2,
          y: (thumbnail.height - side) / 2,
          width: side,
          height: side
        )) else { throw OnboardingProfilePhotoError.invalidImage }
        output = cropped
      } else {
        output = thumbnail
      }

      // Re-encode pixels only: never upload the original location/EXIF metadata.
      let encoded = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
      else { throw OnboardingProfilePhotoError.invalidImage }
      CGImageDestinationAddImage(destination, output, nil)
      guard CGImageDestinationFinalize(destination) else { throw OnboardingProfilePhotoError.invalidImage }
      return encoded as Data
    }.value
  }
}

struct OnboardingProfilePhotoPicker<Avatar: View>: View {
  @Binding var photo: OnboardingProfilePhoto?
  @Binding var isLoading: Bool
  @Binding var errorMessage: String
  let size: CGFloat
  let hasExistingPhoto: Bool
  let isSaving: Bool
  let lookupPhoto: @MainActor (String) async throws -> Data
  let savePhoto: @MainActor (OnboardingProfilePhoto) async throws -> OnboardingProfilePhoto
  @ViewBuilder var avatar: Avatar

  @State private var showsImagePicker = false
  @State private var showsCropper = false
  @State private var showsPhotoSourceDialog = false
  @State private var showsXPicker = false
  @State private var pickedImage: UIImage?
  @State private var uploadID: UUID?
  @State private var uploadTask: Task<Void, Never>?

  private var hasPhoto: Bool { photo != nil || hasExistingPhoto }

  var body: some View {
    Button {
      dismissKeyboard()
      showsPhotoSourceDialog = true
    } label: {
      Group {
        if let photo {
          Image(uiImage: photo.image)
            .resizable()
            .scaledToFill()
        } else if hasExistingPhoto {
          avatar
        } else {
          Circle()
            .fill(Color.accentColor.opacity(0.1))
            .overlay {
              Image(systemName: "camera.fill")
                .font(.system(size: size * 0.29, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isLoading || isSaving)
    .accessibilityLabel(isLoading ? "Loading profile photo" : hasPhoto ? "Edit profile photo" : "Add profile photo")
    .confirmationDialog(
      "",
      isPresented: $showsPhotoSourceDialog,
      titleVisibility: .hidden
    ) {
      Button {
        showsImagePicker = true
      } label: {
        Label("Choose Photo…", systemImage: "photo.on.rectangle")
      }
      Button {
        showsXPicker = true
      } label: {
        Label("From X…", systemImage: "at")
      }
      if let photo, !photo.isUploaded {
        Button {
          self.photo = nil
          errorMessage = ""
        } label: {
          Label("Undo Photo Change", systemImage: "arrow.uturn.backward")
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .sheet(isPresented: $showsImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        pickedImage = image
        showsCropper = true
      }
    }
    .sheet(
      isPresented: $showsCropper,
      onDismiss: { pickedImage = nil },
      content: {
        if let pickedImage {
          CircularCropView(image: pickedImage) { croppedImage in
            accept(croppedImage)
          }
        }
      }
    )
    .sheet(isPresented: $showsXPicker) {
      OnboardingXPhotoPicker(initialPhoto: photo, lookupPhoto: lookupPhoto) { selectedPhoto in
        let savedPhoto = try await savePhoto(selectedPhoto)
        try Task.checkCancellation()
        photo = savedPhoto
        errorMessage = ""
      }
    }
    .onDisappear { resetTransientPresentation() }
  }

  private func accept(_ croppedImage: UIImage) {
    do {
      guard let data = croppedImage.jpegData(compressionQuality: 0.86) else {
        throw OnboardingProfilePhotoError.invalidImage
      }
      let selectedPhoto = try OnboardingProfilePhoto(data: data, fileFormat: .jpeg)
      photo = selectedPhoto
      errorMessage = ""
      upload(selectedPhoto)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func upload(_ selectedPhoto: OnboardingProfilePhoto) {
    uploadTask?.cancel()
    let id = UUID()
    uploadID = id
    isLoading = true
    uploadTask = Task { @MainActor in
      defer {
        if uploadID == id {
          uploadID = nil
          uploadTask = nil
          isLoading = false
        }
      }
      do {
        let savedPhoto = try await savePhoto(selectedPhoto)
        try Task.checkCancellation()
        guard uploadID == id else { return }
        photo = savedPhoto
        errorMessage = ""
      } catch is CancellationError {
        return
      } catch {
        guard uploadID == id else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func resetTransientPresentation() {
    uploadTask?.cancel()
    uploadTask = nil
    uploadID = nil
    showsPhotoSourceDialog = false
    showsImagePicker = false
    showsCropper = false
    showsXPicker = false
    pickedImage = nil
    isLoading = false
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

struct OnboardingXPhotoPicker: View {
  private enum LookupState {
    case idle
    case loading
    case found(OnboardingProfilePhoto)
    case failed(String)

    var photo: OnboardingProfilePhoto? {
      guard case let .found(photo) = self else { return nil }
      return photo
    }

    var isLoading: Bool {
      if case .loading = self { return true }
      return false
    }
  }

  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFocused: Bool
  @State private var handle: String
  @State private var state: LookupState
  @State private var requestID: UUID?
  @State private var isUploading = false
  @State private var uploadError: String?
  @State private var uploadTask: Task<Void, Never>?

  let cropToSquare: Bool
  let lookupPhoto: @MainActor (String) async throws -> Data
  let onUse: @MainActor (OnboardingProfilePhoto) async throws -> Void

  init(
    initialPhoto: OnboardingProfilePhoto?,
    cropToSquare: Bool = true,
    lookupPhoto: @escaping @MainActor (String) async throws -> Data,
    onUse: @escaping @MainActor (OnboardingProfilePhoto) async throws -> Void
  ) {
    let previous = initialPhoto.flatMap { $0.xHandle == nil ? nil : $0 }
    _handle = State(initialValue: previous?.xHandle ?? "")
    _state = State(initialValue: previous.map(LookupState.found) ?? .idle)
    self.cropToSquare = cropToSquare
    self.lookupPhoto = lookupPhoto
    self.onUse = onUse
  }

  var body: some View {
    NavigationStack {
      OnboardingFormPage(focus: $isFocused, autofocus: state.photo == nil) {
        Group {
          if let photo = state.photo {
            Image(uiImage: photo.image)
              .resizable()
              .scaledToFill()
          } else {
            Circle()
              .fill(Color(uiColor: .secondarySystemBackground))
              .overlay {
                Image(systemName: "person.crop.circle")
                  .font(.system(size: 44))
                  .foregroundStyle(.secondary)
              }
          }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
        .accessibilityLabel(state.photo == nil ? "No X photo selected" : "X profile photo preview")

        VStack(spacing: 8) {
          TextField("X username", text: $handle)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.search)
            .multilineTextAlignment(.center)
            .onboardingFormField()
            .focused($isFocused)
            .disabled(isUploading)
            .onSubmit(findPhoto)

          if let message = errorMessage {
            Text(message)
              .font(.callout)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 20)
          }
        }
      } actions: {
        Button {
          if let photo = state.photo {
            usePhoto(photo)
          } else {
            findPhoto()
          }
        } label: {
          HStack(spacing: 8) {
            if state.isLoading || isUploading { ProgressView().tint(.secondary) }
            Text(actionTitle)
          }
        }
        .buttonStyle(OnboardingFormButtonStyle())
        .disabled(state.isLoading || isUploading)
      }
      .navigationTitle("Photo from X")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
            .disabled(isUploading)
        }
      }
    }
    .interactiveDismissDisabled(isUploading)
    .onDisappear { uploadTask?.cancel() }
    .onChange(of: handle) { _, _ in
      requestID = nil
      state = .idle
      uploadError = nil
    }
    .task(id: handle) {
      guard normalizedHandle != nil else { return }
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      guard !Task.isCancelled, requestID == nil, state.photo == nil, !isUploading else { return }
      findPhoto()
    }
    .task(id: requestID) {
      guard let request = requestID, let username = normalizedHandle else { return }
      do {
        let data = try await lookupPhoto(username)
        let prepared = try await OnboardingProfilePhotoProcessor.prepare(data, cropToSquare: cropToSquare)
        try Task.checkCancellation()
        guard requestID == request, normalizedHandle == username else { return }
        state = .found(try OnboardingProfilePhoto(data: prepared, xHandle: username))
      } catch {
        guard !Task.isCancelled, requestID == request, normalizedHandle == username else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private var actionTitle: LocalizedStringKey {
    if isUploading { return "Saving Photo…" }
    if state.isLoading { return "Finding Photo…" }
    return state.photo == nil ? "Find Photo" : "Use Photo"
  }

  private var errorMessage: String? {
    if let uploadError { return uploadError }
    guard case let .failed(message) = state else { return nil }
    return message
  }

  private func usePhoto(_ photo: OnboardingProfilePhoto) {
    guard !isUploading else { return }
    isUploading = true
    uploadError = nil
    isFocused = false
    uploadTask = Task {
      defer { isUploading = false }
      do {
        try await onUse(photo)
        try Task.checkCancellation()
        dismiss()
      } catch {
        guard !Task.isCancelled else { return }
        uploadError = error.localizedDescription
      }
    }
  }

  private func findPhoto() {
    guard !state.isLoading, !isUploading else { return }
    guard normalizedHandle != nil else {
      state = .failed("Enter a valid X username using up to 15 letters, numbers, or underscores.")
      return
    }
    uploadError = nil
    state = .loading
    requestID = UUID()
  }

  private var normalizedHandle: String? {
    var candidate = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: candidate),
       let host = url.host?.lowercased(),
       ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host),
       let name = url.pathComponents.dropFirst().first {
      candidate = name
    }
    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    guard 1 ... 15 ~= candidate.utf8.count,
          candidate.utf8.allSatisfy({ byte in
            byte == 95 || (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
          }) else { return nil }
    return candidate
  }
}
