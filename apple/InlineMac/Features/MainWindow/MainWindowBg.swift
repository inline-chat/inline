//
//  MainWindowBg.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 10/19/25.
//

import AppKit

class MainWindowBg: NSVisualEffectView {
  init() {
    super.init(frame: NSRect(origin: .zero, size: .init(width: 400, height: 500)))
    setupView()
  }

  @available(*, unavailable)
  required init(coder _: NSCoder) {
    fatalError("Not supported")
  }

  private func setupView() {
    // Material
    material = .hudWindow
    blendingMode = .behindWindow
    state = .active

    addOverlay()
    addTopHighlight()
  }

  private func addOverlay() {
    // Overlay view for tinting
    let overlayView = NSView()
    overlayView.wantsLayer = true
    overlayView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor
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
    topHighlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor

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
