import CoreGraphics
import CoreText
import Foundation
import ObjectiveC.runtime

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Headless runtime access to saved Memoji, stock Animoji, and Apple-rendered poses.
///
/// Private frameworks are loaded dynamically. Undocumented Objective-C objects never cross
/// this API boundary, and every class and selector is capability-checked before use.
@MainActor
public struct SystemMemojiLibrary {
  public let domainIdentifier: String

  public init(domainIdentifier: String = Bundle.main.bundleIdentifier ?? "MemojiKit") {
    self.domainIdentifier = domainIdentifier
  }

  public static var availability: MemojiRuntimeAvailability {
    do {
      try MemojiRuntime.loadFrameworks()
      try MemojiRuntime.validateSavedMemojiContract()
      try MemojiRuntime.validatePoseContract()
      return .init(
        isAvailable: true,
        detail: "Apple's saved Memoji and pose renderer contracts are present."
      )
    } catch {
      return .init(isAvailable: false, detail: error.localizedDescription)
    }
  }

  public func loadMemoji() throws -> [Memoji] {
    try MemojiRuntime.loadMemoji(domainIdentifier: domainIdentifier)
  }

  public func loadSavedMemoji() throws -> [Memoji] {
    try MemojiRuntime.loadMemoji(
      domainIdentifier: domainIdentifier,
      includesStockAnimoji: false
    )
  }

  public func loadStockAnimoji(
    onLoad: (@MainActor (Memoji) -> Void)? = nil
  ) async throws -> [Memoji] {
    try await MemojiRuntime.loadStockAnimoji(onLoad: onLoad)
  }

  public func loadPoses(
    for memoji: Memoji,
    limit: Int? = nil
  ) async throws -> [MemojiPose] {
    await Task.yield()
    return try MemojiRuntime.loadPoses(
      memojiID: memoji.id,
      maximumCount: limit,
      domainIdentifier: domainIdentifier
    )
  }
}

public enum MemojiRenderer {
  public static func render(
    pose: MemojiPose,
    background: MemojiBackgroundStyle,
    outputDimension: Int = 512,
    artworkScale: Double = 1,
    horizontalOffset: Double = 0,
    verticalOffset: Double = 0
  ) throws -> MemojiPhoto {
    guard outputDimension > 0, artworkScale > 0 else {
      throw MemojiError.renderingFailed(pose.name)
    }

    #if os(macOS)
    guard
      let image = NSImage(data: pose.transparentPNGData),
      let source = MemojiRuntime.cgImage(from: image),
      let pngData = MemojiRuntime.compositedPNGData(
        source: source,
        background: background,
        outputDimension: outputDimension,
        artworkScale: artworkScale,
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset
      )
    else {
      throw MemojiError.renderingFailed(pose.name)
    }
    #elseif os(iOS)
    guard
      let source = UIImage(data: pose.transparentPNGData)?.cgImage,
      let pngData = MemojiRuntime.compositedPNGData(
        source: source,
        background: background,
        outputDimension: outputDimension,
        artworkScale: artworkScale,
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset
      )
    else {
      throw MemojiError.renderingFailed(pose.name)
    }
    #else
    throw MemojiError.unsupportedPlatform
    #endif

    return MemojiPhoto(
      id: "\(pose.id)::\(background.id)",
      memojiID: pose.memojiID,
      poseID: pose.id,
      backgroundID: background.id,
      pngData: pngData,
      metadata: pose.metadata
    )
  }
}

/// Public, private-API-free output transforms shared by the default UI and custom clients.
public enum MemojiPhotoRenderer {
  /// Bakes a native-picker-style zoom and pan into a square PNG.
  ///
  /// Offsets are expressed as fractions of the output side. Positive horizontal values move
  /// the artwork right; positive vertical values move it down. Values are clamped so the crop
  /// never exposes an empty edge.
  public static func crop(
    _ photo: MemojiPhoto,
    scale: Double,
    horizontalOffset: Double,
    verticalOffset: Double,
    outputDimension: Int
  ) throws -> MemojiPhoto {
    guard scale >= 1, outputDimension > 0 else {
      throw MemojiError.renderingFailed("profile crop")
    }

    #if os(macOS)
    guard
      let image = NSImage(data: photo.pngData),
      let source = MemojiRuntime.cgImage(from: image),
      let pngData = MemojiRuntime.transformedPNGData(
        source: source,
        scale: scale,
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset,
        outputDimension: outputDimension
      )
    else {
      throw MemojiError.renderingFailed("profile crop")
    }
    #elseif os(iOS)
    guard
      let source = UIImage(data: photo.pngData)?.cgImage,
      let pngData = MemojiRuntime.transformedPNGData(
        source: source,
        scale: scale,
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset,
        outputDimension: outputDimension
      )
    else {
      throw MemojiError.renderingFailed("profile crop")
    }
    #else
    throw MemojiError.unsupportedPlatform
    #endif

    return MemojiPhoto(
      id: photo.id,
      memojiID: photo.memojiID,
      poseID: photo.poseID,
      backgroundID: photo.backgroundID,
      pngData: pngData,
      metadata: photo.metadata
    )
  }
}

/// Public rendering for the Emoji source in the default picker.
public enum EmojiProfilePhotoRenderer {
  public static func render(
    emoji: String,
    background: MemojiBackgroundStyle = MemojiBackgroundStyle.presets[0],
    outputDimension: Int = 512,
    artworkScale: Double = 1,
    horizontalOffset: Double = 0,
    verticalOffset: Double = 0
  ) throws -> MemojiPhoto {
    guard
      let emoji = emoji.first.map(String.init),
      outputDimension > 0,
      let pngData = MemojiRuntime.emojiPNGData(
        emoji: emoji,
        background: background,
        outputDimension: outputDimension,
        artworkScale: artworkScale,
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset
      )
    else {
      throw MemojiError.renderingFailed("emoji")
    }

    let scalarID = emoji.unicodeScalars
      .map { String(format: "%04X", $0.value) }
      .joined(separator: "-")
    return MemojiPhoto(
      id: "emoji::\(scalarID)::\(background.id)",
      memojiID: "emoji::\(scalarID)",
      poseID: nil,
      backgroundID: background.id,
      pngData: pngData
    )
  }
}

private enum MemojiRuntime {
  typealias RecordAtIndex = @convention(c) (
    AnyObject,
    Selector,
    UInt
  ) -> Unmanaged<AnyObject>?

  typealias RenderSnapshot = @convention(c) (
    AnyObject,
    Selector,
    CGSize,
    CGFloat,
    NSDictionary?
  ) -> Unmanaged<AnyObject>?

  typealias OneObjectInitializer = @convention(c) (
    AnyObject,
    Selector,
    AnyObject
  ) -> Unmanaged<AnyObject>

  typealias OneObjectVoidMethod = @convention(c) (
    AnyObject,
    Selector,
    AnyObject?
  ) -> Void

  typealias BoolSetter = @convention(c) (
    AnyObject,
    Selector,
    Bool
  ) -> Void

  typealias TwoObjectVoidMethod = @convention(c) (
    AnyObject,
    Selector,
    AnyObject,
    AnyObject
  ) -> Void

  typealias ThreeObjectClassMethod = @convention(c) (
    AnyClass,
    Selector,
    AnyObject?,
    AnyObject?,
    AnyObject?
  ) -> Unmanaged<AnyObject>?

  typealias ImageCompletion = @convention(block) (AnyObject?) -> Void

  @MainActor
  private final class RenderSession {
    let retainedObjects: [AnyObject]
    var completions: [ImageCompletion] = []

    init(retainedObjects: [AnyObject]) {
      self.retainedObjects = retainedObjects
    }
  }

  @MainActor
  private struct PreviewRenderer {
    let renderingType: NSObject.Type
    let snapshotBuilder: NSObject
    let renderSnapshot: RenderSnapshot
    let setAvatar: OneObjectVoidMethod
    let renderSelector = NSSelectorFromString("imageWithSize:scale:options:")
    let setAvatarSelector = NSSelectorFromString("setAvatar:")

    func render(
      record: NSObject,
      identifier: String,
      kind: MemojiKind,
      avatarSelectorName: String
    ) -> Memoji? {
      autoreleasepool {
        guard
          let avatar = try? MemojiRuntime.avatar(
            for: record,
            renderingType: renderingType,
            selectorName: avatarSelectorName
          )
        else { return nil }

        setAvatar(snapshotBuilder, setAvatarSelector, avatar)
        guard
          let rendered = renderSnapshot(
            snapshotBuilder,
            renderSelector,
            CGSize(width: 256, height: 256),
            2,
            nil
          )?.takeUnretainedValue(),
          let pngData = MemojiRuntime.transparentPNGData(from: rendered)
        else { return nil }

        return Memoji(id: identifier, previewPNGData: pngData, kind: kind)
      }
    }

    func clear() {
      setAvatar(snapshotBuilder, setAvatarSelector, nil)
    }
  }

  @MainActor
  private static var retainedSessions: [RenderSession] = []

  @MainActor
  private static var poseCache: [String: [MemojiPose]] = [:]

  @MainActor
  private static var poseCacheOrder: [String] = []

  @MainActor
  private static var stockMemojiCache: [Memoji]?

  @MainActor
  private static var memojiCache: [String: [Memoji]] = [:]

  @MainActor
  private static var loadedFrameworkPaths: Set<String> = []

  private static let retainedSessionLimit = 12
  private static let poseCacheLimit = 24

  private static let dataSourceClassName = "AVTPAvatarRecordDataSource"
  private static let puppetStoreClassName = "AVTPuppetStore"
  private static let renderingClassName = "AVTAvatarRecordRendering"
  private static let snapshotClassName = "AVTSnapshotBuilder"
  private static let configurationClassName = "AVTStickerConfiguration"
  private static let generatorClassName = "AVTStickerGenerator"
  private static let metadataUtilitiesClassName = "CNMemojiMetadataUtilities"
  private static let backgroundParametersClassName = "CNMemojiBackgroundParameters"
  private static let stockMemojiIDPrefix = "stock::"

  private enum MethodDispatch: Sendable {
    case classMethod
    case instanceMethod
  }

  private struct MethodRequirement: Sendable {
    let className: String
    let selectorName: String
    let dispatch: MethodDispatch
    let contract: MemojiObjectiveCMethodContract
  }

  private static var frameworkPaths: [(name: String, path: String)] {
    #if os(macOS) || os(iOS)
    [
      ("ContactsUI", "/System/Library/Frameworks/ContactsUI.framework"),
      ("AvatarPersistence", "/System/Library/PrivateFrameworks/AvatarPersistence.framework"),
      ("AvatarKit", "/System/Library/PrivateFrameworks/AvatarKit.framework"),
    ]
    #else
    []
    #endif
  }

  @MainActor
  static func loadFrameworks() throws {
    guard !frameworkPaths.isEmpty else {
      throw MemojiError.unsupportedPlatform
    }

    for framework in frameworkPaths {
      guard !loadedFrameworkPaths.contains(framework.path) else { continue }
      guard let bundle = Bundle(path: framework.path), bundle.isLoaded || bundle.load() else {
        throw MemojiError.frameworkUnavailable(framework.name)
      }
      loadedFrameworkPaths.insert(framework.path)
    }
  }

  static func validateSavedMemojiContract() throws {
    try validate([
      requirement(
        dataSourceClassName,
        "defaultUIDataSourceWithDomainIdentifier:",
        .classMethod,
        .object,
        [.object]
      ),
      requirement(dataSourceClassName, "indexSetForEditableRecords", .instanceMethod, .object),
      requirement(dataSourceClassName, "recordAtIndex:", .instanceMethod, .object, [.unsignedInteger]),
      requirement(renderingClassName, "memojiForRecord:", .classMethod, .object, [.object]),
      requirement(snapshotClassName, "sharedInstance", .classMethod, .object),
      requirement(snapshotClassName, "setAvatar:", .instanceMethod, .void, [.object]),
      requirement(
        snapshotClassName,
        "imageWithSize:scale:options:",
        .instanceMethod,
        .object,
        [.size, .cgFloat, .object]
      ),
    ])
  }

  static func validatePoseContract() throws {
    try validate([
      requirement(configurationClassName, "stickerConfigurationsForMemoji", .classMethod, .object),
      requirement(generatorClassName, "initWithAvatar:", .instanceMethod, .object, [.object]),
      requirement(generatorClassName, "setAsync:", .instanceMethod, .void, [.bool]),
      requirement(
        generatorClassName,
        "stickerImageWithConfiguration:completionHandler:",
        .instanceMethod,
        .void,
        [.object, .object]
      ),
    ])
  }

  private static func requirement(
    _ className: String,
    _ selectorName: String,
    _ dispatch: MethodDispatch,
    _ returnValue: MemojiObjectiveCValueKind,
    _ arguments: [MemojiObjectiveCValueKind] = []
  ) -> MethodRequirement {
    MethodRequirement(
      className: className,
      selectorName: selectorName,
      dispatch: dispatch,
      contract: .init(returnValue: returnValue, arguments: arguments)
    )
  }

  private static func validate(_ requirements: [MethodRequirement]) throws {
    for requirement in requirements {
      guard let type = NSClassFromString(requirement.className) else {
        throw MemojiError.runtimeContractChanged(requirement.className)
      }
      _ = try validatedMethod(
        on: type,
        selectorName: requirement.selectorName,
        dispatch: requirement.dispatch,
        contract: requirement.contract
      )
    }
  }

  private static func validatedMethod(
    on type: AnyClass,
    selectorName: String,
    dispatch: MethodDispatch,
    contract: MemojiObjectiveCMethodContract
  ) throws -> Method {
    let selector = NSSelectorFromString(selectorName)
    let method = switch dispatch {
    case .classMethod:
      class_getClassMethod(type, selector)
    case .instanceMethod:
      class_getInstanceMethod(type, selector)
    }
    guard let method, contract.matches(method) else {
      throw MemojiError.runtimeContractChanged(selectorName)
    }
    return method
  }

  @MainActor
  private static func makePreviewRenderer() throws -> PreviewRenderer {
    guard
      let renderingType = NSClassFromString(renderingClassName) as? NSObject.Type,
      let snapshotType = NSClassFromString(snapshotClassName) as? NSObject.Type,
      let snapshotBuilder = snapshotType.perform(
        NSSelectorFromString("sharedInstance")
      )?.takeUnretainedValue() as? NSObject
    else {
      throw MemojiError.runtimeContractChanged("saved-record data source")
    }

    let renderMethod = try validatedMethod(
      on: type(of: snapshotBuilder),
      selectorName: "imageWithSize:scale:options:",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .object, arguments: [.size, .cgFloat, .object])
    )
    let setAvatarMethod = try validatedMethod(
      on: type(of: snapshotBuilder),
      selectorName: "setAvatar:",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .void, arguments: [.object])
    )

    return PreviewRenderer(
      renderingType: renderingType,
      snapshotBuilder: snapshotBuilder,
      renderSnapshot: unsafeBitCast(
        method_getImplementation(renderMethod),
        to: RenderSnapshot.self
      ),
      setAvatar: unsafeBitCast(
        method_getImplementation(setAvatarMethod),
        to: OneObjectVoidMethod.self
      )
    )
  }

  @MainActor
  static func loadStockAnimoji(
    onLoad: (@MainActor (Memoji) -> Void)?
  ) async throws -> [Memoji] {
    if let cached = stockMemojiCache {
      for item in cached {
        onLoad?(item)
      }
      return cached
    }

    try loadFrameworks()
    try validateSavedMemojiContract()
    let previewRenderer = try makePreviewRenderer()
    defer { previewRenderer.clear() }

    var stock: [Memoji] = []
    for record in try stockRecords() {
      try Task.checkCancellation()
      guard
        let name = stringValue(record, selectorName: "puppetName"),
        let item = previewRenderer.render(
          record: record,
          identifier: stockMemojiIDPrefix + name,
          kind: .stockAnimoji,
          avatarSelectorName: "avatarForRecord:"
        )
      else { continue }
      stock.append(item)
      onLoad?(item)
      await Task.yield()
    }

    stockMemojiCache = stock
    return stock
  }

  @MainActor
  static func loadMemoji(
    domainIdentifier: String,
    includesStockAnimoji: Bool = true
  ) throws -> [Memoji] {
    let cacheKey = "\(domainIdentifier)::\(includesStockAnimoji ? "all" : "saved")"
    if let cached = memojiCache[cacheKey] {
      return cached
    }
    try loadFrameworks()
    try validateSavedMemojiContract()

    let dataSource = try makeDataSource(domainIdentifier: domainIdentifier)
    let indexes = try editableIndexes(dataSource: dataSource)
    let previewRenderer = try makePreviewRenderer()

    let recordAtIndex = try recordReader(dataSource: dataSource)
    let recordSelector = NSSelectorFromString("recordAtIndex:")

    var memoji: [Memoji] = []
    for index in indexes {
      guard let record = recordAtIndex(
        dataSource,
        recordSelector,
        UInt(index)
      )?.takeUnretainedValue() as? NSObject else { continue }
      let identifier = stringValue(record, selectorName: "identifier") ?? "record-\(index)"
      if let preview = previewRenderer.render(
        record: record,
        identifier: identifier,
        kind: .saved,
        avatarSelectorName: "memojiForRecord:"
      ) {
        memoji.append(preview)
      }
    }

    if includesStockAnimoji {
      if let cached = stockMemojiCache {
        memoji.append(contentsOf: cached)
      } else if let records = try? stockRecords() {
        let stock = records.compactMap { record -> Memoji? in
          guard let name = stringValue(record, selectorName: "puppetName") else { return nil }
          return previewRenderer.render(
            record: record,
            identifier: stockMemojiIDPrefix + name,
            kind: .stockAnimoji,
            avatarSelectorName: "avatarForRecord:"
          )
        }
        if stock.isEmpty == false {
          stockMemojiCache = stock
          memoji.append(contentsOf: stock)
        }
      }
    }
    previewRenderer.clear()

    guard !memoji.isEmpty else {
      if indexes.isEmpty {
        throw MemojiError.noSavedMemoji
      }
      throw MemojiError.noRenderableMemoji(savedRecordCount: indexes.count)
    }
    memojiCache[cacheKey] = memoji
    return memoji
  }

  @MainActor
  static func loadPoses(
    memojiID: String,
    maximumCount: Int?,
    domainIdentifier: String
  ) throws -> [MemojiPose] {
    try loadFrameworks()
    try validateSavedMemojiContract()
    try validatePoseContract()

    if let maximumCount, maximumCount <= 0 {
      return []
    }
    let requestedCount = maximumCount.map(String.init) ?? "all"
    let cacheKey = "\(domainIdentifier)::\(memojiID)::\(requestedCount)"
    if let cached = poseCache[cacheKey] {
      return cached
    }

    let resolvedRecord = try avatarRecord(
      identifier: memojiID,
      domainIdentifier: domainIdentifier
    )
    guard
      let renderingType = NSClassFromString(renderingClassName) as? NSObject.Type,
      let configurationType = NSClassFromString(configurationClassName) as? NSObject.Type,
      let allConfigurations = configurationType.perform(
        NSSelectorFromString("stickerConfigurationsForMemoji")
      )?.takeUnretainedValue() as? [NSObject],
      !allConfigurations.isEmpty,
      let generatorType = NSClassFromString(generatorClassName) as? NSObject.Type,
      let allocated = class_createInstance(generatorType, 0) as AnyObject?
    else {
      throw MemojiError.noPoses
    }
    let record = resolvedRecord.record
    let avatar = try avatar(
      for: record,
      renderingType: renderingType,
      selectorName: resolvedRecord.avatarSelectorName
    )

    let initializerMethod = try validatedMethod(
      on: generatorType,
      selectorName: "initWithAvatar:",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .object, arguments: [.object])
    )
    let asyncMethod = try validatedMethod(
      on: generatorType,
      selectorName: "setAsync:",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .void, arguments: [.bool])
    )
    let renderMethod = try validatedMethod(
      on: generatorType,
      selectorName: "stickerImageWithConfiguration:completionHandler:",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .void, arguments: [.object, .object])
    )

    let initializedGenerator = unsafeBitCast(
      method_getImplementation(initializerMethod),
      to: OneObjectInitializer.self
    )(
      allocated,
      NSSelectorFromString("initWithAvatar:"),
      avatar
    ).takeRetainedValue()
    guard let generator = initializedGenerator as? NSObject else {
      throw MemojiError.runtimeContractChanged("AVTStickerGenerator.initWithAvatar:")
    }

    let asyncSelector = NSSelectorFromString("setAsync:")
    unsafeBitCast(
      method_getImplementation(asyncMethod),
      to: BoolSetter.self
    )(generator, asyncSelector, false)

    let configurations = if let maximumCount {
      Array(allConfigurations.prefix(maximumCount))
    } else {
      allConfigurations
    }
    let session = RenderSession(retainedObjects: [record, avatar, generator] + configurations)
    let render = unsafeBitCast(
      method_getImplementation(renderMethod),
      to: TwoObjectVoidMethod.self
    )

    var poses: [MemojiPose] = []
    for (index, configuration) in configurations.enumerated() {
      let name = stringValue(configuration, selectorName: "name") ?? "pose-\(index + 1)"
      var renderedValue: AnyObject?
      let completion: ImageCompletion = { value in
        renderedValue = value
      }
      session.completions.append(completion)
      render(
        generator,
        NSSelectorFromString("stickerImageWithConfiguration:completionHandler:"),
        configuration,
        completion as AnyObject
      )

      guard
        let renderedValue,
        let transparentPNGData = transparentPNGData(from: renderedValue)
      else { continue }

      poses.append(
        MemojiPose(
          id: "\(memojiID)::\(name)::\(index)",
          memojiID: memojiID,
          name: name,
          transparentPNGData: transparentPNGData,
          metadata: metadataData(record: record, configuration: configuration)
        )
      )
    }

    guard !poses.isEmpty else {
      throw MemojiError.noPoses
    }
    // AvatarKit's VFX queue can outlive its synchronous callback. Keep this object graph alive.
    retainedSessions.append(session)
    if retainedSessions.count > retainedSessionLimit {
      retainedSessions.removeFirst(retainedSessions.count - retainedSessionLimit)
    }

    poseCacheOrder.append(cacheKey)
    poseCache[cacheKey] = poses
    if poseCacheOrder.count > poseCacheLimit {
      let expiredKeys = poseCacheOrder.prefix(poseCacheOrder.count - poseCacheLimit)
      for expiredKey in expiredKeys {
        poseCache.removeValue(forKey: expiredKey)
      }
      poseCacheOrder.removeFirst(poseCacheOrder.count - poseCacheLimit)
    }
    return poses
  }

  @MainActor
  private static func avatarRecord(
    identifier: String,
    domainIdentifier: String
  ) throws -> (record: NSObject, avatarSelectorName: String) {
    if identifier.hasPrefix(stockMemojiIDPrefix) {
      let name = String(identifier.dropFirst(stockMemojiIDPrefix.count))
      if let record = try stockRecords().first(where: {
        stringValue($0, selectorName: "puppetName") == name
      }) {
        return (record, "avatarForRecord:")
      }
      throw MemojiError.memojiNotFound(identifier)
    }

    let dataSource = try makeDataSource(domainIdentifier: domainIdentifier)
    let indexes = try editableIndexes(dataSource: dataSource)
    let recordAtIndex = try recordReader(dataSource: dataSource)

    let selector = NSSelectorFromString("recordAtIndex:")
    for index in indexes {
      guard let record = recordAtIndex(
        dataSource,
        selector,
        UInt(index)
      )?.takeUnretainedValue() as? NSObject else { continue }
      let recordIdentifier = stringValue(record, selectorName: "identifier") ?? "record-\(index)"
      if recordIdentifier == identifier {
        return (record, "memojiForRecord:")
      }
    }
    throw MemojiError.memojiNotFound(identifier)
  }

  private static func stockRecords() throws -> [NSObject] {
    guard let type = NSClassFromString(puppetStoreClassName) as? NSObject.Type else {
      throw MemojiError.runtimeContractChanged(puppetStoreClassName)
    }
    _ = try validatedMethod(
      on: type,
      selectorName: "createPuppetRecords",
      dispatch: .classMethod,
      contract: .init(returnValue: .object, arguments: [])
    )
    guard let records = type.perform(
      NSSelectorFromString("createPuppetRecords")
    )?.takeUnretainedValue() as? [NSObject] else {
      throw MemojiError.runtimeContractChanged("createPuppetRecords")
    }
    return records
  }

  private static func avatar(
    for record: NSObject,
    renderingType: NSObject.Type,
    selectorName: String
  ) throws -> AnyObject {
    _ = try validatedMethod(
      on: renderingType,
      selectorName: selectorName,
      dispatch: .classMethod,
      contract: .init(returnValue: .object, arguments: [.object])
    )
    guard let avatar = renderingType.perform(
      NSSelectorFromString(selectorName),
      with: record
    )?.takeUnretainedValue() else {
      throw MemojiError.runtimeContractChanged(selectorName)
    }
    return avatar
  }

  @MainActor
  private static func makeDataSource(domainIdentifier: String) throws -> NSObject {
    guard let type = NSClassFromString(dataSourceClassName) as? NSObject.Type else {
      throw MemojiError.runtimeContractChanged(dataSourceClassName)
    }
    _ = try validatedMethod(
      on: type,
      selectorName: "defaultUIDataSourceWithDomainIdentifier:",
      dispatch: .classMethod,
      contract: .init(returnValue: .object, arguments: [.object])
    )
    guard let dataSource = type.perform(
      NSSelectorFromString("defaultUIDataSourceWithDomainIdentifier:"),
      with: domainIdentifier
    )?.takeUnretainedValue() as? NSObject else {
      throw MemojiError.runtimeContractChanged("defaultUIDataSourceWithDomainIdentifier:")
    }
    return dataSource
  }

  private static func editableIndexes(dataSource: NSObject) throws -> IndexSet {
    _ = try validatedMethod(
      on: type(of: dataSource),
      selectorName: "indexSetForEditableRecords",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .object, arguments: [])
    )
    guard let indexes = dataSource.perform(
      NSSelectorFromString("indexSetForEditableRecords")
    )?.takeUnretainedValue() as? IndexSet else {
      throw MemojiError.runtimeContractChanged("indexSetForEditableRecords")
    }
    return indexes
  }

  private static func recordReader(dataSource: NSObject) throws -> RecordAtIndex {
    let method = try validatedMethod(
      on: type(of: dataSource),
      selectorName: "recordAtIndex:",
      dispatch: .instanceMethod,
      contract: .init(returnValue: .object, arguments: [.unsignedInteger])
    )
    return unsafeBitCast(method_getImplementation(method), to: RecordAtIndex.self)
  }

  private static func metadataData(record: NSObject, configuration: NSObject) -> Data? {
    guard
      let utilitiesType = NSClassFromString(metadataUtilitiesClassName) as? NSObject.Type,
      let backgroundType = NSClassFromString(backgroundParametersClassName) as? NSObject.Type,
      (try? validatedMethod(
        on: backgroundType,
        selectorName: "defaultBackgroundColorDescription",
        dispatch: .classMethod,
        contract: .init(returnValue: .object, arguments: [])
      )) != nil,
      let background = backgroundType.perform(
        NSSelectorFromString("defaultBackgroundColorDescription")
      )?.takeUnretainedValue(),
      let method = try? validatedMethod(
        on: utilitiesType,
        selectorName: "memojiMetadataDataForAvatarRecord:poseConfiguration:backgroundColorDescription:",
        dispatch: .classMethod,
        contract: .init(returnValue: .object, arguments: [.object, .object, .object])
      )
    else { return nil }

    return unsafeBitCast(
      method_getImplementation(method),
      to: ThreeObjectClassMethod.self
    )(
      utilitiesType,
      NSSelectorFromString(
        "memojiMetadataDataForAvatarRecord:poseConfiguration:backgroundColorDescription:"
      ),
      record,
      configuration,
      background
    )?.takeUnretainedValue() as? Data
  }

  private static func stringValue(_ object: NSObject, selectorName: String) -> String? {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          (try? validatedMethod(
            on: type(of: object),
            selectorName: selectorName,
            dispatch: .instanceMethod,
            contract: .init(returnValue: .object, arguments: [])
          )) != nil
    else { return nil }

    return object.perform(selector)?.takeUnretainedValue() as? String
  }

  private static func transparentPNGData(from value: AnyObject) -> Data? {
    #if os(macOS)
    guard let image = value as? NSImage, let source = cgImage(from: image) else {
      return nil
    }
    return NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])
    #elseif os(iOS)
    return (value as? UIImage)?.pngData()
    #else
    return nil
    #endif
  }

  #if os(macOS)
  static func cgImage(from image: NSImage) -> CGImage? {
    var rect = NSRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }
  #endif

  static func compositedPNGData(
    source: CGImage,
    background: MemojiBackgroundStyle,
    outputDimension: Int,
    artworkScale: Double = 1,
    horizontalOffset: Double = 0,
    verticalOffset: Double = 0
  ) -> Data? {
    guard let context = CGContext(
      data: nil,
      width: outputDimension,
      height: outputDimension,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let bounds = CGRect(x: 0, y: 0, width: outputDimension, height: outputDimension)
    drawBackground(background, in: bounds, context: context)
    context.interpolationQuality = .high
    let scale = CGFloat(artworkScale)
    var artworkBounds = bounds.insetBy(
      dx: bounds.width * (1 - scale) / 2,
      dy: bounds.height * (1 - scale) / 2
    )
    artworkBounds.origin.x += bounds.width * horizontalOffset
    artworkBounds.origin.y -= bounds.height * verticalOffset
    context.draw(source, in: artworkBounds)
    guard let result = context.makeImage() else { return nil }

    #if os(macOS)
    return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    #elseif os(iOS)
    return UIImage(cgImage: result).pngData()
    #else
    return nil
    #endif
  }

  static func transformedPNGData(
    source: CGImage,
    scale: Double,
    horizontalOffset: Double,
    verticalOffset: Double,
    outputDimension: Int
  ) -> Data? {
    guard let context = bitmapContext(outputDimension: outputDimension) else { return nil }

    let outputSide = CGFloat(outputDimension)
    let sourceWidth = CGFloat(source.width)
    let sourceHeight = CGFloat(source.height)
    let fillScale = max(outputSide / sourceWidth, outputSide / sourceHeight)
    let renderedWidth = sourceWidth * fillScale * scale
    let renderedHeight = sourceHeight * fillScale * scale
    let maximumXOffset = max(0, (renderedWidth - outputSide) / (2 * outputSide))
    let maximumYOffset = max(0, (renderedHeight - outputSide) / (2 * outputSide))
    let xOffset = min(max(CGFloat(horizontalOffset), -maximumXOffset), maximumXOffset)
    let yOffset = min(max(CGFloat(verticalOffset), -maximumYOffset), maximumYOffset)

    let destination = CGRect(
      x: (outputSide - renderedWidth) / 2 + xOffset * outputSide,
      y: (outputSide - renderedHeight) / 2 - yOffset * outputSide,
      width: renderedWidth,
      height: renderedHeight
    )
    context.interpolationQuality = .high
    context.draw(source, in: destination)
    return pngData(from: context)
  }

  static func emojiPNGData(
    emoji: String,
    background: MemojiBackgroundStyle,
    outputDimension: Int,
    artworkScale: Double = 1,
    horizontalOffset: Double = 0,
    verticalOffset: Double = 0
  ) -> Data? {
    guard let context = bitmapContext(outputDimension: outputDimension) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: outputDimension, height: outputDimension)
    drawBackground(background, in: bounds, context: context)

    let font = CTFontCreateWithName(
      "AppleColorEmoji" as CFString,
      CGFloat(outputDimension) * 0.52 * artworkScale,
      nil
    )
    let attributes = [kCTFontAttributeName: font] as CFDictionary
    guard let attributedString = CFAttributedStringCreate(nil, emoji as CFString, attributes) else {
      return nil
    }
    let line = CTLineCreateWithAttributedString(attributedString)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    context.textMatrix = .identity
    context.textPosition = CGPoint(
      x: (bounds.width - width) / 2 + bounds.width * horizontalOffset,
      y: (bounds.height - ascent - descent) / 2 + descent - bounds.height * verticalOffset
    )
    CTLineDraw(line, context)
    return pngData(from: context)
  }

  private static func bitmapContext(outputDimension: Int) -> CGContext? {
    guard outputDimension > 0 else { return nil }
    return CGContext(
      data: nil,
      width: outputDimension,
      height: outputDimension,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  private static func pngData(from context: CGContext) -> Data? {
    guard let result = context.makeImage() else { return nil }

    #if os(macOS)
    return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    #elseif os(iOS)
    return UIImage(cgImage: result).pngData()
    #else
    return nil
    #endif
  }

  private static func drawBackground(
    _ background: MemojiBackgroundStyle,
    in bounds: CGRect,
    context: CGContext
  ) {
    guard background.isTransparent == false else { return }
    guard let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [cgColor(background.topColor), cgColor(background.bottomColor)] as CFArray,
      locations: [0, 1]
    ) else { return }
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: bounds.midX, y: bounds.maxY),
      end: CGPoint(x: bounds.midX, y: bounds.minY),
      options: []
    )
  }

  private static func cgColor(_ color: MemojiRGBAColor) -> CGColor {
    CGColor(
      srgbRed: color.red,
      green: color.green,
      blue: color.blue,
      alpha: color.alpha
    )
  }
}
