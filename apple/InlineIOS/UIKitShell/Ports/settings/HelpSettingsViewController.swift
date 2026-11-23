import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import RealtimeV2
import UIKit

/// Help page (SwiftUI `HelpSettingsView`): community actions, resources (with a UIKit What's New
/// page), version and legal links.
@MainActor
final class HelpSettingsViewController: SettingsFormViewController {
  private enum PendingAction: Equatable {
    case townHall
    case founderDM
  }

  private var pending: PendingAction?

  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Help"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let isBusy = pending != nil

    FormSection("community", header: String(localized: "Community")) {
      FormRow.action(
        "townHall",
        String(localized: "Join Town Hall"),
        subtitle: String(localized: "Community space"),
        icon: FormIcon(systemName: "person.3", tint: .secondaryLabel),
        role: .normal,
        isEnabled: !isBusy,
        isLoading: pending == .townHall
      ) { [weak self] in
        self?.perform(.townHall)
      }
      FormRow.action(
        "founderDM",
        String(localized: "Message Mo"),
        value: "@mo",
        icon: FormIcon(systemName: "bubble.left", tint: .secondaryLabel),
        role: .normal,
        isEnabled: !isBusy,
        isLoading: pending == .founderDM
      ) { [weak self] in
        self?.perform(.founderDM)
      }
    }

    FormSection("resources", header: String(localized: "Resources")) {
      link("docs", String(localized: "Docs"), subtitle: String(localized: "Guides and setup"), symbol: "book.closed", url: "https://inline.chat/docs")
      if WhatsNewStore.shared.announcement != nil {
        FormRow.navigation(
          "whatsNew",
          String(localized: "What’s New"),
          icon: FormIcon(systemName: "sparkles", tint: .secondaryLabel)
        ) { [weak self] in
          guard let self, let announcement = WhatsNewStore.shared.announcement else { return }
          push(WhatsNewSettingsViewController(announcement: announcement))
        }
      } else {
        link("whatsNew", String(localized: "What’s New"), symbol: "sparkles", url: WhatsNewAnnouncement.changelogURL.absoluteString)
      }
      link("website", String(localized: "Website"), value: "inline.chat", symbol: "globe", url: "https://inline.chat")
      link(
        "github",
        String(localized: "GitHub"),
        value: "inline-chat",
        symbol: "chevron.left.forwardslash.chevron.right",
        url: "https://github.com/inline-chat"
      )
      link("x", String(localized: "Updates on X"), value: "@inline_chat", symbol: "at", url: "https://x.com/inline_chat")
      link("status", String(localized: "Status"), symbol: "waveform.path.ecg", url: "https://status.inline.chat")
    }

    FormSection("about", header: String(localized: "About")) {
      FormRow.value("version", String(localized: "Version"), value: "\(SettingsAppInfo.version) (\(SettingsAppInfo.build))")
    }

    FormSection("legal", header: String(localized: "Legal")) {
      link("terms", String(localized: "Terms of Service"), symbol: "doc.text", url: "https://inline.chat/legal/terms")
      link("privacy", String(localized: "Privacy Policy"), symbol: "hand.raised", url: "https://inline.chat/legal/privacy")
    }
  }

  private func link(
    _ id: String,
    _ title: String,
    subtitle: String? = nil,
    value: String? = nil,
    symbol: String,
    url: String
  ) -> FormRow {
    FormRow.action(
      id,
      title,
      subtitle: subtitle,
      value: value,
      icon: FormIcon(systemName: symbol, tint: .secondaryLabel),
      role: .normal
    ) { [weak self] in
      self?.open(url)
    }
  }

  // MARK: Community

  private func perform(_ action: PendingAction) {
    guard pending == nil else { return }
    pending = action
    setNeedsFormUpdate()
    Task { [weak self] in
      do {
        switch action {
        case .townHall:
          let result = try await Api.realtime.send(.joinPublicSpace(handle: "townhall"))
          guard case let .joinPublicSpace(response) = result else { throw HelpActionError.invalidResponse }
          guard let self else { return }
          let shell = shell
          closeSettings()
          shell.selectSpace(response.space.id)

        case .founderDM:
          let userID = getDenaOrMoUserId(username: "mo")
          guard userID > 0 else { throw HelpActionError.invalidResponse }
          let peer = Peer.user(id: userID)
          _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))
          guard let self else { return }
          let shell = shell
          closeSettings()
          shell.router.openPrimaryDestination(.chat(peer: peer))
        }
      } catch is CancellationError {
      } catch {
        self?.presentAlert(
          title: String(localized: "Couldn’t Complete Action"),
          message: action == .townHall
            ? String(localized: "Couldn’t join Town Hall. Please try again.")
            : String(localized: "Couldn’t start a DM with @mo. Please try again.")
        )
      }
      self?.pending = nil
      self?.setNeedsFormUpdate()
    }
  }

  private enum HelpActionError: Error {
    case invalidResponse
  }
}

/// UIKit What's New (SwiftUI `WhatsNewView` is iOS 17+): the bundled highlights, a link to the
/// full changelog, and marks the announcement seen like the sheet does.
@MainActor
final class WhatsNewSettingsViewController: FormViewController {
  private let announcement: WhatsNewAnnouncement

  init(announcement: WhatsNewAnnouncement) {
    self.announcement = announcement
    super.init(style: .insetGrouped)
    title = String(localized: "What’s New")
    navigationItem.largeTitleDisplayMode = .never
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    WhatsNewStore.shared.markSeen()
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    FormSection("items", header: String(localized: "What’s New in Inline")) {
      for item in announcement.itemsForCurrentPlatform {
        FormRow.value(
          "item-\(item.id)",
          item.title,
          value: nil,
          subtitle: item.detail,
          icon: .tile(item.systemImage, .systemBlue)
        )
      }
    }
    FormSection("changelog") {
      FormRow.action(
        "changelog",
        String(localized: "Full Changelog"),
        icon: FormIcon(systemName: "doc.text.magnifyingglass", tint: .secondaryLabel),
        role: .normal
      ) {
        UIApplication.shared.open(WhatsNewAnnouncement.changelogURL)
      }
    }
  }
}
