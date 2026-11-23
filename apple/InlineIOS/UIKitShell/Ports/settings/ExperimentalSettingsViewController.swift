import Auth
import InlineCompatUI
import InlineIOSFoundation
import InlineIOSUI
import InlineKit
import InlineMessageLayout
import UIKit

/// Experimental page (SwiftUI `ExperimentalView`), same purpose-based groups as macOS.
/// Every value lives in `UserDefaults.standard` under the keys the SwiftUI `@AppStorage` used.
@MainActor
final class ExperimentalSettingsViewController: SettingsFormViewController {
  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Experimental"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(Auth.shared.objectWillChange)
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let defaults = UserDefaults.standard
    let nativeDownloadsEnabled = defaults.bool(forKey: ExperimentalFeatureFlags.nativeFileDownloadsKey)
    let nativeDownloadsAvailable = Auth.shared.getIsLoggedIn()
    let nativeDownloadsFooter = Self.nativeDownloadsFooter(available: nativeDownloadsAvailable, enabled: nativeDownloadsEnabled)

    FormSection("files", header: String(localized: "Files"), footer: nativeDownloadsFooter) {
      FormRow.toggle(
        "nativeFileDownloads",
        String(localized: "Native File Downloads"),
        icon: .tile("arrow.down.doc", .systemBlue),
        isOn: nativeDownloadsEnabled,
        isEnabled: nativeDownloadsAvailable || nativeDownloadsEnabled
      ) { [weak self] isOn in
        defaults.set(isOn, forKey: ExperimentalFeatureFlags.nativeFileDownloadsKey)
        self?.setNeedsFormUpdate()
      }
    }

    FormSection(
      "messages",
      header: String(localized: "Messages"),
      footer: String(localized: "Holding a message opens Inline's menu, where you can select and quote part of the text. Turn it off to use the system menu. Reopen the chat after changing it.")
    ) {
      FormRow.toggle(
        "customContextMenu",
        String(localized: "Message Menu Text Selection"),
        icon: .tile("contextualmenu.and.cursorarrow", .systemIndigo),
        isOn: Self.bool(MessageContextMenuFeature.preferenceKey, default: true)
      ) { isOn in
        defaults.set(isOn, forKey: MessageContextMenuFeature.preferenceKey)
        if isOn { MessageContextMenuFeature.resetCrashGuard() }
      }
    }

    if SettingsBuildAudience.showsDebugTools {
      let album = defaults.string(forKey: MessageAlbumView.layoutStyleKey)
        .flatMap(AlbumLayoutStyle.init(rawValue:)) ?? .telegram
      FormSection(
        "developerTools",
        header: String(localized: "Developer Tools"),
        footer: String(localized: "The next message view is on by default. Turn it off to compare with the previous view. Album Layout picks how photos sent together are drawn in the next message view. Reopen the chat after changing either.")
      ) {
        FormRow.toggle(
          "timeline",
          String(localized: "New Message List"),
          icon: .tile("list.bullet.rectangle.fill", .systemPurple),
          isOn: Self.bool(TimelineFeature.preferenceKey, default: true)
        ) { isOn in
          defaults.set(isOn, forKey: TimelineFeature.preferenceKey)
        }
        FormRow.toggle(
          "nextMessageView",
          String(localized: "Next Message View"),
          icon: .tile("text.bubble.fill", .systemOrange),
          isOn: Self.bool(NextMessageViewFeature.preferenceKey, default: true)
        ) { isOn in
          defaults.set(isOn, forKey: NextMessageViewFeature.preferenceKey)
        }
        FormRow.navigation(
          "albumLayout",
          String(localized: "Album Layout"),
          value: album.title,
          icon: .tile("square.grid.2x2.fill", .systemTeal)
        ) { [weak self] in
          self?.push(SettingsPickerViewController(
            title: String(localized: "Album Layout"),
            footer: String(localized: "Reopen the chat after changing it."),
            // Islands are the Mac's minimal style.
            options: AlbumLayoutStyle.allCases.filter { $0 != .islands }.map {
              SettingsPickerOption(id: $0.rawValue, title: $0.title)
            },
            selectedID: {
              UserDefaults.standard.string(forKey: MessageAlbumView.layoutStyleKey) ?? AlbumLayoutStyle.telegram.rawValue
            },
            onSelect: { id, _ in
              UserDefaults.standard.set(id, forKey: MessageAlbumView.layoutStyleKey)
            }
          ))
        }
      }
    }
  }

  private static func nativeDownloadsFooter(available: Bool, enabled: Bool) -> String {
    if available {
      return String(localized: "Download documents and videos over the realtime connection. Other media use standard downloads. Turn off to use standard downloads for everything.")
    } else if enabled {
      return String(localized: "Sign in to use native file downloads. Turn off to clear the saved preference.")
    }
    return String(localized: "Sign in to use native file downloads.")
  }

  /// `@AppStorage` semantics: an unset key reads as `default`.
  private static func bool(_ key: String, default value: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? value
  }
}
