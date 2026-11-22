import Charts
import InlineKit
import InlineUI
import QuickLook
import SwiftUI

@available(iOS 17.0, *)
struct DataStorageSettingsView: View {
  @ObservedObject private var autoDownload = INUserSettings.current.autoDownload
  @State private var storage = StorageUsageViewModel()
  @State private var allowsCellular = AutoDownloadNetwork.allowsCellular

  @State private var confirmsClear = false
  @State private var pendingCleanup: PendingCleanup?

  var body: some View {
    List {
      Section {
        StorageDonut(summary: storage.summary, isLoading: !storage.hasSummary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      downloadsSection
      cleanupSection
      autoDownloadSection

      ResetLocalDataSettingsSection()
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Data & Storage")
    .navigationBarTitleDisplayMode(.inline)
    .task { await storage.refresh() }
    .refreshable { await storage.refresh() }
    .confirmationDialog(
      "Clear \(storage.selectedRemovableBytes.storageFormatted)?",
      isPresented: $confirmsClear,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        perform { await storage.clearSelected() }
      }
    } message: {
      Text("Downloads are removed from this \(UIDevice.current.model). They stay in your chats.")
    }
    .confirmationDialog(
      pendingCleanup?.title ?? "",
      isPresented: Binding(get: { pendingCleanup != nil }, set: { if !$0 { pendingCleanup = nil } }),
      titleVisibility: .visible,
      presenting: pendingCleanup
    ) { pending in
      Button("Remove \(pending.bytes.storageFormatted)", role: .destructive) {
        perform {
          switch pending {
            case let .keepMedia(value, _): await storage.setKeepMedia(value)
            case let .cacheLimit(value, _): await storage.setCacheLimit(value)
          }
        }
      }
    } message: { _ in
      Text("Downloads are removed now and once a day after. They stay in your chats.")
    }
    .alert(
      "Storage",
      isPresented: Binding(get: { storage.errorMessage != nil }, set: { if !$0 { storage.errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(storage.errorMessage ?? "")
    }
  }

  // MARK: Downloads

  @ViewBuilder
  private var downloadsSection: some View {
    let categories = storage.visibleCategories
    Section("Downloads") {
      if categories.isEmpty {
        HStack(spacing: 12) {
          if storage.hasSummary {
            Image(systemName: "tray").foregroundStyle(.secondary)
            Text("No downloads on this \(UIDevice.current.model)").foregroundStyle(.secondary)
          } else {
            ProgressView()
            Text("Measuring…").foregroundStyle(.secondary)
          }
        }
      } else {
        ForEach(categories) { category in
          StorageCategoryRow(
            category: category,
            bytes: storage.summary.bytes(for: category),
            count: storage.report.map { _ in storage.count(for: category) },
            isSelected: storage.isSelected(category),
            canSelect: storage.removableBytes(for: category) > 0,
            onToggle: { withAnimation(.snappy) { storage.toggle(category) } },
            destination: { StorageItemsView(scope: .category(category), storage: storage) }
          )
        }
      }

      if !storage.chats.isEmpty {
        NavigationLink {
          StorageChatsView(storage: storage)
        } label: {
          SettingsItem(icon: "bubble.left.and.bubble.right.fill", iconColor: .accentColor, title: "Chats") {
            Text(storage.chats.count.formatted())
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
    }
    .animation(.snappy, value: categories)

    if !categories.isEmpty {
      Section {
        Button {
          confirmsClear = true
        } label: {
          Group {
            if storage.isClearing {
              ProgressView().tint(.white)
            } else {
              Text(storage.selectedRemovableBytes > 0 ? "Clear \(storage.selectedRemovableBytes.storageFormatted)" : "Clear")
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(storage.selectedRemovableBytes == 0 || storage.isClearing)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .animation(.snappy, value: storage.selectedRemovableBytes)
      }
    }
  }

  // MARK: Automatic Cleanup

  private var cleanupSection: some View {
    Section {
      Picker(selection: keepMediaBinding) {
        ForEach(StorageKeepMedia.allCases) { Text($0.title).tag($0) }
      } label: {
        SettingsItem(icon: "clock.arrow.circlepath", iconColor: .green, title: "Keep Media")
      }
      .pickerStyle(.menu)

      Picker(selection: cacheLimitBinding) {
        ForEach(StorageCacheLimit.allCases) { Text($0.title).tag($0) }
      } label: {
        SettingsItem(icon: "internaldrive.fill", iconColor: .gray, title: "Maximum Size")
      }
      .pickerStyle(.menu)
    } header: {
      Text("Automatic Cleanup")
    } footer: {
      Text("Removes downloads you haven’t opened for a while, oldest first when over the size.")
    }
  }

  private var keepMediaBinding: Binding<StorageKeepMedia> {
    Binding {
      storage.keepMedia
    } set: { value in
      let bytes = storage.cleanupBytes(keepMedia: value)
      if bytes > 0 {
        pendingCleanup = .keepMedia(value, bytes: bytes)
      } else {
        perform { await storage.setKeepMedia(value) }
      }
    }
  }

  private var cacheLimitBinding: Binding<StorageCacheLimit> {
    Binding {
      storage.cacheLimit
    } set: { value in
      let bytes = storage.cleanupBytes(cacheLimit: value)
      if bytes > 0 {
        pendingCleanup = .cacheLimit(value, bytes: bytes)
      } else {
        perform { await storage.setCacheLimit(value) }
      }
    }
  }

  // MARK: Auto-Download

  @ViewBuilder
  private var autoDownloadSection: some View {
    Section {
      limitPicker(icon: "photo.on.rectangle.angled", color: .blue, title: "Photos and Videos", kind: .media, value: binding(\.mediaMaxMB))
      limitPicker(icon: "doc.fill", color: .orange, title: "Files", kind: .file, value: binding(\.fileMaxMB))
      limitPicker(icon: "waveform", color: .pink, title: "Voice Messages", kind: .voice, value: binding(\.voiceMaxMB))
    } header: {
      Text("Auto-Download")
    } footer: {
      Text("Larger files download when you open them.")
    }

    Section {
      Toggle(isOn: Binding(get: { allowsCellular }, set: { value in
        allowsCellular = value
        AutoDownloadNetwork.allowsCellular = value
      })) {
        SettingsItem(icon: "antenna.radiowaves.left.and.right", iconColor: .green, title: "Use Cellular Data")
      }
    } footer: {
      Text(allowsCellular
        ? "Low Data Mode counts as cellular."
        : "Photos, videos, and files wait for Wi‑Fi. Voice messages still download.")
    }
  }

  private func limitPicker(icon: String, color: Color, title: String, kind: AutoDownloadKind, value: Binding<Int>) -> some View {
    Picker(selection: value) {
      ForEach(AutoDownloadSettingsManager.sizeOptions(for: kind, including: value.wrappedValue), id: \.self) { megabytes in
        Text(AutoDownloadSettingsManager.sizeLabel(megabytes)).tag(megabytes)
      }
    } label: {
      SettingsItem(icon: icon, iconColor: color, title: title)
    }
    .pickerStyle(.menu)
  }

  private func binding(_ keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>) -> Binding<Int> {
    Binding {
      autoDownload[keyPath: keyPath]
    } set: { value in
      autoDownload[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(value)
    }
  }

  private func perform(_ work: @escaping @MainActor () async -> StorageCleanupResult?) {
    Task { @MainActor in
      let result = await work()
      await ImagePrefetcher.shared.clearCache()
      StorageFeedback.freed(result?.removedBytes ?? 0)
    }
  }
}

@available(iOS 17.0, *)
private enum PendingCleanup: Identifiable {
  case keepMedia(StorageKeepMedia, bytes: Int64)
  case cacheLimit(StorageCacheLimit, bytes: Int64)

  var id: String {
    switch self {
      case let .keepMedia(value, _): "keep-\(value.rawValue)"
      case let .cacheLimit(value, _): "limit-\(value.rawValue)"
    }
  }

  var bytes: Int64 {
    switch self {
      case let .keepMedia(_, bytes), let .cacheLimit(_, bytes): bytes
    }
  }

  var title: String {
    switch self {
      case let .keepMedia(value, _): "Keep media for \(value.title.lowercased())?"
      case let .cacheLimit(value, _): "Limit downloads to \(value.title)?"
    }
  }
}

@available(iOS 17.0, *)
@MainActor
private enum StorageFeedback {
  static func freed(_ bytes: Int64) {
    guard bytes > 0 else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    ToastManager.shared.showToast(
      "Freed \(bytes.storageFormatted)",
      description: nil,
      type: .success,
      systemImage: "checkmark.circle.fill"
    )
  }
}

// MARK: - Donut

@available(iOS 17.0, *)
private struct StorageDonut: View {
  let summary: StorageUsageSummary
  let isLoading: Bool

  @State private var selectedAngle: Double?
  @State private var appeared = false

  private struct Slice: Identifiable, Equatable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
  }

  private var slices: [Slice] {
    var slices = StorageCategory.allCases.compactMap { category -> Slice? in
      let bytes = summary.bytes(for: category)
      guard bytes > 0 else { return nil }
      return Slice(id: category.rawValue, title: category.title, bytes: bytes, color: StorageCategoryStyle.color(category))
    }
    if summary.databaseBytes > 0 {
      slices.append(Slice(id: "messages", title: "Messages", bytes: summary.databaseBytes, color: StorageCategoryStyle.databaseColor))
    }
    return slices
  }

  private func slice(at angle: Double?) -> Slice? {
    guard let angle else { return nil }
    var running: Double = 0
    for slice in slices {
      running += Double(slice.bytes)
      if angle <= running { return slice }
    }
    return nil
  }

  var body: some View {
    let slices = slices
    let selected = slice(at: selectedAngle)
    ZStack {
      if slices.isEmpty {
        Circle()
          .stroke(Color.secondary.opacity(0.12), lineWidth: 26)
          .padding(14)
      } else {
        Chart(slices) { slice in
          SectorMark(
            angle: .value("Size", appeared ? Double(slice.bytes) : 1),
            innerRadius: .ratio(0.64),
            outerRadius: .ratio(selected?.id == slice.id ? 1 : 0.94),
            angularInset: 1.5
          )
          .cornerRadius(5)
          .foregroundStyle(slice.color.gradient)
          .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.4)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .animation(.smooth(duration: 0.6), value: slices)
      }

      VStack(spacing: 2) {
        if let selected {
          Text(selected.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(selected.bytes.storageFormatted)
            .font(.system(.title, design: .rounded).weight(.bold))
            .monospacedDigit()
        } else if isLoading {
          ProgressView()
        } else {
          Text(summary.totalBytes.storageFormatted)
            .font(.system(.title, design: .rounded).weight(.bold))
            .monospacedDigit()
            .contentTransition(.numericText())
          Text("on this \(UIDevice.current.model)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .animation(.snappy, value: selected?.id)
      .animation(.smooth, value: summary.totalBytes)
    }
    .frame(width: 210, height: 210)
    .sensoryFeedback(.selection, trigger: selected?.id)
    .onAppear {
      withAnimation(.smooth(duration: 0.8).delay(0.1)) { appeared = true }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Storage usage, \(summary.totalBytes.storageFormatted)")
    .accessibilityValue(slices.map { "\($0.title) \($0.bytes.storageFormatted)" }.joined(separator: ", "))
  }
}

// MARK: - Rows

@available(iOS 17.0, *)
private struct StorageCategoryIcon: View {
  let systemImage: String
  let color: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.callout)
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
  }
}

@available(iOS 17.0, *)
private struct StorageCategoryRow<Destination: View>: View {
  let category: StorageCategory
  let bytes: Int64
  /// Nil until the first scan finishes.
  let count: Int?
  let isSelected: Bool
  let canSelect: Bool
  let onToggle: () -> Void
  @ViewBuilder let destination: () -> Destination

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onToggle) {
        HStack(spacing: 12) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? StorageCategoryStyle.color(category) : Color.secondary.opacity(0.5))
            .contentTransition(.symbolEffect(.replace))

          StorageCategoryIcon(systemImage: category.systemImage, color: StorageCategoryStyle.color(category))

          VStack(alignment: .leading, spacing: 1) {
            Text(category.title).foregroundStyle(.primary)
            if let count {
              Text(category == .other ? "Profile photos and unused files" : (count == 1 ? "1 item" : "\(count.formatted()) items"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Text(bytes.storageFormatted)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canSelect)

      NavigationLink {
        destination()
      } label: {
        EmptyView()
      }
      .frame(width: 12)
      .disabled((count ?? 0) == 0)
    }
    .sensoryFeedback(.selection, trigger: isSelected)
  }
}

@available(iOS 17.0, *)
private struct StorageChatIcon: View {
  let usage: StorageChatUsage

  var body: some View {
    if let user = usage.user {
      UserAvatar(userInfo: user, size: 32)
    } else {
      ZStack {
        Circle().fill(Color.secondary.opacity(0.15))
        if let emoji = usage.chat?.emoji, !emoji.isEmpty {
          Text(emoji).font(.system(size: 16))
        } else {
          Image(systemName: "bubble.left.fill")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 32, height: 32)
    }
  }
}

@available(iOS 17.0, *)
private struct StorageChatRow: View {
  let usage: StorageChatUsage
  let largestBytes: Int64

  @State private var appeared = false

  var body: some View {
    HStack(spacing: 12) {
      StorageChatIcon(usage: usage)
      VStack(alignment: .leading, spacing: 6) {
        Text(usage.title).lineLimit(1)
        GeometryReader { proxy in
          let width = max(proxy.size.width * CGFloat(usage.bytes) / CGFloat(max(largestBytes, 1)), 4)
          HStack(spacing: 1) {
            ForEach(StorageCategory.allCases) { category in
              let bytes = usage.bytesByCategory[category] ?? 0
              if bytes > 0 {
                Rectangle()
                  .fill(StorageCategoryStyle.color(category))
                  .frame(width: max(width * CGFloat(bytes) / CGFloat(max(usage.bytes, 1)), 1))
              }
            }
          }
          .frame(width: appeared ? width : 0, alignment: .leading)
          .clipShape(Capsule())
        }
        .frame(height: 4)
      }
      Spacer(minLength: 8)
      Text(usage.bytes.storageFormatted)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .onAppear { withAnimation(.smooth(duration: 0.7)) { appeared = true } }
  }
}

// MARK: - Chats

/// Chats ordered by the space their downloads take.
@available(iOS 17.0, *)
private struct StorageChatsView: View {
  let storage: StorageUsageViewModel

  @State private var chatToClear: StorageChatUsage?

  var body: some View {
    let chats = storage.chats
    let largest = chats.first?.bytes ?? 1
    List {
      Section {
        ForEach(chats) { usage in
          NavigationLink {
            StorageItemsView(scope: .chat(usage.chatId), storage: storage)
          } label: {
            StorageChatRow(usage: usage, largestBytes: largest)
          }
          .swipeActions {
            if usage.removableBytes > 0 {
              Button("Clear", role: .destructive) { chatToClear = usage }
            }
          }
          .contextMenu {
            Button("Clear Downloads", systemImage: "trash", role: .destructive) { chatToClear = usage }
              .disabled(usage.removableBytes == 0)
          }
        }
      } footer: {
        if !chats.isEmpty {
          Text("Swipe a chat to clear its downloads.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .overlay {
      if chats.isEmpty {
        ContentUnavailableView("No Downloads", systemImage: "tray")
      }
    }
    .animation(.snappy, value: chats.map(\.id))
    .navigationTitle("Chats")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog(
      "Clear downloads from \(chatToClear?.title ?? "this chat")?",
      isPresented: Binding(get: { chatToClear != nil }, set: { if !$0 { chatToClear = nil } }),
      titleVisibility: .visible,
      presenting: chatToClear
    ) { usage in
      Button("Clear \(usage.removableBytes.storageFormatted)", role: .destructive) {
        Task {
          let result = await storage.clear(categories: Set(StorageCategory.allCases), chatId: usage.chatId)
          StorageFeedback.freed(result?.removedBytes ?? 0)
        }
      }
    } message: { _ in
      Text("Messages stay. Media downloads again when you open it.")
    }
  }
}

// MARK: - Items

@available(iOS 17.0, *)
enum StorageItemsScope: Hashable {
  case category(StorageCategory)
  case chat(Int64)
}

@available(iOS 17.0, *)
private enum StorageItemsSort: String, CaseIterable, Identifiable {
  case size = "Size"
  case date = "Date"
  var id: String { rawValue }
}

/// Every download in a category or chat, largest first, with swipe and multi-select removal.
@available(iOS 17.0, *)
struct StorageItemsView: View {
  let scope: StorageItemsScope
  let storage: StorageUsageViewModel

  @Environment(\.editMode) private var editMode
  @State private var selection = Set<StorageItem.ID>()
  @State private var categoryFilter: StorageCategory?
  @State private var sort: StorageItemsSort = .size
  @State private var previewURL: URL?
  @State private var pendingRemoval: [StorageItem] = []

  private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

  var body: some View {
    List(selection: $selection) {
      if case .chat = scope, presentCategories.count > 1 {
        Section {
          Picker("Kind", selection: $categoryFilter) {
            Text("All").tag(StorageCategory?.none)
            ForEach(presentCategories) { Text($0.title).tag(StorageCategory?.some($0)) }
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
      }

      Section {
        ForEach(items) { item in
          StorageItemRow(item: item, chatTitle: showsChat ? item.chatId.flatMap { storage.chat($0)?.title } : nil)
            .contentShape(Rectangle())
            .onTapGesture {
              guard !isEditing else { return }
              previewURL = item.url
            }
            .swipeActions {
              if item.isRemovable {
                Button("Remove", role: .destructive) { pendingRemoval = [item] }
              }
            }
            .selectionDisabled(!item.isRemovable)
        }
      } header: {
        Text("\(items.count.formatted()) items · \(items.reduce(Int64(0)) { $0 + $1.bytes }.storageFormatted)")
          .contentTransition(.numericText())
      }
    }
    .listStyle(.insetGrouped)
    .overlay {
      if storage.report != nil, items.isEmpty {
        ContentUnavailableView("No Downloads", systemImage: "tray")
      }
    }
    .animation(.snappy, value: items.map(\.id))
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .quickLookPreview($previewURL)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Sort By", selection: $sort) {
            ForEach(StorageItemsSort.allCases) { Text($0.rawValue).tag($0) }
          }
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
      }
      ToolbarItem(placement: .topBarTrailing) {
        EditButton()
      }
      ToolbarItemGroup(placement: .bottomBar) {
        if isEditing {
          Button(selection.count == removableItems.count ? "Deselect All" : "Select All") {
            selection = selection.count == removableItems.count ? [] : Set(removableItems.map(\.id))
          }
          Spacer()
          Button("Remove \(selectedBytes.storageFormatted)", role: .destructive) {
            pendingRemoval = items.filter { selection.contains($0.id) && $0.isRemovable }
          }
          .disabled(selectedBytes == 0)
        } else if !removableItems.isEmpty {
          Spacer()
          Button("Clear \(removableItems.reduce(Int64(0)) { $0 + $1.bytes }.storageFormatted)", role: .destructive) {
            pendingRemoval = removableItems
          }
          Spacer()
        }
      }
    }
    .confirmationDialog(
      "Remove \(pendingRemoval.count == 1 ? "1 download" : "\(pendingRemoval.count.formatted()) downloads")?",
      isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } }),
      titleVisibility: .visible
    ) {
      Button("Remove \(pendingRemoval.reduce(Int64(0)) { $0 + $1.bytes }.storageFormatted)", role: .destructive) {
        let removal = pendingRemoval
        Task {
          let result = await storage.remove(removal)
          selection.removeAll()
          editMode?.wrappedValue = .inactive
          StorageFeedback.freed(result?.removedBytes ?? 0)
        }
      }
    } message: {
      Text("They stay in your chats.")
    }
  }

  private var title: String {
    switch scope {
      case let .category(category): category.title
      case let .chat(chatId): storage.chat(chatId)?.title ?? "Chat"
    }
  }

  private var showsChat: Bool {
    if case .category = scope { return true }
    return false
  }

  private var scopedItems: [StorageItem] {
    guard let report = storage.report else { return [] }
    switch scope {
      case let .category(category): return report.items(in: category)
      case let .chat(chatId): return report.items(inChat: chatId)
    }
  }

  private var presentCategories: [StorageCategory] {
    let present = Set(scopedItems.map(\.category))
    return StorageCategory.allCases.filter { present.contains($0) }
  }

  private var items: [StorageItem] {
    let filtered = scopedItems.filter { categoryFilter == nil || $0.category == categoryFilter }
    switch sort {
      case .size: return filtered.sorted { $0.bytes > $1.bytes }
      case .date: return filtered.sorted { $0.date > $1.date }
    }
  }

  private var removableItems: [StorageItem] {
    items.filter(\.isRemovable)
  }

  private var selectedBytes: Int64 {
    items.reduce(0) { $0 + (selection.contains($1.id) && $1.isRemovable ? $1.bytes : 0) }
  }
}

@available(iOS 17.0, *)
private struct StorageItemRow: View {
  let item: StorageItem
  let chatTitle: String?

  var body: some View {
    HStack(spacing: 12) {
      StorageThumbnail(item: item, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(item.displayName).lineLimit(1).truncationMode(.middle)
          if let protection = item.protection {
            Text(protection == .draft ? "Draft" : protection == .unsent ? "Unsent" : "In Use")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
          }
        }
        Text([chatTitle, item.date.formatted(.dateTime.day().month(.abbreviated).year())].compactMap(\.self).joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Text(item.bytes.storageFormatted)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}
