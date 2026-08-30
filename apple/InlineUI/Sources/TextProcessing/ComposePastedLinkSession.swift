import Foundation

/// One per editor. Replaces the single pasted-URL state with bounded, cancellable occurrences.
/// The editor remains responsible for native text mutation, undo, draft persistence and styling.
@MainActor
public final class ComposePastedLinkSession {
  public typealias Snapshot = (text: NSAttributedString, selection: NSRange)
  public typealias Resolve = @MainActor (String) async throws -> String?
  public typealias Replace = (NSRange, NSAttributedString, NSRange, String) -> Bool

  private struct Occurrence {
    let id = UUID()
    let url: String
    let original: NSAttributedString
    let resolve: Resolve
    var range: NSRange
    var label: String?
  }

  private struct Request: Sendable {
    let id: UUID
    let task: Task<Void, Never>
  }

  private let snapshot: () -> Snapshot?
  private let replace: Replace
  private let availabilityChanged: (Bool) -> Void
  private var occurrences: [Occurrence] = []
  private var requests: [String: Request] = [:]
  private var isReplacing = false
  private let occurrenceLimit = 8
  private let concurrencyLimit = 3

  public var canRevert: Bool { !occurrences.isEmpty }

  public init(
    snapshot: @escaping () -> Snapshot?,
    replace: @escaping Replace,
    availabilityChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.snapshot = snapshot
    self.replace = replace
    self.availabilityChanged = availabilityChanged
  }

  deinit {
    for request in requests.values { request.task.cancel() }
  }

  public func pasted(links: [LinkMatch], resolve: @escaping Resolve) {
    validate()
    guard let snapshot = snapshot() else { return }
    for link in links {
      guard let scheme = link.url.scheme?.lowercased(), ["https", "http"].contains(scheme),
            NSMaxRange(link.range) <= snapshot.text.length,
            !occurrences.contains(where: { NSIntersectionRange($0.range, link.range).length > 0 })
      else { continue }
      occurrences.append(Occurrence(
        url: link.url.absoluteString,
        original: snapshot.text.attributedSubstring(from: link.range),
        resolve: resolve,
        range: link.range
      ))
    }
    if occurrences.count > occurrenceLimit { occurrences.removeFirst(occurrences.count - occurrenceLimit) }
    changed()
    startRequests()
  }

  public func willChange(range: NSRange, replacement: String) {
    guard !isReplacing, !occurrences.isEmpty else { return }
    updateRanges(range: range, replacement: replacement)
    changed()
    startRequests()
  }

  public func validate() {
    guard !isReplacing, !occurrences.isEmpty else { return }
    guard let snapshot = snapshot() else { reset(); return }
    occurrences.removeAll { occurrence in
      guard occurrence.range.location >= 0, NSMaxRange(occurrence.range) <= snapshot.text.length else { return true }
      return (snapshot.text.string as NSString).substring(with: occurrence.range)
        != (occurrence.label ?? occurrence.original.string)
    }
    changed()
    startRequests()
  }

  public func reset() {
    guard !occurrences.isEmpty || !requests.isEmpty else { return }
    occurrences.removeAll()
    for request in requests.values { request.task.cancel() }
    requests.removeAll()
    availabilityChanged(false)
  }

  @discardableResult
  public func revertLatest() -> Bool {
    validate()
    guard let occurrence = occurrences.last else { return false }
    return revert(occurrence)
  }

  @discardableResult
  public func revertAtCaret() -> Bool {
    validate()
    guard let selection = snapshot()?.selection, selection.length == 0,
          let occurrence = occurrences.last(where: { $0.label != nil && NSMaxRange($0.range) == selection.location })
    else { return false }
    return revert(occurrence)
  }

  private func revert(_ occurrence: Occurrence) -> Bool {
    if occurrence.label != nil {
      guard apply(occurrence, replacement: occurrence.original, action: "Restore Link") else { return false }
    }
    occurrences.removeAll { $0.id == occurrence.id }
    changed()
    startRequests()
    return true
  }

  private func startRequests() {
    for occurrence in occurrences where occurrence.label == nil {
      guard requests.count < concurrencyLimit else { break }
      guard requests[occurrence.url] == nil else { continue }
      let id = UUID()
      let url = occurrence.url
      let resolve = occurrence.resolve
      let task = Task { @MainActor [weak self] in
        let label: String?
        do { label = try await resolve(url) } catch { label = nil }
        guard !Task.isCancelled else { return }
        self?.finished(url: url, requestID: id, label: label)
      }
      requests[url] = Request(id: id, task: task)
    }
  }

  private func finished(url: String, requestID: UUID, label: String?) {
    guard requests[url]?.id == requestID else { return }
    validate()
    // Work from the end so replacing one occurrence cannot invalidate earlier ranges.
    let pending = occurrences.filter { $0.url == url && $0.label == nil }.sorted { $0.range.location > $1.range.location }
    for occurrence in pending {
      let label = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !label.isEmpty, label != occurrence.original.string, let current = snapshot(),
         ComposeLinkPaste.links(in: current.text, range: occurrence.range).contains(where: {
           $0.range == occurrence.range && $0.url.absoluteString == occurrence.url
         })
      {
        var attributes = current.text.attributes(at: occurrence.range.location, effectiveRange: nil)
        attributes[.link] = occurrence.url
        let replacement = NSAttributedString(string: label, attributes: attributes)
        if apply(occurrence, replacement: replacement, action: "Replace Link"),
           let index = occurrences.firstIndex(where: { $0.id == occurrence.id })
        {
          occurrences[index].range.length = replacement.length
          occurrences[index].label = label
          continue
        }
      }
      occurrences.removeAll { $0.id == occurrence.id }
    }
    requests.removeValue(forKey: url)
    changed()
    startRequests()
  }

  private func apply(_ occurrence: Occurrence, replacement: NSAttributedString, action: String) -> Bool {
    guard let snapshot = snapshot() else { return false }
    let selection = ComposeLinkPaste.selectionAfterReplacing(
      occurrence.range, length: replacement.length, selection: snapshot.selection
    )
    isReplacing = true
    defer { isReplacing = false }
    guard replace(occurrence.range, replacement, selection, action) else { return false }
    updateRanges(range: occurrence.range, replacement: replacement.string, excluding: occurrence.id)
    return true
  }

  private func updateRanges(range: NSRange, replacement: String, excluding id: UUID? = nil) {
    occurrences = occurrences.compactMap { value in
      var occurrence = value
      if occurrence.id == id { return occurrence }
      if NSMaxRange(range) <= occurrence.range.location {
        occurrence.range.location += replacement.utf16.count - range.length
        return occurrence
      }
      if range.location >= NSMaxRange(occurrence.range) {
        // Appending a query/path edits the pending URL even though the insertion is at its boundary.
        if occurrence.label == nil, range.location == NSMaxRange(occurrence.range),
           let first = replacement.first, !first.isWhitespace { return nil }
        return occurrence
      }
      return nil
    }
  }

  private func changed() {
    let pendingURLs = Set(occurrences.filter { $0.label == nil }.map(\.url))
    for url in Array(requests.keys) where !pendingURLs.contains(url) {
      requests.removeValue(forKey: url)?.task.cancel()
    }
    availabilityChanged(!occurrences.isEmpty)
  }
}
