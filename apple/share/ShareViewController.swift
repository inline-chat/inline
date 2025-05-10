import Logger
import MobileCoreServices
import MultipartFormDataKit
import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
  private let log = Log.scoped("ShareViewController")
  private let state = ShareState()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.2)

    let sheetContainerView = UIView()
    sheetContainerView.translatesAutoresizingMaskIntoConstraints = false
    sheetContainerView.backgroundColor = .clear
    sheetContainerView.layer.cornerRadius = 24
    sheetContainerView.layer.maskedCorners = [
      .layerMinXMinYCorner, // Top Left
      .layerMaxXMinYCorner, // Top Right
      .layerMinXMaxYCorner, // Bottom Left
      .layerMaxXMaxYCorner, // Bottom Right
    ]
    sheetContainerView.layer.masksToBounds = true
    sheetContainerView.layer.shadowColor = UIColor.black.cgColor
    sheetContainerView.layer.shadowOpacity = 0.2
    sheetContainerView.layer.shadowOffset = CGSize(width: 0, height: -4)
    sheetContainerView.layer.shadowRadius = 12

    view.addSubview(sheetContainerView)

    let shareView = ShareView()
      .environmentObject(state)
      .environment(\.extensionContext, extensionContext)
    let hostingController = UIHostingController(rootView: shareView)
    addChild(hostingController)
    sheetContainerView.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: sheetContainerView.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: sheetContainerView.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: sheetContainerView.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: sheetContainerView.bottomAnchor),
    ])

    let sheetHeight: CGFloat = 480
    let bottomConstraint = sheetContainerView.bottomAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.bottomAnchor,
      constant: sheetHeight
    )
    NSLayoutConstraint.activate([
      sheetContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      sheetContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      sheetContainerView.heightAnchor.constraint(equalToConstant: sheetHeight),
      bottomConstraint,
    ])
    view.layoutIfNeeded()

    UIView.animate(
      withDuration: 0.32,
      delay: 0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0.7,
      options: [.curveEaseOut]
    ) {
      bottomConstraint.constant = 0
      self.view.layoutIfNeeded()
    }

    loadSharedImages()
  }

  private func loadSharedImages() {
    guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
      return
    }

    let group = DispatchGroup()

    for extensionItem in extensionItems {
      guard let attachments = extensionItem.attachments else { continue }

      for attachment in attachments {
        // For iOS 14+
        if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
          group.enter()

          attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, _ in
            defer { group.leave() }

            if let imageURL = data as? URL {
              if let imageData = try? Data(contentsOf: imageURL),
                 let image = UIImage(data: imageData)
              {
                DispatchQueue.main.async {
                  self?.state.sharedImages.append(image)
                }
              }
            } else if let image = data as? UIImage {
              DispatchQueue.main.async {
                self?.state.sharedImages.append(image)
              }
            }
          }
        } else if attachment.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
          group.enter()

          attachment.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { [weak self] data, _ in
            defer { group.leave() }

            if let imageURL = data as? URL,
               let imageData = try? Data(contentsOf: imageURL),
               let image = UIImage(data: imageData)
            {
              DispatchQueue.main.async {
                self?.state.sharedImages.append(image)
              }
            } else if let image = data as? UIImage {
              DispatchQueue.main.async {
                self?.state.sharedImages.append(image)
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - Chat Selector Delegate

extension ShareViewController: ChatSelectorDelegate {
  func didSelectChat(_ chat: SharedChat) {}
}

// MARK: - Chat Selector View Controller

protocol ChatSelectorDelegate: AnyObject {
  func didSelectChat(_ chat: SharedChat)
}

class ChatSelectorViewController: UITableViewController {
  weak var delegate: ChatSelectorDelegate?
  var sharedData: SharedData?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Select Chat"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel,
      target: self,
      action: #selector(cancelTapped)
    )

    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ChatCell")
  }

  @objc private func cancelTapped() {
    dismiss(animated: true)
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sharedData?.shareExtensionData.first?.chats.count ?? 0
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "ChatCell", for: indexPath)

    if let chat = sharedData?.shareExtensionData.first?.chats[indexPath.row] {
      if !chat.title.isEmpty {
        // Thread chat - use title
        cell.textLabel?.text = chat.title
      } else if let peerUserId = chat.peerUserId,
                let userData = sharedData?.shareExtensionData.first?.users.first(where: { $0.id == peerUserId })
      {
        // Private chat - use user's first name
        cell.textLabel?.text = userData.firstName
      } else {
        cell.textLabel?.text = "Unknown"
      }
    }

    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if let chat = sharedData?.shareExtensionData.first?.chats[indexPath.row] {
      delegate?.didSelectChat(chat)
      dismiss(animated: true)
    }
  }
}
