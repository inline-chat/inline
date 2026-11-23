import Combine
import Intents
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import UIKit

/// Privacy page (SwiftUI `PrivacySettingsView`): global search, time zone and Focus rules,
/// voice transcription.
@MainActor
final class PrivacySettingsViewController: SettingsFormViewController {
  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Privacy"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(INUserSettings.current.privacy.objectWillChange)
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let privacy = INUserSettings.current.privacy

    FormSection("search", footer: String(localized: "Allow other people to find you by username in global search.")) {
      FormRow.toggle(
        "globalSearch",
        String(localized: "Appear in Global Search"),
        icon: .tile("globe", .systemBlue),
        isOn: privacy.appearInGlobalSearch
      ) { isOn in
        privacy.appearInGlobalSearch = isOn
      }
    }

    FormSection("rules", footer: String(localized: "Choose who can see your local time and when a Focus silences your notifications.")) {
      FormRow.navigation(
        "timeZone",
        PrivacyRulePageKind.timeZone.title,
        value: privacy.effectiveTimeZoneRule.summary,
        icon: .tile("clock.fill", .systemOrange)
      ) { [weak self] in
        guard let self else { return }
        push(PrivacyRuleSettingsViewController(shell: shell, kind: .timeZone))
      }
      FormRow.navigation(
        "focusStatus",
        PrivacyRulePageKind.focusStatus.title,
        value: privacy.effectiveFocusStatusRule.summary,
        icon: .tile("moon.fill", .systemIndigo)
      ) { [weak self] in
        guard let self else { return }
        push(PrivacyRuleSettingsViewController(shell: shell, kind: .focusStatus))
      }
    }

    FormSection(
      "transcription",
      footer: String(localized: "Voice messages you send are transcribed by an AI service so people can read them. Turn this off to keep your recordings from being sent for transcription.")
    ) {
      FormRow.toggle(
        "transcribe",
        String(localized: "Transcribe Voice Messages"),
        icon: .tile("waveform", .systemPurple),
        isOn: privacy.transcribeVoiceMessages
      ) { isOn in
        privacy.transcribeVoiceMessages = isOn
      }
    }
  }
}

// MARK: - Rule page

/// Which privacy rule a page edits, with its wording (SwiftUI `PrivacyRuleKind`, iOS 17+ there).
enum PrivacyRulePageKind {
  case timeZone
  case focusStatus

  var title: String {
    switch self {
    case .timeZone: String(localized: "Time Zone")
    case .focusStatus: String(localized: "Focus Status")
    }
  }

  var pickerTitle: String {
    switch self {
    case .timeZone: String(localized: "Who Can See My Local Time")
    case .focusStatus: String(localized: "Who Can See My Focus Status")
    }
  }

  /// What the rule protects, finishing "won't see …" and "can see …".
  var subject: String {
    switch self {
    case .timeZone: String(localized: "your local time")
    case .focusStatus: String(localized: "when your notifications are silenced")
    }
  }
}

/// One privacy rule (SwiftUI `PrivacyRuleSettingsView`): automatic/manual time zone, audience,
/// exceptions and Focus permission. The exceptions editor is SwiftUI, so it opens on iOS 18+
/// only; earlier systems show the count.
@MainActor
final class PrivacyRuleSettingsViewController: SettingsFormViewController {
  private let kind: PrivacyRulePageKind

  init(shell: MainShellController, kind: PrivacyRulePageKind) {
    self.kind = kind
    super.init(shell: shell, title: kind.title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(INUserSettings.current.privacy.objectWillChange)
    if kind == .focusStatus {
      reloadOnChange(FocusStatusReporter.shared.$authorization)
    }
  }

  private var privacy: PrivacySettingsManager { INUserSettings.current.privacy }

  private var currentRule: PrivacyRuleValue {
    switch kind {
    case .timeZone: privacy.effectiveTimeZoneRule
    case .focusStatus: privacy.effectiveFocusStatusRule
    }
  }

  private func save(_ rule: PrivacyRuleValue) {
    switch kind {
    case .timeZone: privacy.setTimeZoneRule(rule)
    case .focusStatus: privacy.setFocusStatusRule(rule)
    }
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let privacy = self.privacy
    let rule = currentRule
    let kind = self.kind

    if kind == .timeZone, privacy.supportsManualTimeZone {
      FormSection(
        "timeZoneChoice",
        footer: String(localized: "Use the time zone of your iPhone or Mac. Turn this off to pick one yourself.")
      ) {
        FormRow.toggle(
          "automatic",
          String(localized: "Set Automatically"),
          isOn: privacy.manualTimeZone == nil
        ) { automatic in
          // Turning automatic off starts from the time zone this iPhone is in.
          privacy.setManualTimeZone(automatic ? nil : TimeZone.autoupdatingCurrent)
        }
        if let manual = privacy.manualTimeZone {
          FormRow.navigation("manual", String(localized: "Time Zone"), value: manual.pickerTitle) { [weak self] in
            self?.push(TimeZonePickerViewController(selection: manual) { timeZone in
              privacy.setManualTimeZone(timeZone)
            })
          }
        }
      }
    }

    FormSection(
      "audience",
      header: kind.pickerTitle,
      footer: kind == .focusStatus
        ? String(localized: "Shows “Notifications silenced” in direct messages when a Focus is on. Apple shares only whether a Focus is on, not which one.")
        : nil
    ) {
      FormRow.check("everyone", String(localized: "Everyone"), isSelected: rule.audience == .everyone) { [weak self] in
        self?.setAudience(.everyone)
      }
      FormRow.check("nobody", String(localized: "Nobody"), isSelected: rule.audience == .nobody) { [weak self] in
        self?.setAudience(.nobody)
      }
    }

    FormSection(
      "exceptions",
      header: String(localized: "Exceptions"),
      footer: rule.audience == .everyone
        ? String(localized: "Add people who shouldn’t see \(kind.subject).")
        : String(localized: "Add people who can see \(kind.subject).")
    ) {
      if SettingsBridgedPages.isAvailable {
        FormRow.navigation("exceptions", rule.exceptionsTitle, value: Self.exceptionsCount(rule)) { [weak self] in
          self?.editExceptions()
        }
      } else {
        FormRow.value("exceptions", rule.exceptionsTitle, value: Self.exceptionsCount(rule, editable: false))
      }
    }

    if kind == .focusStatus, privacy.sharesFocusStatus {
      focusAccessSection()
    }
  }

  private func setAudience(_ audience: PrivacyRuleValue.Audience) {
    var rule = currentRule
    guard rule.audience != audience else { return }
    CompatHaptics.selection()
    rule.audience = audience
    save(rule)
  }

  private func editExceptions() {
    guard #available(iOS 18.0, *) else { return }
    let rule = currentRule
    let kind = self.kind
    let controller = SettingsBridgedPages.privacyPeopleEditor(
      shell: shell,
      title: rule.exceptionsTitle,
      footer: rule.audience == .everyone
        ? String(localized: "These people won’t see \(kind.subject).")
        : String(localized: "Only these people will see \(kind.subject)."),
      selectedIDs: rule.exceptions
    ) { [weak self] ids in
      guard let self else { return }
      var updated = currentRule
      updated.exceptions = ids
      save(updated)
    }
    present(controller, animated: true)
  }

  /// Apple's own permission, needed before this iPhone can read Focus at all.
  private func focusAccessSection() -> [FormSection] {
    let reporter = FocusStatusReporter.shared
    switch reporter.authorization {
    case .authorized:
      return []
    case .notDetermined:
      return [FormSection("focusAccess", footer: String(localized: "Inline needs permission to read whether a Focus is on.")) {
        FormRow.button("allowFocus", String(localized: "Allow Focus Access")) {
          Task { await reporter.requestAuthorization() }
        }
      }]
    default:
      return [FormSection("focusAccess", footer: String(localized: "Turn on Focus for Inline in Settings to share it from this iPhone.")) {
        FormRow.button("openSettings", String(localized: "Open Settings")) {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
      }]
    }
  }

  private static func exceptionsCount(_ rule: PrivacyRuleValue, editable: Bool = true) -> String {
    let count = rule.exceptions.count
    if count == 0 { return editable ? String(localized: "Add") : String(localized: "None") }
    return count == 1 ? String(localized: "1 person") : String(localized: "\(count) people")
  }
}

// MARK: - Time zone picker

/// Searchable list of every time zone (SwiftUI `TimeZonePickerList`, whose entries are internal
/// to InlineUI, so the names are rebuilt here the same way).
@MainActor
final class TimeZonePickerViewController: FormViewController, UISearchResultsUpdating {
  private struct Entry {
    let timeZone: TimeZone
    let city: String
    let detail: String
    let searchText: String
  }

  private static let entries: [Entry] = TimeZone.knownTimeZoneIdentifiers.compactMap { identifier in
    // Skip aliases like "GMT" and "UTC" without a region; keep real places.
    guard identifier.contains("/"), let timeZone = TimeZone(identifier: identifier) else { return nil }
    let city = (identifier.split(separator: "/").last.map(String.init) ?? identifier)
      .replacingOccurrences(of: "_", with: " ")
    let region = identifier.split(separator: "/").first.map(String.init) ?? ""
    let name = timeZone.localizedName(for: .generic, locale: .current) ?? ""
    let detail = name.isEmpty ? region : "\(name) · \(region)"
    return Entry(timeZone: timeZone, city: city, detail: detail, searchText: "\(city) \(identifier) \(name)")
  }
  .sorted { $0.city.localizedStandardCompare($1.city) == .orderedAscending }

  private let selection: TimeZone
  private let onSelect: @MainActor (TimeZone) -> Void
  private let searchController = UISearchController(searchResultsController: nil)
  private var query = ""

  init(selection: TimeZone, onSelect: @escaping @MainActor (TimeZone) -> Void) {
    self.selection = selection
    self.onSelect = onSelect
    super.init(style: .insetGrouped)
    title = String(localized: "Time Zone")
    navigationItem.largeTitleDisplayMode = .never
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = String(localized: "Search cities or time zones")
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
  }

  func updateSearchResults(for searchController: UISearchController) {
    let text = searchController.searchBar.text ?? ""
    guard text != query else { return }
    query = text
    setNeedsFormUpdate()
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = trimmed.isEmpty
      ? Self.entries
      : Self.entries.filter { $0.searchText.localizedStandardContains(trimmed) }
    let now = Date()

    FormSection("zones") {
      for entry in filtered {
        FormRow.check(
          entry.timeZone.identifier,
          entry.city,
          subtitle: "\(Self.offset(entry.timeZone, at: now)) · \(entry.detail)",
          isSelected: entry.timeZone.identifier == selection.identifier
        ) { [weak self] in
          guard let self else { return }
          CompatHaptics.selection()
          onSelect(entry.timeZone)
          if searchController.isActive { searchController.isActive = false }
          navigationController?.popViewController(animated: true)
        }
      }
      if filtered.isEmpty {
        FormRow.note("empty", String(localized: "No time zones found"))
      }
    }
  }

  private static func offset(_ timeZone: TimeZone, at date: Date) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    guard seconds != 0 else { return "GMT" }
    let sign = seconds > 0 ? "+" : "-"
    let hours = abs(seconds) / 3_600
    let minutes = (abs(seconds) % 3_600) / 60
    return minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT\(sign)%d:%02d", hours, minutes)
  }
}
