import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import UIKit

/// Data & Storage page (SwiftUI `DataStorageSettingsView`) without the donut chart and the
/// per-item / per-chat browsers: downloads by category with a Clear action, automatic cleanup,
/// auto-download limits and cellular use.
///
/// `StorageUsageViewModel` is `CompatObservable`, so its `@Tracked` reads in `makeSections()`
/// re-render the page on their own.
@MainActor
final class DataStorageSettingsViewController: SettingsFormViewController {
  private let storage: StorageUsageViewModel
  private var allowsCellular = AutoDownloadNetwork.allowsCellular
  private var shownError: String?

  init(shell: MainShellController) {
    storage = StorageUsageViewModel()
    super.init(shell: shell, title: String(localized: "Data & Storage"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(INUserSettings.current.autoDownload.objectWillChange)
    let refresh = UIRefreshControl()
    refresh.addAction(UIAction { [weak self, weak refresh] _ in
      guard let self else { return }
      Task {
        await self.storage.refresh()
        refresh?.endRefreshing()
      }
    }, for: .valueChanged)
    tableView.refreshControl = refresh
    Task { [weak self] in await self?.storage.refresh() }
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let storage = self.storage
    let categories = storage.visibleCategories
    let summary = storage.summary
    let hasSummary = storage.hasSummary
    let selectedBytes = storage.selectedRemovableBytes
    let isClearing = storage.isClearing
    let autoDownload = INUserSettings.current.autoDownload
    let device = UIDevice.current.model
    let _ = presentErrorIfNeeded(storage.errorMessage)

    FormSection("usage", header: String(localized: "Downloads")) {
      if hasSummary {
        FormRow.value(
          "total",
          String(localized: "Total on This \(device)"),
          value: summary.totalBytes.storageFormatted,
          icon: .tile("externaldrive.fill", .systemIndigo)
        )
      }
      if categories.isEmpty {
        if hasSummary {
          FormRow.note("empty", String(localized: "No downloads on this \(device)"))
        } else {
          FormRow("measuring", title: String(localized: "Measuring…"), accessory: .activity)
        }
      } else {
        for category in categories {
          Self.categoryRow(category, storage: storage, summary: summary, isClearing: isClearing)
        }
      }
    }

    if !categories.isEmpty {
      FormSection("clear", footer: String(localized: "Downloads are removed from this \(device). They stay in your chats.")) {
        FormRow.button(
          "clear",
          selectedBytes > 0
            ? String(localized: "Clear \(selectedBytes.storageFormatted)")
            : String(localized: "Clear"),
          role: .destructive,
          isEnabled: selectedBytes > 0,
          isLoading: isClearing
        ) { [weak self] in
          self?.confirmClearSelected()
        }
      }
    }

    FormSection(
      "cleanup",
      header: String(localized: "Automatic Cleanup"),
      footer: String(localized: "Removes downloads you haven’t opened for a while, oldest first when over the size.")
    ) {
      FormRow.navigation(
        "keepMedia",
        String(localized: "Keep Media"),
        value: storage.keepMedia.title,
        icon: .tile("clock.arrow.circlepath", .systemGreen)
      ) { [weak self] in
        self?.pushKeepMediaPicker()
      }
      FormRow.navigation(
        "cacheLimit",
        String(localized: "Maximum Size"),
        value: storage.cacheLimit.title,
        icon: .tile("internaldrive.fill", .systemGray)
      ) { [weak self] in
        self?.pushCacheLimitPicker()
      }
    }

    FormSection(
      "autoDownload",
      header: String(localized: "Auto-Download"),
      footer: String(localized: "Larger files download when you open them.")
    ) {
      limitRow(
        "media", String(localized: "Photos and Videos"), icon: .tile("photo.on.rectangle.angled", .systemBlue),
        kind: .media, keyPath: \.mediaMaxMB, settings: autoDownload
      )
      limitRow(
        "file", String(localized: "Files"), icon: .tile("doc.fill", .systemOrange),
        kind: .file, keyPath: \.fileMaxMB, settings: autoDownload
      )
      limitRow(
        "voice", String(localized: "Voice Messages"), icon: .tile("waveform", .systemPink),
        kind: .voice, keyPath: \.voiceMaxMB, settings: autoDownload
      )
    }

    FormSection(
      "cellular",
      footer: allowsCellular
        ? String(localized: "Low Data Mode counts as cellular.")
        : String(localized: "Photos, videos, and files wait for Wi‑Fi. Voice messages still download.")
    ) {
      FormRow.toggle(
        "cellular",
        String(localized: "Use Cellular Data"),
        icon: .tile("antenna.radiowaves.left.and.right", .systemGreen),
        isOn: allowsCellular
      ) { [weak self] isOn in
        AutoDownloadNetwork.allowsCellular = isOn
        self?.allowsCellular = isOn
        self?.setNeedsFormUpdate()
      }
    }
  }

  // MARK: Rows

  private static func categoryRow(
    _ category: StorageCategory,
    storage: StorageUsageViewModel,
    summary: StorageUsageSummary,
    isClearing: Bool
  ) -> FormRow {
    let canSelect = storage.removableBytes(for: category) > 0
    let count = storage.report.map { _ in storage.count(for: category) }
    var row = FormRow(
      "category-\(category.rawValue)",
      title: category.title,
      subtitle: count.map { $0 == 1 ? String(localized: "1 item") : String(localized: "\($0) items") },
      value: summary.bytes(for: category).storageFormatted,
      icon: .tile(category.systemImage, color(for: category)),
      accessory: storage.isSelected(category) && canSelect ? .checkmark : .none,
      isEnabled: canSelect && !isClearing
    )
    row.onSelect = {
      CompatHaptics.selection()
      storage.toggle(category)
    }
    return row
  }

  private func limitRow(
    _ id: String,
    _ title: String,
    icon: FormIcon,
    kind: AutoDownloadKind,
    keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>,
    settings: AutoDownloadSettingsManager
  ) -> FormRow {
    FormRow.navigation(
      id,
      title,
      value: AutoDownloadSettingsManager.sizeLabel(settings[keyPath: keyPath]),
      icon: icon
    ) { [weak self] in
      let options = AutoDownloadSettingsManager.sizeOptions(for: kind, including: settings[keyPath: keyPath])
      self?.push(SettingsPickerViewController(
        title: title,
        footer: String(localized: "Larger files download when you open them."),
        options: options.map { SettingsPickerOption(id: String($0), title: AutoDownloadSettingsManager.sizeLabel($0)) },
        selectedID: { String(AutoDownloadSettingsManager.clamped(settings[keyPath: keyPath])) },
        onSelect: { id, _ in
          guard let megabytes = Int(id) else { return }
          settings[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(megabytes)
        }
      ))
    }
  }

  private static func color(for category: StorageCategory) -> UIColor {
    switch category {
    case .photos: .systemBlue
    case .videos: .systemPurple
    case .files: .systemOrange
    case .voice: .systemPink
    case .other: .systemGray
    }
  }

  // MARK: Actions

  private func confirmClearSelected() {
    let bytes = storage.selectedRemovableBytes
    guard bytes > 0, !storage.isClearing else { return }
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: String(localized: "Clear \(bytes.storageFormatted)?"),
        message: String(localized: "Downloads are removed from this \(UIDevice.current.model). They stay in your chats."),
        confirmTitle: String(localized: "Clear"),
        destructive: true,
        style: .actionSheet
      )
      guard confirmed else { return }
      let storage = self.storage
      perform { await storage.clearSelected() }
    }
  }

  private func pushKeepMediaPicker() {
    let storage = self.storage
    push(SettingsPickerViewController(
      title: String(localized: "Keep Media"),
      footer: String(localized: "Removes downloads you haven’t opened for a while."),
      options: StorageKeepMedia.allCases.map { SettingsPickerOption(id: String($0.rawValue), title: $0.title) },
      selectedID: { String(storage.keepMedia.rawValue) },
      popsOnSelect: false
    ) { [weak self] id, picker in
      guard let value = StorageKeepMedia(rawValue: Int(id) ?? -1) else { return }
      self?.applyCleanup(
        bytes: storage.cleanupBytes(keepMedia: value),
        from: picker
      ) { await storage.setKeepMedia(value) }
    })
  }

  private func pushCacheLimitPicker() {
    let storage = self.storage
    push(SettingsPickerViewController(
      title: String(localized: "Maximum Size"),
      footer: String(localized: "Oldest downloads are removed first when over the size."),
      options: StorageCacheLimit.allCases.map { SettingsPickerOption(id: String($0.rawValue), title: $0.title) },
      selectedID: { String(storage.cacheLimit.rawValue) },
      popsOnSelect: false
    ) { [weak self] id, picker in
      guard let value = StorageCacheLimit(rawValue: Int(id) ?? -1) else { return }
      self?.applyCleanup(
        bytes: storage.cleanupBytes(cacheLimit: value),
        from: picker
      ) { await storage.setCacheLimit(value) }
    })
  }

  /// A tighter limit removes downloads now: confirm with the size first, like the SwiftUI page.
  private func applyCleanup(
    bytes: Int64,
    from picker: SettingsPickerViewController,
    work: @escaping @MainActor () async -> StorageCleanupResult?
  ) {
    guard bytes > 0 else {
      perform(work)
      picker.finish()
      return
    }
    Task { [weak self, weak picker] in
      guard let picker else { return }
      let confirmed = await picker.confirm(
        title: String(localized: "Remove \(bytes.storageFormatted)?"),
        message: String(localized: "Downloads are removed now and once a day after. They stay in your chats."),
        confirmTitle: String(localized: "Remove \(bytes.storageFormatted)"),
        destructive: true,
        style: .actionSheet
      )
      if confirmed { self?.perform(work) }
      picker.finish()
    }
  }

  private func perform(_ work: @escaping @MainActor () async -> StorageCleanupResult?) {
    Task { @MainActor in
      let result = await work()
      await ImagePrefetcher.shared.clearCache()
      let freed = result?.removedBytes ?? 0
      guard freed > 0 else { return }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      ToastManager.shared.showToast(
        String(localized: "Freed \(freed.storageFormatted)"),
        type: .success,
        systemImage: "checkmark.circle.fill"
      )
    }
  }

  /// `errorMessage` is tracked state; show it once as an alert, then clear it.
  private func presentErrorIfNeeded(_ message: String?) -> Bool {
    guard let message, message != shownError else {
      if message == nil { shownError = nil }
      return false
    }
    shownError = message
    DispatchQueue.main.async { [weak self] in
      guard let self, view.window != nil else { return }
      presentAlert(title: String(localized: "Storage"), message: message)
      storage.errorMessage = nil
    }
    return true
  }
}
