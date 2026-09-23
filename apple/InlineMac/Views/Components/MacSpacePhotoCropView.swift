import AppKit
import InlineUI
import SwiftUI

struct MacSpacePhotoCropView: View {
  let image: CGImage
  let isBusy: Bool
  let errorMessage: String?
  let onUse: (Data) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var zoom: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var cropError: String?
  @State private var isSaving = false
  @GestureState private var drag: CGSize = .zero
  @GestureState private var magnification: CGFloat = 1

  private let viewport: CGFloat = 280

  private var geometry: SpacePhotoCropGeometry {
    cropGeometry(zoom: zoom * magnification, offset: CGSize(
      width: offset.width + drag.width, height: offset.height + drag.height
    ))
  }

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text("Crop Space Photo").font(.headline)
        Text("Drag to reposition and zoom to adjust.")
          .foregroundStyle(.secondary)
      }

      Image(decorative: image, scale: 1)
        .resizable()
        .frame(width: geometry.displaySize.width, height: geometry.displaySize.height)
        .offset(geometry.offset)
        .frame(width: viewport, height: viewport)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: viewport / 3, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: viewport / 3, style: .continuous)
            .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
              offset = cropGeometry(zoom: zoom, offset: CGSize(
                width: offset.width + value.translation.width,
                height: offset.height + value.translation.height
              )).offset
            }
        )
        .simultaneousGesture(
          MagnificationGesture()
            .updating($magnification) { value, state, _ in state = value }
            .onEnded { value in
              zoom = min(max(zoom * value, 1), 4)
              offset = cropGeometry(zoom: zoom, offset: offset).offset
            }
        )
        .accessibilityLabel("Space photo crop preview")

      HStack(spacing: 12) {
        Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
        Slider(value: $zoom, in: 1 ... 4)
          .accessibilityLabel("Zoom")
        Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
      }
      .frame(width: viewport)
      .onChange(of: zoom) { _, value in offset = cropGeometry(zoom: value, offset: offset).offset }

      if let message = cropError ?? errorMessage {
        Text(message).foregroundStyle(.red).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button("Use Photo") { save() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 360)
    .disabled(isBusy || isSaving)
    .interactiveDismissDisabled(isBusy || isSaving)
  }

  private func cropGeometry(zoom: CGFloat, offset: CGSize) -> SpacePhotoCropGeometry {
    SpacePhotoCropGeometry(
      imageSize: CGSize(width: image.width, height: image.height),
      viewport: viewport, zoom: zoom, offset: offset
    )
  }

  private func save() {
    guard !isSaving, !isBusy else { return }
    do {
      let data = try SpacePhotoProcessor.crop(image, rect: geometry.sourceRect)
      cropError = nil
      isSaving = true
      Task {
        defer { isSaving = false }
        if await onUse(data) { dismiss() }
      }
    } catch {
      cropError = error.localizedDescription
    }
  }
}
