import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

struct IOSSpacePhotoPicker: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @Binding var photoData: Data?
  @Binding var isProcessing: Bool
  let space: Space
  let isBusy: Bool
  let size: CGFloat
  let savesImmediately: Bool

  @State private var showsPhotoOptions = false
  @State private var showsImagePicker = false
  @State private var showsXPicker = false
  @State private var showsCropper = false
  @State private var pickedImage: UIImage?
  @State private var isWorking = false
  @State private var errorMessage: String?

  init(
    photoData: Binding<Data?> = .constant(nil),
    space: Space,
    isBusy: Bool = false,
    isProcessing: Binding<Bool> = .constant(false),
    size: CGFloat = 64,
    savesImmediately: Bool = false
  ) {
    _photoData = photoData
    _isProcessing = isProcessing
    self.space = space
    self.isBusy = isBusy
    self.size = size
    self.savesImmediately = savesImmediately
  }

  var body: some View {
    Button {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      showsPhotoOptions = true
    } label: {
      ZStack {
        if let photoData, let image = UIImage(data: photoData) {
          Image(uiImage: image).resizable().scaledToFill()
        } else {
          SpaceAvatar(space: space, size: size)
        }
        if isWorking {
          Color.black.opacity(0.28)
          ProgressView().tint(.white)
        }
      }
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size / 3))
      .contentShape(RoundedRectangle(cornerRadius: size / 3))
    }
    .buttonStyle(.plain)
    .disabled(isBusy || isWorking)
    .accessibilityLabel(isWorking ? "Saving space photo" : "Edit space photo")
    .confirmationDialog("", isPresented: $showsPhotoOptions, titleVisibility: .hidden) {
      Button("Choose Photo…") { showsImagePicker = true }
      Button("From X…") { showsXPicker = true }
      if photoData != nil || space.photoFileUniqueId != nil {
        Button("Remove Photo", role: .destructive) {
          Task { await update(nil) }
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .sheet(isPresented: $showsImagePicker, onDismiss: {
      showsCropper = pickedImage != nil
    }, content: {
      ImagePicker(sourceType: .photoLibrary) { image in
        pickedImage = image
        showsImagePicker = false
      }
    })
    .sheet(isPresented: $showsCropper, onDismiss: { pickedImage = nil }, content: {
      if let pickedImage {
        CircularCropView(image: pickedImage, cornerRadiusRatio: 1 / 3) { image in
          guard let data = image.pngData() else {
            errorMessage = SpacePhotoProcessingError.invalidImage.localizedDescription
            return
          }
          Task { await update(data) }
        }
      }
    })
    .sheet(isPresented: $showsXPicker, onDismiss: {
      showsCropper = pickedImage != nil
    }, content: {
      OnboardingXPhotoPicker(initialPhoto: nil, cropToSquare: false, lookupPhoto: lookupXPhoto) { photo in
        pickedImage = photo.image
      }
    })
    .alert("Could Not Update Space Photo", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func update(_ data: Data?) async {
    do {
      try await use(data)
    } catch { errorMessage = error.localizedDescription }
  }

  private func use(_ data: Data?) async throws {
    guard !isBusy, !isWorking else { return }
    isWorking = true
    isProcessing = true
    defer {
      isWorking = false
      isProcessing = false
    }
    if savesImmediately {
      try await SpacePhotoUpdater.update(spaceID: space.id, photoData: data)
    } else {
      let prepared = try await Task.detached(priority: .userInitiated) {
        try data.map { try SpacePhotoProcessor.prepare($0) }
      }.value
      try Task.checkCancellation()
      photoData = prepared
    }
    errorMessage = nil
  }

  private func lookupXPhoto(_ username: String) async throws -> Data {
    let result = try await realtimeV2.getExternalProfilePhoto(provider: .x, username: username)
    switch result.status {
    case .externalProfilePhotoFound where !result.photo.isEmpty:
      return result.photo
    case .externalProfilePhotoNotFound:
      throw OnboardingProfilePhotoError.notFound
    case .externalProfilePhotoUnavailable:
      throw OnboardingProfilePhotoError.unavailable
    case .unspecified, .externalProfilePhotoFound, .UNRECOGNIZED:
      throw OnboardingProfilePhotoError.invalidImage
    }
  }
}
