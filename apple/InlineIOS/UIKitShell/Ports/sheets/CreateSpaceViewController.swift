import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import Logger
import UIKit

/// UIKit port of `CreateSpace` (apple/InlineIOS/Sheets/CreateSpace.swift): optional emoji and a
/// name, created with `DataManager.createSpace`. The photo picker is not ported.
@MainActor
final class CreateSpaceViewController: FormViewController {
  private unowned let shell: MainShellController
  private let onCreated: (Int64) -> Void

  // Field edits re-render (no visible change) so a re-dequeued field cell gets current text.
  private var name = "" { didSet { if name != oldValue { updateCreateItem(); setNeedsFormUpdate() } } }
  private var emoji = "" { didSet { if emoji != oldValue { setNeedsFormUpdate() } } }
  private var isLoading = false {
    didSet {
      updateCreateItem()
      setNeedsFormUpdate()
    }
  }

  private var errorMessage: String? { didSet { setNeedsFormUpdate() } }
  private var didFocus = false

  init(shell: MainShellController, onCreated: @escaping (Int64) -> Void) {
    self.shell = shell
    self.onCreated = onCreated
    super.init(style: .insetGrouped)
    title = String(localized: "Create Space")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The sheet to present for `Sheet.createSpace` (medium and large detents, as before).
  static func makeSheet(shell: MainShellController, onCreated: @escaping (Int64) -> Void) -> UIViewController {
    ShellSheetSupport.wrap(
      CreateSpaceViewController(shell: shell, onCreated: onCreated),
      shell: shell,
      detents: [.medium, .large]
    )
  }

  override func registerCells(in tableView: UITableView) {
    tableView.register(SheetEmojiTitleCell.self, forCellReuseIdentifier: SheetEmojiTitleCell.reuseIdentifier)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    if isModalRoot {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        systemItem: .cancel,
        primaryAction: UIAction { [weak self] _ in self?.cancel() }
      )
    }
    updateCreateItem()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didFocus else { return }
    didFocus = true
    focusName()
  }

  /// Root of its own (sheet) navigation controller, as opposed to pushed on a tab stack.
  private var isModalRoot: Bool {
    navigationController?.viewControllers.first === self
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func updateCreateItem() {
    guard isViewLoaded else { return }
    if isLoading {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      spinner.accessibilityLabel = String(localized: "Creating Space")
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    } else {
      let create = UIBarButtonItem(
        title: String(localized: "Create"),
        primaryAction: UIAction { [weak self] _ in self?.submit() }
      )
      create.style = .done
      create.isEnabled = !trimmedName.isEmpty
      navigationItem.rightBarButtonItem = create
    }
    navigationItem.leftBarButtonItem?.isEnabled = !isLoading
    isModalInPresentation = isLoading
    navigationController?.isModalInPresentation = isLoading
  }

  // MARK: Form

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    FormSection(
      "name",
      footer: String(localized: "Choose a short name and an optional emoji. You can change both later.")
    ) {
      FormRow.emojiTitle(
        "emoji-name",
        emoji: emoji,
        title: name,
        placeholder: String(localized: "Space name"),
        autocapitalization: .words,
        isEnabled: !isLoading,
        onEmojiChange: { [weak self] value in self?.emoji = value },
        onTitleChange: { [weak self] value in self?.name = value },
        onSubmit: { [weak self] in self?.submit() }
      )
    }

    if let errorMessage {
      FormSection("error") {
        FormRow.value(
          "error",
          errorMessage,
          value: nil,
          icon: FormIcon(systemName: "exclamationmark.triangle.fill", tint: .systemRed)
        )
      }
    }
  }

  private func focusName() {
    guard let indexPath = indexPath(forRow: "emoji-name", inSection: "name"),
          let cell = tableView.cellForRow(at: indexPath) as? SheetEmojiTitleCell
    else { return }
    cell.titleField.becomeFirstResponder()
  }

  // MARK: Actions

  private func submit() {
    let spaceName = trimmedName
    guard !spaceName.isEmpty, !isLoading else { return }
    view.endEditing(true)
    errorMessage = nil
    isLoading = true
    let displayName = emoji.isEmpty ? spaceName : "\(emoji) \(spaceName)"
    Task { [weak self] in
      guard let self else { return }
      do {
        let id = try await shell.data.createSpace(name: displayName, photoData: nil)
        isLoading = false
        if let id { onCreated(id) }
        finish()
      } catch {
        Log.shared.error("Failed to create space", error: error)
        isLoading = false
        errorMessage = error.localizedDescription
      }
    }
  }

  private func cancel() {
    guard !isLoading else { return }
    finish()
  }

  /// Closes the sheet, or pops when pushed as `Destination.createSpace`.
  private func finish() {
    if isModalRoot {
      closeShellSheet(shell)
    } else if let navigation = navigationController, navigation.viewControllers.count > 1 {
      navigation.popViewController(animated: true)
    }
  }
}
