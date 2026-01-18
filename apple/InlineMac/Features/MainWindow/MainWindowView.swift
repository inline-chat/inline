//
//  MainWindowView.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 10/19/25.
//

import AppKit
import InlineMacWindow

class MainWindowView: NSViewController {
  override func loadView() {
    view = MainWindowRootView()
  }

  private var currentViewController: NSViewController?

  func switchTo(viewController: NSViewController) {
    if let currentViewController {
      currentViewController.view.removeFromSuperview()
      currentViewController.removeFromParent()
    }

    guard let rootView = view as? MainWindowRootView else { return }
    addChild(viewController)
    rootView.contentView.addSubview(viewController.view)
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: rootView.contentView.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: rootView.contentView.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: rootView.contentView.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: rootView.contentView.trailingAnchor),
    ])
    currentViewController = viewController
  }
}

final class MainWindowRootView: TrafficLightInsetApplierView {
  let contentView = NSView()
  private let backgroundView = MainWindowBg()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("Not supported")
  }

  private func setupView() {
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    contentView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundView)
    addSubview(contentView)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
}
