//
//  MainWindowBg.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 10/19/25.
//

import AppKit

class MainWindowBg: NSVisualEffectView {
  private let overlayView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    return view
  }()

  init() {
    super.init(frame: NSRect(origin: .zero, size: .init(width: 400, height: 500)))
    setupView()
  }

  @available(*, unavailable)
  required init(coder _: NSCoder) {
    fatalError("Not supported")
  }

  override func updateLayer() {
    overlayView.layer?.backgroundColor = Theme.windowBackgroundColor.cgColor
    super.updateLayer()
  }

  private func setupView() {
    // Material
    material = .hudWindow
    blendingMode = .behindWindow
    state = .followsWindowActiveState

    addOverlay()
    addTopHighlight()
  }

  private func addOverlay() {
    // Overlay view for tinting
    addSubview(overlayView)
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      overlayView.topAnchor.constraint(equalTo: topAnchor),
      overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func addTopHighlight() {
    // Create top inner highlight border
    let topHighlight = NSView()
    topHighlight.wantsLayer = true
    topHighlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor

    addSubview(topHighlight)
    topHighlight.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      topHighlight.topAnchor.constraint(equalTo: topAnchor),
      topHighlight.leadingAnchor.constraint(equalTo: leadingAnchor),
      topHighlight.trailingAnchor.constraint(equalTo: trailingAnchor),
      topHighlight.heightAnchor.constraint(equalToConstant: 2),
    ])
  }
}
