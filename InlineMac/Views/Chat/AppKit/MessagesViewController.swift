// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

protocol MessagesViewControllerDelegate: AnyObject {
  func messagesViewController(_ controller: MessagesViewController, didSelectMessages selectedIds: Set<UUID>)
  func messagesViewController(_ controller: MessagesViewController, didCopyText text: String)
}

final class MessagesViewController: NSViewController {
  weak var delegate: MessagesViewControllerDelegate?
  private var messages: [FullMessage] = []
  private var selectedIds: Set<UUID> = []
  private var updateTimer: Timer?
  private var pendingMessages: [FullMessage] = []
  
  private lazy var collectionView: NSCollectionView = {
    let view = NSCollectionView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.collectionViewLayout = createLayout()
    view.isSelectable = true
    view.allowsMultipleSelection = true
    view.register(MessageCell.self, forItemWithIdentifier: .init(MessageCell.reuseIdentifier))
    view.dataSource = self
    view.delegate = self
    view.wantsLayer = true
    return view
  }()
  
  private lazy var scrollView: NSScrollView = {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.backgroundColor = .clear
    scroll.documentView = collectionView
    scroll.wantsLayer = true
    return scroll
  }()
  
  override func loadView() {
    view = NSView()
    view.wantsLayer = true
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    setupViews()
    
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }
  
  private func setupViews() {
    view.addSubview(scrollView)
    
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
  }
  
  private func createLayout() -> NSCollectionViewFlowLayout {
    let layout = NSCollectionViewFlowLayout()
    layout.scrollDirection = .vertical
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 1
    layout.sectionInset = .init(top: 0, left: 0, bottom: 0, right: 0)
    
    // Make items full width
    if let width = view.window?.contentView?.frame.width {
      layout.itemSize = NSSize(width: width, height: 44)
    }
    return layout
  }
  
  override func viewDidLayout() {
    super.viewDidLayout()
    // Update layout when view size changes
    if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
      layout.itemSize = NSSize(width: view.bounds.width, height: 44)
      layout.invalidateLayout()
    }
  }
  
  func update(with messages: [FullMessage]) {
    pendingMessages = messages
    
    updateTimer?.invalidate()
    updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
      self?.applyPendingUpdates()
    }
  }
  
  private var isFirstRender = true
  
  private func applyPendingUpdates() {
    let oldMessages = messages
    messages = pendingMessages
    
    let differences = pendingMessages.difference(from: oldMessages) { $0.id == $1.id }
    
    collectionView.performBatchUpdates {
      for change in differences {
        switch change {
        case .insert(let offset, _, _):
          collectionView.insertItems(at: [IndexPath(item: offset, section: 0)])
        case .remove(let offset, _, _):
          collectionView.deleteItems(at: [IndexPath(item: offset, section: 0)])
        }
      }
    } completionHandler: { [weak self] _ in
      if self?.messages.count ?? 0 > oldMessages.count {
        print("render completed")
        if self?.isFirstRender == true {
          self?.scrollToBottom(animated: false)
          self?.isFirstRender = false
        } else {
          self?.scrollToBottom(animated: true)
        }
      }
    }
  }

  private func scrollToBottom(animated: Bool = true) {
    guard !messages.isEmpty else { return }
    
    // Since the collection view is flipped, scroll to bottom means scrolling to the last item
    let lastIndex = IndexPath(item: messages.count - 1, section: 0)
    
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        context.allowsImplicitAnimation = true
        self.collectionView.scrollToItems(
          at: [lastIndex],
          scrollPosition: .bottom
        )
      }
    } else {
      collectionView.scrollToItems(
        at: [lastIndex],
        scrollPosition: .bottom
      )
    }
  }
}

extension MessagesViewController: NSCollectionViewDataSource {
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    messages.count
  }
  
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = collectionView.makeItem(withIdentifier: .init(MessageCell.reuseIdentifier), for: indexPath)
    guard let cell = item as? MessageCell else { return item }
    cell.configure(with: messages[indexPath.item])
    return cell
  }
}

extension MessagesViewController: NSCollectionViewDelegateFlowLayout {
  func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
    // Let auto layout determine the size
    NSSize(width: collectionView.bounds.width, height: 44)
  }
}
