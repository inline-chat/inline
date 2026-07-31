import Foundation
import MemojiKit
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
private enum MemojiPickerLayout {
  static let subjectColumns = Array(
    repeating: GridItem(.flexible(minimum: 60), spacing: 12),
    count: 5
  )
  static let poseColumns = Array(
    repeating: GridItem(.flexible(minimum: 72), spacing: 14),
    count: 4
  )
}

public struct MemojiPickerConfiguration: Sendable {
  public var title: String
  public var subtitle: String
  public var maximumPoseCount: Int
  public var preferredPoseIndex: Int
  public var outputDimension: Int
  public var backgrounds: [MemojiBackgroundStyle]
  public var emojiChoices: [String]

  public init(
    title: String = "Choose your profile Memoji",
    subtitle: String = "Choose a saved Memoji or character, pose, and background.",
    maximumPoseCount: Int = 20,
    preferredPoseIndex: Int = 1,
    outputDimension: Int = 512,
    backgrounds: [MemojiBackgroundStyle] = MemojiBackgroundStyle.presets,
    emojiChoices: [String] = Self.defaultEmojiChoices
  ) {
    self.title = title
    self.subtitle = subtitle
    self.maximumPoseCount = max(0, maximumPoseCount)
    self.preferredPoseIndex = max(0, preferredPoseIndex)
    self.outputDimension = max(1, outputDimension)
    self.backgrounds = backgrounds
    self.emojiChoices = emojiChoices
  }

  public static let defaultEmojiChoices = [
    "😀", "😃", "😄", "😁", "😆", "🥹", "😂", "🙂",
    "🙃", "😉", "😊", "🥰", "😍", "🤩", "😘", "😎",
    "🥳", "🤗", "🤭", "🫡", "🤔", "🫠", "😴", "😭",
    "😤", "😱", "🤯", "🥶", "🤠", "👻", "🤖", "👽",
    "🐶", "🐱", "🦊", "🐼", "🐨", "🐸", "🦖", "🦄",
    "🌈", "⭐️", "🔥", "💡", "🎉", "❤️", "👍", "👋",
  ]
}

/// A ready-made picker built on ``SystemMemojiLibrary``.
///
/// Set `selection` to receive an upload-ready PNG. For a custom interface, import
/// `MemojiKit` directly and use its headless library and renderer.
public struct MemojiPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Binding private var selection: MemojiPhoto?
  @State private var model = MemojiPickerModel()
  @State private var selectedSource: MemojiPickerSource? = .memoji
  @State private var section: MemojiPickerSection = .subject
  @State private var cropDragOrigin: CGSize?

  private let configuration: MemojiPickerConfiguration
  private let onFailure: (@MainActor (MemojiError) -> Void)?

  public init(
    selection: Binding<MemojiPhoto?>,
    configuration: MemojiPickerConfiguration = .init(),
    onFailure: (@MainActor (MemojiError) -> Void)? = nil
  ) {
    _selection = selection
    self.configuration = configuration
    self.onFailure = onFailure
  }

  public var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(spacing: 0) {
        toolbar
        Divider()
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        footer
      }
    }
    .memojiPickerFrame()
    .task {
      model.setFailureHandler(onFailure)
      await model.load(configuration: configuration)
    }
    .task(id: MemojiPickerRoute(source: source, section: section)) {
      await model.activate(section: section, source: source, configuration: configuration)
    }
    .onChange(of: selectedSource) { _, selectedSource in
      guard selectedSource != nil else {
        self.selectedSource = source
        return
      }
      section = .subject
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: $selectedSource) {
        Label("Memoji", systemImage: "person.crop.circle")
          .tag(MemojiPickerSource.memoji)
        Label("Emoji", systemImage: "face.smiling")
          .tag(MemojiPickerSource.emoji)
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)

      Divider()

      cropEditor
        .frame(width: 132)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    .frame(width: 184)
    .background {
      MemojiSidebarBackground()
    }
  }

  private var cropEditor: some View {
    VStack(spacing: 10) {
      GeometryReader { proxy in
        let side = min(proxy.size.width, proxy.size.height)
        ZStack {
          MemojiPlatformImage(
            data: model.basePreviewPNGData,
            cacheKey: model.basePreviewCacheKey
          )
          .frame(width: side, height: side)
          .scaleEffect(model.cropScale)
          .offset(
            x: model.cropOffset.width * side,
            y: model.cropOffset.height * side
          )

          if model.basePreviewPNGData == nil, model.isLoadingPoses {
            ProgressView()
              .controlSize(.small)
          }
        }
          .frame(width: side, height: side)
          .clipShape(Circle())
          .overlay {
            Circle().stroke(.primary.opacity(0.14), lineWidth: 1)
          }
          .contentShape(Circle())
          .gesture(cropGesture(previewSide: side))
          .accessibilityLabel("Profile photo crop preview")
          .accessibilityHint("Drag to reposition the photo")
      }
      .aspectRatio(1, contentMode: .fit)

      HStack(spacing: 6) {
        Image(systemName: "person.crop.circle")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { model.cropScale },
            set: { model.setCropScale($0, configuration: configuration) }
          ),
          in: 1 ... 2.5
        )
        .accessibilityLabel("Photo size")
        Image(systemName: "person.crop.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func cropGesture(previewSide: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if cropDragOrigin == nil {
          cropDragOrigin = model.cropOffset
        }
        guard let cropDragOrigin else { return }
        model.setCropOffset(
          CGSize(
            width: cropDragOrigin.width + value.translation.width / previewSide,
            height: cropDragOrigin.height + value.translation.height / previewSide
          ),
          configuration: configuration,
          rendersOutput: false
        )
      }
      .onEnded { _ in
        cropDragOrigin = nil
        model.commitCrop(configuration: configuration)
      }
  }

  private var toolbar: some View {
    HStack {
      Picker("", selection: $section) {
        ForEach(availableSections) { item in
          Label(item.title(for: source), systemImage: item.systemImage)
            .tag(item)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Editor section")
      .frame(maxWidth: source == .memoji ? 390 : 270)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var availableSections: [MemojiPickerSection] {
    switch source {
    case .memoji: [.subject, .pose, .style]
    case .emoji: [.subject, .style]
    }
  }

  private var source: MemojiPickerSource {
    selectedSource ?? .memoji
  }

  @ViewBuilder
  private var content: some View {
    if source == .emoji {
      if section == .style {
        styleContent
      } else {
        emojiGrid
      }
    } else {
      memojiContent
    }
  }

  @ViewBuilder
  private var memojiContent: some View {
    switch model.phase {
    case .loading:
      ProgressState(
        title: "Loading saved Memoji…",
        detail: "The system avatar library is preparing your Memoji."
      )
    case let .failed(message):
      ContentUnavailableView(
        "Memoji unavailable",
        systemImage: "person.crop.circle.badge.exclamationmark",
        description: Text(message)
      )
    case .loaded:
      switch section {
      case .subject:
        memojiGrid
      case .pose:
        poseContent
      case .style:
        styleContent
      }
    }
  }

  private var memojiGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: MemojiPickerLayout.subjectColumns,
        spacing: 16
      ) {
        ForEach(model.memoji) { item in
          memojiButton(item)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 16)
    }
  }

  private func memojiButton(_ memoji: Memoji) -> some View {
    let isSelected = model.selectedMemojiID == memoji.id
    return Button {
      Task {
        await model.selectMemoji(memoji, configuration: configuration)
      }
    } label: {
      MemojiPlatformImage(
        data: memoji.previewPNGData,
        cacheKey: "subject:\(memoji.id)",
        contentMode: .fit
      )
        .frame(width: 58, height: 58)
        .padding(5)
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(
            isSelected ? Color.accentColor : .clear,
            lineWidth: 3
          )
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Memoji")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var emojiGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: MemojiPickerLayout.subjectColumns,
        spacing: 16
      ) {
        ForEach(configuration.emojiChoices, id: \.self) { emoji in
          emojiButton(emoji)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 16)
    }
  }

  private func emojiButton(_ emoji: String) -> some View {
    let isSelected = model.selectedEmoji == emoji
    return Button {
      model.selectEmoji(emoji, configuration: configuration)
    } label: {
      Text(emoji)
        .font(.system(size: 32))
        .frame(width: 48, height: 48)
        .padding(5)
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(
            isSelected ? Color.accentColor : .clear,
            lineWidth: 3
          )
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Emoji \(emoji)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var poseContent: some View {
    if model.isLoadingPoses {
      ProgressState(
        title: "Rendering Apple Memoji poses…",
        detail: "Each pose is generated on this Mac."
      )
    } else if let error = model.poseError {
      ContentUnavailableView(
        "Pose editor unavailable",
        systemImage: "person.crop.circle.badge.exclamationmark",
        description: Text(error)
      )
    } else {
      ScrollView {
        LazyVGrid(
          columns: MemojiPickerLayout.poseColumns,
          spacing: 18
        ) {
          ForEach(model.poses) { pose in
            poseButton(pose)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
      }
    }
  }

  private func poseButton(_ pose: MemojiPose) -> some View {
    let isSelected = model.selectedPoseID == pose.id
    return Button {
      model.selectPose(pose, configuration: configuration)
    } label: {
      MemojiPlatformImage(
        data: pose.transparentPNGData,
        cacheKey: "pose:\(pose.id)",
        contentMode: .fit
      )
        .frame(width: 64, height: 64)
        .padding(6)
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(
            isSelected ? Color.accentColor : .clear,
            lineWidth: 3
          )
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(pose.name.replacingOccurrences(of: "_", with: " "))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var styleContent: some View {
    if model.isLoadingStyles {
      ProgressState(
        title: "Preparing backgrounds…",
        detail: "Rendering previews for the selected avatar."
      )
    } else if source == .memoji, model.selectedPose == nil {
      ContentUnavailableView(
        "Choose a pose first",
        systemImage: "person.crop.circle",
        description: Text("A pose is required before a background can be previewed.")
      )
    } else if source == .emoji, model.selectedEmoji == nil {
      ContentUnavailableView(
        "Choose an emoji first",
        systemImage: "face.smiling",
        description: Text("An emoji is required before a background can be previewed.")
      )
    } else {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 96, maximum: 112), spacing: 18)],
          spacing: 18
        ) {
          ForEach(configuration.backgrounds) { style in
            styleButton(style)
          }
        }
        .padding(26)
      }
    }
  }

  private func styleButton(_ style: MemojiBackgroundStyle) -> some View {
    let isSelected = model.selectedStyleID == style.id
    return Button {
      model.selectStyle(style, source: source, configuration: configuration)
    } label: {
      VStack(spacing: 7) {
        MemojiPlatformImage(
          data: model.stylePreviews[style.id],
          cacheKey: model.stylePreviewCacheKey(for: style.id, source: source)
        )
          .frame(width: 64, height: 64)
          .clipShape(Circle())
          .overlay {
            Circle().stroke(
              isSelected ? Color.accentColor : .primary.opacity(0.10),
              lineWidth: isSelected ? 4 : 1
            )
          }
          .overlay(alignment: .bottomTrailing) {
            if isSelected {
              Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Color.accentColor, in: Circle())
                .overlay { Circle().stroke(.white, lineWidth: 2) }
                .offset(x: 2, y: 2)
            }
          }
        Text(style.name)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(style.name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text(footerText)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button("Cancel", role: .cancel) {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)

      Button("Use Photo") {
        selection = model.previewPhoto
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(model.previewPhoto == nil)
    }
    .padding(16)
  }

  private var footerText: String {
    if source == .emoji {
      return section == .style
        ? "Choose a background."
        : "Choose an emoji, then adjust the crop preview."
    }

    switch section {
    case .subject:
      return model.memoji.isEmpty
        ? "Choose a Memoji to begin."
        : "\(model.memoji.count) characters available."
    case .pose:
      return model.poses.isEmpty
        ? "Choose a Memoji to see its poses."
        : "\(model.poses.count) poses available."
    case .style:
      return "Choose a background."
    }
  }
}

private enum MemojiPickerSource: Hashable, Identifiable {
  case memoji
  case emoji

  var id: Self { self }
}

private enum MemojiPickerSection: Hashable, Identifiable {
  case subject
  case pose
  case style

  var id: Self { self }

  func title(for source: MemojiPickerSource) -> String {
    switch self {
    case .subject: source == .memoji ? "Memoji" : "Emoji"
    case .pose: "Pose"
    case .style: "Style"
    }
  }

  var systemImage: String {
    switch self {
    case .subject: "person.crop.circle"
    case .pose: "person.crop.rectangle"
    case .style: "paintpalette"
    }
  }
}

private struct MemojiPickerRoute: Hashable {
  let source: MemojiPickerSource
  let section: MemojiPickerSection
}

@MainActor
@Observable
private final class MemojiPickerModel {
  private static let defaultArtworkScale = 0.86

  enum Phase: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  private(set) var phase: Phase = .loading
  private(set) var memoji: [Memoji] = []
  private(set) var poses: [MemojiPose] = []
  private(set) var previewPhoto: MemojiPhoto?
  private(set) var basePhoto: MemojiPhoto?
  private(set) var stylePreviews: [MemojiBackgroundStyle.ID: Data] = [:]
  private(set) var isLoadingPoses = false
  private(set) var isLoadingStyles = false
  private(set) var poseError: String?
  private(set) var selectedMemojiID: Memoji.ID?
  private(set) var selectedPoseID: MemojiPose.ID?
  private(set) var selectedStyleID: MemojiBackgroundStyle.ID?
  private(set) var selectedEmoji: String?
  private(set) var cropScale = 1.0
  private(set) var cropOffset = CGSize.zero

  private let library = SystemMemojiLibrary()
  private var poseRequestID = UUID()
  @ObservationIgnored private var activeSource = MemojiPickerSource.memoji
  @ObservationIgnored private var memojiBasePhoto: MemojiPhoto?
  @ObservationIgnored private var emojiBasePhoto: MemojiPhoto?
  @ObservationIgnored private var stylePreviewOwner: String?
  @ObservationIgnored private var fullyLoadedMemojiID: Memoji.ID?
  @ObservationIgnored private var failureHandler: (@MainActor (MemojiError) -> Void)?

  var selectedPose: MemojiPose? {
    poses.first { $0.id == selectedPoseID }
  }

  var basePreviewPNGData: Data? {
    basePhoto?.pngData
  }

  var basePreviewCacheKey: String? {
    basePhoto.map { "base:\($0.id)" }
  }

  func stylePreviewCacheKey(
    for styleID: MemojiBackgroundStyle.ID,
    source: MemojiPickerSource
  ) -> String {
    switch source {
    case .memoji:
      "style:memoji:\(selectedPoseID ?? "none"):\(styleID)"
    case .emoji:
      "style:emoji:\(selectedEmoji ?? "none"):\(styleID)"
    }
  }

  func setFailureHandler(_ handler: (@MainActor (MemojiError) -> Void)?) {
    failureHandler = handler
  }

  func load(configuration: MemojiPickerConfiguration) async {
    guard phase == .loading else { return }
    do {
      memoji = try library.loadSavedMemoji()
      phase = .loaded
      if let first = memoji.first {
        await selectMemoji(first, configuration: configuration)
      }
    } catch {
      let failure = normalizedFailure(error)
      phase = .failed(failure.localizedDescription)
      reportFailure(failure)
      return
    }

    do {
      let stock = try await library.loadStockAnimoji()
      let existingIDs = Set(memoji.map(\.id))
      memoji.append(contentsOf: stock.filter { existingIDs.contains($0.id) == false })
    } catch {
      if !Task.isCancelled {
        reportFailure(normalizedFailure(error))
      }
    }
  }

  func selectMemoji(
    _ item: Memoji,
    configuration: MemojiPickerConfiguration
  ) async {
    selectedMemojiID = item.id
    selectedPoseID = nil
    selectedStyleID = configuration.backgrounds.first?.id
    memojiBasePhoto = nil
    cropScale = 1
    cropOffset = .zero
    setBasePhoto(MemojiPhoto(memoji: item), resetsCrop: true, configuration: configuration)
    poses = []
    stylePreviews = [:]
    stylePreviewOwner = nil
    poseError = nil
    fullyLoadedMemojiID = nil
    isLoadingPoses = true
    let requestID = UUID()
    poseRequestID = requestID
    defer {
      if poseRequestID == requestID {
        isLoadingPoses = false
      }
    }

    do {
      let initialPoseCount = min(
        configuration.maximumPoseCount,
        configuration.preferredPoseIndex + 1
      )
      let loadedPoses = try await library.loadPoses(
        for: item,
        limit: initialPoseCount
      )
      guard
        activeSource == .memoji,
        selectedMemojiID == item.id,
        poseRequestID == requestID
      else { return }
      poses = loadedPoses
      let preferredPose = preferredPose(
        from: loadedPoses,
        preferredIndex: configuration.preferredPoseIndex
      )
      selectedPoseID = preferredPose?.id
      if item.kind != .stockAnimoji {
        if preferredPose == nil {
          setBasePhoto(MemojiPhoto(memoji: item), resetsCrop: true, configuration: configuration)
        } else {
          refreshPhoto(configuration: configuration)
        }
      }
    } catch {
      guard
        activeSource == .memoji,
        selectedMemojiID == item.id,
        poseRequestID == requestID
      else { return }
      let failure = normalizedFailure(error)
      poseError = failure.localizedDescription
      setBasePhoto(MemojiPhoto(memoji: item), resetsCrop: true, configuration: configuration)
      reportFailure(failure)
    }
  }

  func selectPose(_ pose: MemojiPose, configuration: MemojiPickerConfiguration) {
    selectedPoseID = pose.id
    stylePreviews = [:]
    stylePreviewOwner = nil
    refreshPhoto(configuration: configuration)
  }

  func selectStyle(
    _ style: MemojiBackgroundStyle,
    source: MemojiPickerSource,
    configuration: MemojiPickerConfiguration
  ) {
    selectedStyleID = style.id
    switch source {
    case .memoji:
      refreshPhoto(configuration: configuration)
    case .emoji:
      refreshEmojiPhoto(configuration: configuration)
    }
  }

  func selectEmoji(_ emoji: String, configuration: MemojiPickerConfiguration) {
    selectedEmoji = emoji
    if selectedStyleID == nil {
      selectedStyleID = configuration.backgrounds.first?.id
    }
    stylePreviews = [:]
    stylePreviewOwner = nil
    refreshEmojiPhoto(configuration: configuration, resetsCrop: true)
  }

  func activate(
    section: MemojiPickerSection,
    source: MemojiPickerSource,
    configuration: MemojiPickerConfiguration
  ) async {
    activeSource = source
    switch source {
    case .memoji:
      guard let item = memoji.first(where: { $0.id == selectedMemojiID }) ?? memoji.first else { return }
      if basePhoto?.memojiID != item.id,
         let memojiBasePhoto,
         memojiBasePhoto.memojiID == item.id {
        restoreBasePhoto(memojiBasePhoto, configuration: configuration)
      } else if selectedMemojiID == nil || basePhoto?.memojiID != item.id {
        await selectMemoji(item, configuration: configuration)
      }
      guard activeSource == .memoji else { return }
      switch section {
      case .subject:
        break
      case .pose:
        await loadAllPoses(for: item, configuration: configuration)
        if item.kind == .stockAnimoji, basePhoto?.poseID == nil {
          refreshPhoto(configuration: configuration)
        }
      case .style:
        if item.kind == .stockAnimoji, basePhoto?.poseID == nil {
          refreshPhoto(configuration: configuration)
        }
        await prepareStylePreviews(source: source, configuration: configuration)
      }
    case .emoji:
      guard let emoji = selectedEmoji ?? configuration.emojiChoices.first else { return }
      let expectedMemojiID = emojiMemojiID(emoji)
      if basePhoto?.memojiID != expectedMemojiID,
         let emojiBasePhoto,
         emojiBasePhoto.memojiID == expectedMemojiID {
        restoreBasePhoto(emojiBasePhoto, configuration: configuration)
      } else if selectedEmoji == nil || basePhoto?.memojiID != expectedMemojiID {
        selectEmoji(emoji, configuration: configuration)
      }
      if section == .style {
        await prepareStylePreviews(source: source, configuration: configuration)
      }
    }
  }

  func setCropScale(
    _ scale: Double,
    configuration: MemojiPickerConfiguration
  ) {
    cropScale = min(max(scale, 1), 2.5)
    cropOffset = clampedCropOffset(cropOffset)
    commitCrop(configuration: configuration)
  }

  func setCropOffset(
    _ offset: CGSize,
    configuration: MemojiPickerConfiguration,
    rendersOutput: Bool
  ) {
    cropOffset = clampedCropOffset(offset)
    if rendersOutput {
      commitCrop(configuration: configuration)
    }
  }

  func commitCrop(configuration: MemojiPickerConfiguration) {
    guard let basePhoto else {
      previewPhoto = nil
      return
    }
    do {
      if let style = configuration.backgrounds.first(where: { $0.id == selectedStyleID }),
         let selectedEmoji,
         basePhoto.memojiID.hasPrefix("emoji::") {
        previewPhoto = try EmojiProfilePhotoRenderer.render(
          emoji: selectedEmoji,
          background: style,
          outputDimension: configuration.outputDimension,
          artworkScale: cropScale,
          horizontalOffset: cropOffset.width,
          verticalOffset: cropOffset.height
        )
      } else if let style = configuration.backgrounds.first(where: { $0.id == selectedStyleID }),
                let selectedPose,
                basePhoto.poseID == selectedPose.id {
        previewPhoto = try MemojiRenderer.render(
          pose: selectedPose,
          background: style,
          outputDimension: configuration.outputDimension,
          artworkScale: Self.defaultArtworkScale * cropScale,
          horizontalOffset: cropOffset.width,
          verticalOffset: cropOffset.height
        )
      } else {
        previewPhoto = try MemojiPhotoRenderer.crop(
          basePhoto,
          scale: cropScale,
          horizontalOffset: cropOffset.width,
          verticalOffset: cropOffset.height,
          outputDimension: configuration.outputDimension
        )
      }
    } catch {
      previewPhoto = nil
      reportFailure(normalizedFailure(error))
    }
  }

  private func loadAllPoses(
    for item: Memoji,
    configuration: MemojiPickerConfiguration
  ) async {
    guard fullyLoadedMemojiID != item.id, configuration.maximumPoseCount > 0 else { return }
    isLoadingPoses = true
    let requestID = UUID()
    poseRequestID = requestID
    defer {
      if poseRequestID == requestID {
        isLoadingPoses = false
      }
    }

    do {
      let loadedPoses = try await library.loadPoses(
        for: item,
        limit: configuration.maximumPoseCount
      )
      guard selectedMemojiID == item.id, poseRequestID == requestID else { return }
      let currentPoseID = selectedPoseID
      poses = loadedPoses
      selectedPoseID = loadedPoses.contains(where: { $0.id == currentPoseID })
        ? currentPoseID
        : preferredPose(from: loadedPoses, preferredIndex: configuration.preferredPoseIndex)?.id
      fullyLoadedMemojiID = item.id
    } catch {
      guard selectedMemojiID == item.id, poseRequestID == requestID else { return }
      let failure = normalizedFailure(error)
      poseError = failure.localizedDescription
      reportFailure(failure)
    }
  }

  private func prepareStylePreviews(
    source: MemojiPickerSource,
    configuration: MemojiPickerConfiguration
  ) async {
    let owner = switch source {
    case .memoji: "memoji:\(selectedPoseID ?? "none")"
    case .emoji: "emoji:\(selectedEmoji ?? "none")"
    }
    guard stylePreviewOwner != owner else { return }
    stylePreviews = [:]
    isLoadingStyles = true
    defer { isLoadingStyles = false }
    await Task.yield()
    guard !Task.isCancelled else { return }

    switch source {
    case .memoji:
      guard let selectedPose else { return }
      stylePreviews = Dictionary(
        uniqueKeysWithValues: configuration.backgrounds.compactMap { style in
          guard let photo = try? MemojiRenderer.render(
            pose: selectedPose,
            background: style,
            outputDimension: 192,
            artworkScale: Self.defaultArtworkScale
          ) else { return nil }
          return (style.id, photo.pngData)
        }
      )
    case .emoji:
      guard let selectedEmoji else { return }
      stylePreviews = Dictionary(
        uniqueKeysWithValues: configuration.backgrounds.compactMap { style in
          guard let photo = try? EmojiProfilePhotoRenderer.render(
            emoji: selectedEmoji,
            background: style,
            outputDimension: 192
          ) else { return nil }
          return (style.id, photo.pngData)
        }
      )
    }
    stylePreviewOwner = owner
  }

  private func refreshPhoto(configuration: MemojiPickerConfiguration) {
    guard
      let selectedPose,
      let selectedStyle = configuration.backgrounds.first(where: { $0.id == selectedStyleID })
    else {
      previewPhoto = nil
      return
    }

    do {
      let photo = try MemojiRenderer.render(
        pose: selectedPose,
        background: selectedStyle,
        outputDimension: configuration.outputDimension,
        artworkScale: Self.defaultArtworkScale
      )
      setBasePhoto(photo, resetsCrop: false, configuration: configuration)
    } catch {
      previewPhoto = nil
      reportFailure(normalizedFailure(error))
    }
  }

  private func refreshEmojiPhoto(
    configuration: MemojiPickerConfiguration,
    resetsCrop: Bool = false
  ) {
    guard
      let selectedEmoji,
      let selectedStyle = configuration.backgrounds.first(where: { $0.id == selectedStyleID })
    else {
      basePhoto = nil
      previewPhoto = nil
      stylePreviews = [:]
      return
    }

    do {
      let photo = try EmojiProfilePhotoRenderer.render(
        emoji: selectedEmoji,
        background: selectedStyle,
        outputDimension: configuration.outputDimension
      )
      setBasePhoto(photo, resetsCrop: resetsCrop, configuration: configuration)
    } catch {
      basePhoto = nil
      previewPhoto = nil
      reportFailure(normalizedFailure(error))
    }
  }

  private func setBasePhoto(
    _ photo: MemojiPhoto,
    resetsCrop: Bool,
    configuration: MemojiPickerConfiguration
  ) {
    basePhoto = photo
    if photo.memojiID.hasPrefix("emoji::") {
      emojiBasePhoto = photo
    } else {
      memojiBasePhoto = photo
    }
    if resetsCrop {
      cropScale = 1
      cropOffset = .zero
    }
    commitCrop(configuration: configuration)
  }

  private func restoreBasePhoto(
    _ photo: MemojiPhoto,
    configuration: MemojiPickerConfiguration
  ) {
    basePhoto = photo
    cropScale = 1
    cropOffset = .zero
    stylePreviews = [:]
    stylePreviewOwner = nil
    commitCrop(configuration: configuration)
  }

  private func clampedCropOffset(_ offset: CGSize) -> CGSize {
    let maximum = CGFloat(max(0, (cropScale - 1) / 2))
    return CGSize(
      width: min(max(offset.width, -maximum), maximum),
      height: min(max(offset.height, -maximum), maximum)
    )
  }

  private func preferredPose(
    from poses: [MemojiPose],
    preferredIndex: Int
  ) -> MemojiPose? {
    guard poses.isEmpty == false else { return nil }
    return poses[min(preferredIndex, poses.count - 1)]
  }

  private func emojiMemojiID(_ emoji: String) -> String {
    let scalarID = emoji.unicodeScalars
      .map { String(format: "%04X", $0.value) }
      .joined(separator: "-")
    return "emoji::\(scalarID)"
  }

  private func reportFailure(_ failure: MemojiError) {
    failureHandler?(failure)
  }

  private func normalizedFailure(_ error: Error) -> MemojiError {
    error as? MemojiError ?? .unexpectedFailure
  }
}

private struct ProgressState: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(title)
        .foregroundStyle(.secondary)
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.tertiary)
    }
    .multilineTextAlignment(.center)
  }
}

private struct MemojiPlatformImage: View {
  enum ContentMode {
    case fill
    case fit
  }

  let data: Data?
  let cacheKey: String?
  var contentMode: ContentMode = .fill

  var body: some View {
    Group {
      #if os(macOS)
      if let data, let image = MemojiPlatformImageCache.image(data: data, key: cacheKey) {
        FadingPlatformImage(
          image: Image(nsImage: image),
          contentMode: contentMode
        )
        .id(cacheKey)
      } else {
        placeholder
      }
      #elseif os(iOS)
      if let data, let image = MemojiPlatformImageCache.image(data: data, key: cacheKey) {
        FadingPlatformImage(
          image: Image(uiImage: image),
          contentMode: contentMode
        )
        .id(cacheKey)
      } else {
        placeholder
      }
      #else
      placeholder
      #endif
    }
  }

  private var placeholder: some View {
    Color.clear
      .overlay {
        Image(systemName: "person.crop.circle")
          .foregroundStyle(.tertiary)
      }
  }
}

private struct FadingPlatformImage: View {
  @State private var isVisible = false

  let image: Image
  let contentMode: MemojiPlatformImage.ContentMode

  var body: some View {
    renderedImage
      .opacity(isVisible ? 1 : 0)
      .onAppear {
        withAnimation(.easeOut(duration: 0.16)) {
          isVisible = true
        }
      }
  }

  @ViewBuilder
  private var renderedImage: some View {
    switch contentMode {
    case .fill:
      image.resizable().scaledToFill()
    case .fit:
      image.resizable().scaledToFit()
    }
  }
}

private struct MemojiSidebarBackground: View {
  var body: some View {
    #if os(macOS)
    MemojiSidebarVisualEffect()
      .ignoresSafeArea()
    #else
    Color(uiColor: .secondarySystemBackground)
      .ignoresSafeArea()
    #endif
  }
}

#if os(macOS)
private struct MemojiSidebarVisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#endif

@MainActor
private enum MemojiPlatformImageCache {
  #if os(macOS)
  private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 160
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()

  static func image(data: Data, key: String?) -> NSImage? {
    guard let key else { return NSImage(data: data) }
    let cacheKey = key as NSString
    if let cached = images.object(forKey: cacheKey) { return cached }
    guard let image = NSImage(data: data) else { return nil }
    images.setObject(image, forKey: cacheKey, cost: data.count)
    return image
  }
  #elseif os(iOS)
  private static let images: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 160
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()

  static func image(data: Data, key: String?) -> UIImage? {
    guard let key else { return UIImage(data: data) }
    let cacheKey = key as NSString
    if let cached = images.object(forKey: cacheKey) { return cached }
    guard let image = UIImage(data: data) else { return nil }
    images.setObject(image, forKey: cacheKey, cost: data.count)
    return image
  }
  #endif
}

private extension View {
  @ViewBuilder
  func memojiPickerFrame() -> some View {
    #if os(macOS)
    frame(width: 660, height: 500)
    #else
    frame(maxWidth: .infinity, maxHeight: .infinity)
    #endif
  }
}

private extension Color {
  init(_ color: MemojiRGBAColor) {
    self.init(
      red: color.red,
      green: color.green,
      blue: color.blue,
      opacity: color.alpha
    )
  }
}
