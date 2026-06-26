import AppKit
import Foundation
import Logger
import Observation

@MainActor
@Observable
public final class MacDevtoolsLogStore {
  public var entries: [LogEntry] = []
  public var filter = ""
  public var minimumLevel: LogLevel = .trace
  public var follow = true
  public var selectedIDs: Set<LogEntry.ID> = []
  public var focusedEntryID: LogEntry.ID?
  public var captureEnabled: Bool
  public var statusMessage: String?

  @ObservationIgnored private let reader = MacDevtoolsLogReader()
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  private let maxVisibleEntries = 5_000

  public init() {
    captureEnabled = MacDevtoolsLogCapture.shared.isEnabled
  }

  public var filteredEntries: [LogEntry] {
    let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let minPriority = minimumLevel.macDevtoolsPriority

    return entries.filter { entry in
      guard entry.level.macDevtoolsPriority >= minPriority else { return false }
      guard query.isEmpty == false else { return true }

      return entry.level.rawValue.lowercased().contains(query)
        || entry.scope.lowercased().contains(query)
        || entry.message.lowercased().contains(query)
        || entry.fileName.lowercased().contains(query)
        || entry.function.lowercased().contains(query)
    }
  }

  public var selectedEntry: LogEntry? {
    let entries = selectedEntries
    if let focusedEntryID,
       let entry = entries.first(where: { $0.id == focusedEntryID })
    {
      return entry
    }

    return entries.first
  }

  public var selectedEntries: [LogEntry] {
    guard selectedIDs.isEmpty == false else { return [] }
    return filteredEntries.filter { selectedIDs.contains($0.id) }
  }

  public var countText: String {
    let filteredCount = filteredEntries.count
    guard filteredCount != entries.count else {
      return "\(entries.count) logs"
    }
    return "\(filteredCount) of \(entries.count) logs"
  }

  public func start() {
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      await self?.refresh()

      while Task.isCancelled == false {
        try? await Task.sleep(for: .milliseconds(500))
        await self?.refresh()
      }
    }
  }

  public func stop() {
    refreshTask?.cancel()
    refreshTask = nil
  }

  public func setCaptureEnabled(_ enabled: Bool) {
    captureEnabled = enabled
    MacDevtoolsLogCapture.shared.setEnabled(enabled)
    Task { [weak self] in
      await self?.reader.reset()
      await self?.refresh(resetExisting: true)
    }
  }

  public func updateSelectionFocus() {
    let entries = selectedEntries
    guard entries.isEmpty == false else {
      focusedEntryID = nil
      return
    }

    if let focusedEntryID,
       entries.contains(where: { $0.id == focusedEntryID })
    {
      return
    }

    focusedEntryID = entries.first?.id
  }

  public func exportReport() {
    Task { [weak self] in
      guard let self else { return }

      do {
        let url = try MacDevtoolsReportExporter.export()
        statusMessage = "Exported \(url.lastPathComponent)"
      } catch MacDevtoolsReportExporter.ExportError.cancelled {
        return
      } catch {
        statusMessage = "Export failed: \(error.localizedDescription)"
      }
    }
  }

  public func copySelectedEntries() {
    let entries = selectedEntries
    guard entries.isEmpty == false else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      entries.map { rawText(for: $0) }.joined(separator: "\n\n"),
      forType: .string
    )
    statusMessage = entries.count == 1 ? "Copied selected log" : "Copied \(entries.count) selected logs"
  }

  public func copyFilteredEntries() {
    let entries = filteredEntries
    guard entries.isEmpty == false else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      entries.map { rawText(for: $0) }.joined(separator: "\n\n"),
      forType: .string
    )
    statusMessage = "Copied \(entries.count) visible logs"
  }

  public func rawText(for entry: LogEntry) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    guard let data = try? encoder.encode(entry),
          let string = String(data: data, encoding: .utf8)
    else {
      return entry.consoleMessage
    }

    return string
  }

  private func refresh(resetExisting: Bool = false) async {
    guard let url = MacDevtools.logFileURL else { return }

    do {
      let result = try await reader.readNewEntries(from: url)
      if resetExisting || result.didReset {
        entries = []
        selectedIDs = []
        focusedEntryID = nil
      }
      guard result.entries.isEmpty == false else { return }

      entries.append(contentsOf: result.entries)
      if entries.count > maxVisibleEntries {
        entries.removeFirst(entries.count - maxVisibleEntries)
      }
      pruneSelection()
    } catch {
      statusMessage = "Read failed: \(error.localizedDescription)"
    }
  }

  private func pruneSelection() {
    let ids = Set(entries.map(\.id))
    selectedIDs.formIntersection(ids)

    if let focusedEntryID,
       selectedIDs.contains(focusedEntryID)
    {
      return
    }

    focusedEntryID = selectedIDs.first
  }
}
