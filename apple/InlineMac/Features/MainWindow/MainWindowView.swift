//
//  MainWindowBg.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 10/19/25.
//

import AppKit

class MainWindowView: NSViewController {
  override func loadView() {
    view = MainWindowBg()
    //view.translatesAutoresizingMaskIntoConstraints = false
  }

  private var currentViewController: NSViewController?

  func switchTo(viewController: NSViewController) {
    if let currentViewController {
      currentViewController.view.removeFromSuperview()
      currentViewController.removeFromParent()
    }

    addChild(viewController)
    view.addSubview(viewController.view)
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }
}
