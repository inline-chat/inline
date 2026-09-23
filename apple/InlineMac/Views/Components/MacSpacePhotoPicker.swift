import AppKit
import InlineKit
import InlineUI
import SwiftUI

struct MacSpacePhotoPicker: View {
  @Binding var photoData: Data?
  @Binding var isProcessing: Bool
  let space: Space
  let isBusy: Bool
  let size: CGFloat
  let savesImmediately: Bool

  @State private var cropImage: CGImage?
  @State private var showsCropper = false
  @State private var showsPhotoSource = false
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
    EditableProfileAvatar(
      cornerRadius: size / 3,
      photoLabel: "Space photo",
      photoErrorMessage: errorMessage,
      onPhotoSourcePresentationChanged: { presented in
        showsPhotoSource = presented
        if !presented { showsCropper = cropImage != nil }
      },
      size: size,
      hasPhoto: photoData != nil || space.photoFileUniqueId != nil,
      showsMemoji: MemojiBetaRollout.isEnabled(dependencies: nil),
      isBusy: isBusy || isWorking,
      onPickFile: { url in
        Task {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 10 * 1_024 * 1_024 else {
              throw SpacePhotoProcessingError.invalidImage
            }
            _ = await select(try Data(contentsOf: url))
          } catch { errorMessage = error.localizedDescription }
        }
      },
      onFilePickerFailure: { errorMessage = $0.localizedDescription },
      onUsePhotoData: { await select($0) },
      onMemojiFailure: { errorMessage = $0.localizedDescription },
      onRemove: { Task { _ = await use(nil) } },
      avatar: { size in
        if let photoData, let image = NSImage(data: photoData) {
          Image(nsImage: image).resizable().scaledToFill()
        } else {
          SpaceAvatar(space: space, size: size)
        }
      }
    )
    .sheet(isPresented: $showsCropper, onDismiss: { cropImage = nil }, content: {
      if let cropImage {
        MacSpacePhotoCropView(image: cropImage, isBusy: isWorking, errorMessage: errorMessage) { data in
          await use(data)
        }
      }
    })
    .alert("Could Not Update Space Photo", isPresented: Binding(
      get: { errorMessage != nil && !showsCropper && !showsPhotoSource },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func select(_ data: Data) async -> Bool {
    guard !isBusy, !isWorking else { return false }
    isWorking = true
    isProcessing = true
    defer {
      isWorking = false
      isProcessing = false
    }
    do {
      let image = try await Task.detached(priority: .userInitiated) {
        try SpacePhotoProcessor.imageForCropping(data)
      }.value
      try Task.checkCancellation()
      cropImage = image
      errorMessage = nil
      showsCropper = !showsPhotoSource
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func use(_ data: Data?) async -> Bool {
    guard !isBusy, !isWorking else { return false }
    isWorking = true
    isProcessing = true
    errorMessage = nil
    defer {
      isWorking = false
      isProcessing = false
    }
    do {
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
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
