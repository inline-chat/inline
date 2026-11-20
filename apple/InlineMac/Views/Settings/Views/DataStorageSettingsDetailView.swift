import AppKit
import Foundation
import InlineKit
import InlineUI
import SwiftUI

struct DataStorageSettingsDetailView: View {
  @ObservedObject private var autoDownload = INUserSettings.current.autoDownload
  @State private var storage = StorageUsageViewModel()

  @State private var highlighted: StorageCategory?
  @State private var browser: StorageBrowserRoute?
  @State private var confirmsClear = false
  @State private var pendingCleanup: PendingCleanup?
  @State private var freedBytes: Int64?

  var body: some View {
    Form {
      overviewSection
      downloadsSection
      cleanupSection
      autoDownloadSection
    }
    .settingsFormStyle()
    .task { await storage.refresh() }
    .sheet(item: $browser) { route in
      StorageBrowserSheet(initialRoute: route, storage: storage, onFreed: showFreed)
    }
    .confirmationDialog(
      "Clear \(storage.selectedRemovableBytes.storageFormatted)?",
      isPresented: $confirmsClear
    ) {
      Button("Clear", role: .destructive) {
        perform { await storage.clearSelected() }
      }
    } message: {
      Text("\(selectedCategoryNames) will be removed from this Mac. They stay in your chats.")
    }
    .confirmationDialog(
      pendingCleanup?.title ?? "",
      isPresented: Binding(get: { pendingCleanup != nil }, set: { if !$0 { pendingCleanup = nil } }),
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
      Text("Downloads are removed from this Mac now and once a day after. They stay in your chats.")
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

  // MARK: Overview

  private var overviewSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(storage.hasSummary ? storage.summary.totalBytes.storageFormatted : "—")
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())

          caption
            .frame(maxWidth: .infinity, alignment: .leading)

          Button {
            NSWorkspace.shared.open(StorageUsageService.mediaFolderURL)
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Show Downloads in Finder")
          .accessibilityLabel("Show Downloads in Finder")
        }

        StorageUsageBar(summary: storage.summary, isLoading: !storage.hasSummary, highlighted: $highlighted)

        StorageLegend(summary: storage.summary, highlighted: $highlighted)
      }
      .padding(.vertical, 4)
      .animation(.smooth(duration: 0.45), value: storage.summary)
      .settingsSearchAnchor(.storageUsage)
    }
  }

  @ViewBuilder
  private var caption: some View {
    Group {
      if let freedBytes {
        Label("Freed \(freedBytes.storageFormatted)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      } else if storage.isClearing {
        HStack(spacing: 5) {
          ProgressView().controlSize(.mini)
          Text("Clearing…")
        }
      } else if !storage.hasSummary {
        HStack(spacing: 5) {
          ProgressView().controlSize(.mini)
          Text("Measuring…")
        }
      } else if storage.summary.removableBytes > 0 {
        Text("\(storage.summary.removableBytes.storageFormatted) can be cleared")
          .monospacedDigit()
          .contentTransition(.numericText())
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .animation(.smooth, value: freedBytes)
    .animation(.smooth, value: storage.isClearing)
  }

  // MARK: Downloads

  private var downloadsSection: some View {
    Section {
      let categories = storage.visibleCategories
      if categories.isEmpty {
        if storage.hasSummary {
          SettingsEmptyRow("No downloads on this Mac", systemImage: "tray")
        } else {
          SettingsLoadingRow("Measuring downloads…")
        }
      } else {
        ForEach(categories) { category in
          StorageCategoryRow(
            category: category,
            bytes: storage.summary.bytes(for: category),
            count: storage.report.map { _ in storage.count(for: category) },
            isSelected: storage.isSelected(category),
            canSelect: storage.removableBytes(for: category) > 0,
            isHighlighted: highlighted == category,
            onToggle: { withAnimation(.smooth) { storage.toggle(category) } },
            onShow: { browser = .category(category) }
          )
          .onHover { hovering in
            highlighted = hovering ? category : (highlighted == category ? nil : highlighted)
          }
          .transition(.opacity)
        }

        HStack {
          if !storage.chats.isEmpty {
            Button("Chats…") { browser = .chats }
              .help("Downloads by chat")
              .settingsSearchAnchor(.chatStorage)
          }

          Spacer()

          Button {
            confirmsClear = true
          } label: {
            Text(storage.selectedRemovableBytes > 0 ? "Clear \(storage.selectedRemovableBytes.storageFormatted)…" : "Clear…")
              .monospacedDigit()
              .contentTransition(.numericText())
          }
          .disabled(storage.selectedRemovableBytes == 0 || storage.isClearing)
          .animation(.smooth, value: storage.selectedRemovableBytes)
        }
        .settingsSearchAnchor(.clearDownloads)
      }
    } header: {
      SettingsSectionHeader("Downloads")
    }
    .animation(.smooth, value: storage.visibleCategories)
  }

  // MARK: Automatic Cleanup

  private var cleanupSection: some View {
    Section {
      LabeledContent {
        Picker("Keep Media", selection: keepMediaBinding) {
          ForEach(StorageKeepMedia.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
      } label: {
        SettingsRowLabel(.keepMedia, description: "Remove downloads you haven’t opened for this long.")
      }
      .settingsSearchAnchor(.keepMedia)

      LabeledContent {
        Picker("Maximum Size", selection: cacheLimitBinding) {
          ForEach(StorageCacheLimit.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
      } label: {
        SettingsRowLabel(.cacheLimit, description: "Remove the oldest downloads above this size.")
      }
      .settingsSearchAnchor(.cacheLimit)
    } header: {
      SettingsSectionHeader("Automatic Cleanup")
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

  private var autoDownloadSection: some View {
    Section {
      AutoDownloadLimitRow(item: .autoDownloadMedia, kind: .media, value: binding(\.mediaMaxMB))
      AutoDownloadLimitRow(item: .autoDownloadFiles, kind: .file, value: binding(\.fileMaxMB))
      AutoDownloadLimitRow(item: .autoDownloadVoiceMessages, kind: .voice, value: binding(\.voiceMaxMB))
    } header: {
      SettingsSectionHeader("Auto-Download", subtitle: "Larger files download when you open them.")
    }
  }

  // MARK: Helpers

  private var selectedCategoryNames: String {
    let names = storage.visibleCategories.filter { storage.isSelected($0) }.map(\.title)
    return names.isEmpty ? "Downloads" : ListFormatter.localizedString(byJoining: names)
  }

  private func perform(_ work: @escaping @MainActor () async -> StorageCleanupResult?) {
    Task { @MainActor in
      guard let result = await work() else { return }
      showFreed(result.removedBytes)
    }
  }

  private func showFreed(_ bytes: Int64) {
    guard bytes > 0 else { return }
    Task { @MainActor in
      withAnimation(.smooth) { freedBytes = bytes }
      try? await Task.sleep(for: .seconds(4))
      withAnimation(.smooth) { freedBytes = nil }
    }
  }

  private func binding(_ keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>) -> Binding<Int> {
    Binding {
      autoDownload[keyPath: keyPath]
    } set: { value in
      autoDownload[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(value)
    }
  }
}

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

// MARK: - Usage Bar

/// A segmented bar like the one in System Settings > General > Storage.
private struct StorageUsageBar: View {
  let summary: StorageUsageSummary
  let isLoading: Bool
  @Binding var highlighted: StorageCategory?

  @State private var appeared = false
  @State private var pulse = false

  var body: some View {
    GeometryReader { proxy in
      let segments = StorageSegment.segments(for: summary)
      let total = max(segments.reduce(Int64(0)) { $0 + $1.bytes }, 1)
      let spacing: CGFloat = 2
      let available = max(proxy.size.width - spacing * CGFloat(max(segments.count - 1, 0)), 0)

      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.primary.opacity(isLoading ? (pulse ? 0.12 : 0.06) : 0.06))

        HStack(spacing: spacing) {
          ForEach(segments) { segment in
            let width = max(available * CGFloat(segment.bytes) / CGFloat(total), 3)
            Rectangle()
              .fill(segment.color.gradient)
              .frame(width: appeared ? width : 0)
              .opacity(highlighted == nil || highlighted == segment.category ? 1 : 0.35)
              .onHover { hovering in
                guard let category = segment.category else { return }
                highlighted = hovering ? category : nil
              }
              .help("\(segment.title): \(segment.bytes.storageFormatted)")
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .animation(.smooth(duration: 0.6), value: segments)
    }
    .frame(height: 22)
    .animation(.smooth(duration: 0.25), value: highlighted)
    .onAppear {
      withAnimation(.smooth(duration: 0.8).delay(0.05)) { appeared = true }
      if isLoading {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Storage usage")
    .accessibilityValue(
      StorageSegment.segments(for: summary).map { "\($0.title) \($0.bytes.storageFormatted)" }.joined(separator: ", ")
    )
  }
}

private struct StorageSegment: Identifiable, Equatable {
  let id: String
  let category: StorageCategory?
  let title: String
  let bytes: Int64
  let color: Color

  /// Categories that hold anything, then messages (the database), which clearing never touches.
  static func segments(for summary: StorageUsageSummary) -> [StorageSegment] {
    var segments = StorageCategory.allCases.compactMap { category -> StorageSegment? in
      let bytes = summary.bytes(for: category)
      guard bytes > 0 else { return nil }
      return StorageSegment(
        id: category.rawValue, category: category, title: category.title, bytes: bytes,
        color: StorageCategoryStyle.color(category)
      )
    }
    if summary.databaseBytes > 0 {
      segments.append(StorageSegment(
        id: "messages", category: nil, title: "Messages", bytes: summary.databaseBytes,
        color: StorageCategoryStyle.databaseColor
      ))
    }
    return segments
  }
}

private struct StorageLegend: View {
  let summary: StorageUsageSummary
  @Binding var highlighted: StorageCategory?

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
      ForEach(StorageSegment.segments(for: summary)) { segment in
        HStack(spacing: 6) {
          Circle().fill(segment.color).frame(width: 8, height: 8)
          Text(segment.title)
          Text(segment.bytes.storageFormatted)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .font(.caption)
        .lineLimit(1)
        .opacity(highlighted == nil || highlighted == segment.category ? 1 : 0.45)
        .onHover { hovering in
          guard let category = segment.category else { return }
          highlighted = hovering ? category : nil
        }
        .help(segment.category == nil ? "Messages and chats. Clearing never removes them." : "")
      }
    }
    .animation(.smooth(duration: 0.25), value: highlighted)
  }
}

// MARK: - Rows

private struct StorageCategoryIcon: View {
  let systemImage: String
  let color: Color
  var size: CGFloat = 22

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
  }
}

private struct StorageCategoryRow: View {
  let category: StorageCategory
  let bytes: Int64
  /// Nil until the first scan finishes.
  let count: Int?
  let isSelected: Bool
  let canSelect: Bool
  let isHighlighted: Bool
  let onToggle: () -> Void
  let onShow: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) {
        HStack(spacing: 10) {
          StorageCategoryIcon(systemImage: category.systemImage, color: StorageCategoryStyle.color(category))
            .scaleEffect(isHighlighted ? 1.08 : 1)
          VStack(alignment: .leading, spacing: 2) {
            Text(category.title)
            if let count {
              Text(subtitle(count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }
          }
        }
      }
      .toggleStyle(.checkbox)
      .disabled(!canSelect)
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(bytes.storageFormatted)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText())

      Button(action: onShow) {
        Image(systemName: "info.circle")
      }
      .buttonStyle(.borderless)
      .disabled(count ?? 0 == 0)
      .help("Show \(category.title)")
      .accessibilityLabel("Show \(category.title)")
    }
    .animation(.smooth(duration: 0.2), value: isHighlighted)
  }

  private func subtitle(_ count: Int) -> String {
    if category == .other { return "Profile photos and unused files" }
    return count == 1 ? "1 item" : "\(count.formatted()) items"
  }
}

// MARK: - Browser

enum StorageBrowserRoute: Identifiable, Hashable {
  case category(StorageCategory)
  case chats
  case chat(Int64)

  var id: String {
    switch self {
      case let .category(category): "category-\(category.rawValue)"
      case .chats: "chats"
      case let .chat(chatId): "chat-\(chatId)"
    }
  }
}

/// Lists downloads by chat or by kind, like the lists in System Settings > General > Storage.
private struct StorageBrowserSheet: View {
  let initialRoute: StorageBrowserRoute
  let storage: StorageUsageViewModel
  let onFreed: (Int64) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var route: StorageBrowserRoute?
  @State private var chatToClear: StorageChatUsage?

  private var current: StorageBrowserRoute { route ?? initialRoute }
  private var canGoBack: Bool { initialRoute == .chats && current != .chats }

  var body: some View {
    VStack(spacing: 0) {
      switch current {
        case .chats:
          chatList
            .transition(.move(edge: .leading).combined(with: .opacity))
        case let .category(category):
          StorageFilesPane(scope: .category(category), storage: storage, onBack: nil, onDone: { dismiss() }, onFreed: onFreed)
        case let .chat(chatId):
          StorageFilesPane(
            scope: .chat(chatId),
            storage: storage,
            onBack: canGoBack ? { withAnimation(.smooth) { route = .chats } } : nil,
            onDone: { dismiss() },
            onFreed: onFreed
          )
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .frame(minWidth: 680, idealWidth: 760, minHeight: 440, idealHeight: 520)
    .confirmationDialog(
      "Clear downloads from \(chatToClear?.title ?? "this chat")?",
      isPresented: Binding(get: { chatToClear != nil }, set: { if !$0 { chatToClear = nil } }),
      presenting: chatToClear
    ) { usage in
      Button("Clear \(usage.removableBytes.storageFormatted)", role: .destructive) {
        Task {
          let result = await storage.clear(categories: Set(StorageCategory.allCases), chatId: usage.chatId)
          onFreed(result?.removedBytes ?? 0)
        }
      }
    } message: { _ in
      Text("Messages stay. Media downloads again when you open it.")
    }
  }

  private var chatList: some View {
    let chats = storage.chats
    let largest = chats.first?.bytes ?? 1
    return VStack(spacing: 0) {
      StorageSheetHeader(
        title: "Chats",
        subtitle: "\(chats.count) chats · \(chats.reduce(Int64(0)) { $0 + $1.bytes }.storageFormatted)",
        onBack: nil
      ) {
        StorageCategoryIcon(systemImage: "bubble.left.and.bubble.right.fill", color: .accentColor, size: 30)
      }

      List {
        ForEach(chats) { usage in
          StorageChatRow(
            usage: usage,
            largestBytes: largest,
            onOpen: { withAnimation(.smooth) { route = .chat(usage.chatId) } },
            onClear: { chatToClear = usage }
          )
        }
      }
      .listStyle(.inset)
      .overlay {
        if chats.isEmpty {
          ContentUnavailableView("No Downloads", systemImage: "tray")
        }
      }
      .animation(.smooth, value: chats.map(\.id))

      Divider()

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
  }
}

private struct StorageSheetHeader<Icon: View>: View {
  let title: String
  let subtitle: String
  let onBack: (() -> Void)?
  @ViewBuilder let icon: () -> Icon
  var trailing: AnyView? = nil

  var body: some View {
    HStack(spacing: 10) {
      if let onBack {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("[", modifiers: .command)
        .help("Chats")
        .accessibilityLabel("Back to Chats")
      }
      icon()
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline).lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 12)
  }
}

private struct StorageChatRow: View {
  let usage: StorageChatUsage
  let largestBytes: Int64
  let onOpen: () -> Void
  let onClear: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      StorageChatIcon(usage: usage, size: 28)

      VStack(alignment: .leading, spacing: 5) {
        Text(usage.title).lineLimit(1)
        StorageCompositionBar(usage: usage, largestBytes: largestBytes)
      }

      Spacer(minLength: 12)

      Text(usage.bytes.storageFormatted)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText())

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { isHovered = $0 }
    .listRowBackground(isHovered ? Color.primary.opacity(0.05) : Color.clear)
    .contextMenu {
      Button("Show Downloads", action: onOpen)
      Button("Clear Downloads…", role: .destructive, action: onClear)
        .disabled(usage.removableBytes == 0)
    }
    .accessibilityAddTraits(.isButton)
  }
}

private struct StorageChatIcon: View {
  let usage: StorageChatUsage
  let size: CGFloat

  var body: some View {
    if let user = usage.user {
      SidebarChatIcon(peer: .user(user), size: size)
    } else if let chat = usage.chat {
      SidebarChatIcon(peer: .chat(chat), size: size)
    } else {
      StorageCategoryIcon(systemImage: "bubble.left.fill", color: .gray, size: size)
    }
  }
}

/// A chat's downloads by category, as wide as its share of the largest chat.
private struct StorageCompositionBar: View {
  let usage: StorageChatUsage
  let largestBytes: Int64

  @State private var appeared = false

  var body: some View {
    GeometryReader { proxy in
      let fraction = CGFloat(usage.bytes) / CGFloat(max(largestBytes, 1))
      let width = max(proxy.size.width * fraction, 4)
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
    .onAppear { withAnimation(.smooth(duration: 0.7)) { appeared = true } }
  }
}

// MARK: - Files

private enum StorageFilesScope: Hashable {
  case category(StorageCategory)
  case chat(Int64)
}

private struct StorageFileRow: Identifiable {
  let item: StorageItem
  let name: String
  let chatTitle: String
  let kind: String

  var id: StorageItem.ID { item.id }
  var date: Date { item.date }
  var bytes: Int64 { item.bytes }
}

private struct StorageFilesPane: View {
  let scope: StorageFilesScope
  let storage: StorageUsageViewModel
  let onBack: (() -> Void)?
  let onDone: () -> Void
  let onFreed: (Int64) -> Void

  @State private var selection = Set<StorageItem.ID>()
  @State private var sortOrder = [KeyPathComparator(\StorageFileRow.bytes, order: .reverse)]
  @State private var searchText = ""
  @State private var categoryFilter: StorageCategory?
  @State private var pendingRemoval: [StorageItem] = []

  var body: some View {
    VStack(spacing: 0) {
      StorageSheetHeader(
        title: title,
        subtitle: "\(scopedItems.count.formatted()) items · \(scopedItems.reduce(Int64(0)) { $0 + $1.bytes }.storageFormatted)",
        onBack: onBack,
        icon: { headerIcon },
        trailing: AnyView(
          TextField("Search", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
        )
      )

      if case .chat = scope, presentCategories.count > 1 {
        Picker("Kind", selection: $categoryFilter) {
          Text("All").tag(StorageCategory?.none)
          ForEach(presentCategories) { Text($0.title).tag(StorageCategory?.some($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
      }

      table

      Divider()

      footer
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    .confirmationDialog(
      "Remove \(pendingRemoval.count == 1 ? "1 download" : "\(pendingRemoval.count.formatted()) downloads")?",
      isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    ) {
      Button("Remove \(pendingRemoval.reduce(Int64(0)) { $0 + $1.bytes }.storageFormatted)", role: .destructive) {
        let items = pendingRemoval
        Task {
          let result = await storage.remove(items)
          selection.removeAll()
          onFreed(result?.removedBytes ?? 0)
        }
      }
    } message: {
      Text("They stay in your chats.")
    }
  }

  private var table: some View {
    Table(rows, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Name", value: \.name) { row in
        HStack(spacing: 8) {
          StorageThumbnail(item: row.item, size: 24)
          Text(row.name).lineLimit(1).truncationMode(.middle)
          if let protection = row.item.protection {
            Text(protection.label)
              .font(.caption2.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
              .help("Kept while it’s needed")
          }
        }
      }
      TableColumn("Chat", value: \.chatTitle) { row in
        Text(row.chatTitle).lineLimit(1).foregroundStyle(.secondary)
      }
      TableColumn("Kind", value: \.kind) { row in
        Text(row.kind).foregroundStyle(.secondary)
      }
      .width(min: 60, ideal: 90)
      TableColumn("Date", value: \.date) { row in
        Text(row.date, format: .dateTime.day().month(.abbreviated).year()).foregroundStyle(.secondary)
      }
      .width(min: 80, ideal: 100)
      TableColumn("Size", value: \.bytes) { row in
        Text(row.bytes.storageFormatted)
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .width(min: 60, ideal: 80)
    }
    .contextMenu(forSelectionType: StorageItem.ID.self) { ids in
      Button("Open") { open(ids) }
      Button("Show in Finder") { reveal(ids) }
      Divider()
      Button("Remove Download…", role: .destructive) { pendingRemoval = removable(ids) }
        .disabled(removable(ids).isEmpty)
    } primaryAction: { ids in
      open(ids)
    }
    .onDeleteCommand { pendingRemoval = removable(selection) }
    .overlay {
      if rows.isEmpty {
        ContentUnavailableView(searchText.isEmpty ? "No Downloads" : "No Results", systemImage: searchText.isEmpty ? "tray" : "magnifyingglass")
      }
    }
    .animation(.smooth, value: rows.map(\.id))
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text(selectionSummary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText())
        .frame(maxWidth: .infinity, alignment: .leading)

      if !selection.isEmpty {
        Button("Show in Finder") { reveal(selection) }
      }

      let targets = selection.isEmpty ? rows.map(\.item).filter(\.isRemovable) : removable(selection)
      Button(selection.isEmpty ? "Remove All…" : "Remove…") { pendingRemoval = targets }
        .disabled(targets.isEmpty || storage.isClearing)

      Button("Done", action: onDone)
        .keyboardShortcut(.defaultAction)
    }
  }

  @ViewBuilder
  private var headerIcon: some View {
    switch scope {
      case let .category(category):
        StorageCategoryIcon(systemImage: category.systemImage, color: StorageCategoryStyle.color(category), size: 30)
      case let .chat(chatId):
        if let usage = storage.chat(chatId) {
          StorageChatIcon(usage: usage, size: 30)
        } else {
          StorageCategoryIcon(systemImage: "bubble.left.fill", color: .gray, size: 30)
        }
    }
  }

  // MARK: Data

  private var title: String {
    switch scope {
      case let .category(category): category.title
      case let .chat(chatId): storage.chat(chatId)?.title ?? "Chat"
    }
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

  private var rows: [StorageFileRow] {
    let titles = Dictionary(storage.chats.map { ($0.chatId, $0.title) }, uniquingKeysWith: { first, _ in first })
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return scopedItems
      .filter { categoryFilter == nil || $0.category == categoryFilter }
      .map { item in
        StorageFileRow(
          item: item,
          name: item.displayName,
          chatTitle: item.chatId.flatMap { titles[$0] } ?? "—",
          kind: item.category.title
        )
      }
      .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.chatTitle.localizedCaseInsensitiveContains(query) }
      .sorted(using: sortOrder)
  }

  private func removable(_ ids: Set<StorageItem.ID>) -> [StorageItem] {
    rows.filter { ids.contains($0.id) && $0.item.isRemovable }.map(\.item)
  }

  private var selectionSummary: String {
    let selected = rows.filter { selection.contains($0.id) }
    guard !selected.isEmpty else { return "\(rows.count.formatted()) items" }
    let bytes = selected.reduce(Int64(0)) { $0 + $1.bytes }
    return "\(selected.count.formatted()) of \(rows.count.formatted()) selected · \(bytes.storageFormatted)"
  }

  private func urls(_ ids: Set<StorageItem.ID>) -> [URL] {
    rows.filter { ids.contains($0.id) }.map(\.item.url)
  }

  private func open(_ ids: Set<StorageItem.ID>) {
    for url in urls(ids) { NSWorkspace.shared.open(url) }
  }

  private func reveal(_ ids: Set<StorageItem.ID>) {
    let urls = urls(ids)
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }
}

private extension StorageItem.Protection {
  var label: String {
    switch self {
      case .draft: "Draft"
      case .unsent: "Unsent"
      case .recent, .inUse: "In Use"
    }
  }
}

// MARK: - Auto-Download

private struct AutoDownloadLimitRow: View {
  let item: SettingsSearchItem
  let kind: AutoDownloadKind
  @Binding var value: Int

  var body: some View {
    LabeledContent {
      Picker(String(localized: item.title), selection: $value) {
        ForEach(AutoDownloadSettingsManager.sizeOptions(for: kind, including: value), id: \.self) { megabytes in
          Text(AutoDownloadSettingsManager.sizeLabel(megabytes)).tag(megabytes)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
    } label: {
      SettingsRowLabel(item)
    }
    .settingsSearchAnchor(item)
  }
}

#Preview {
  DataStorageSettingsDetailView()
}
