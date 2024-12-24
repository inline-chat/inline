import AppKit

class BasicView: NSView {
  // MARK: - Properties
    
  var backgroundColor: NSColor? {
    didSet { configureBackground() }
  }
    
  override var wantsUpdateLayer: Bool { true }
    
  // MARK: - Lifecycle
    
  init() {
    super.init(frame: .zero)
    configureView()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  // MARK: - Methods
    
  override func updateLayer() {
    super.updateLayer()
    configureBackground()
  }
    
  private func configureView() {
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }
    
  private func configureBackground() {
    guard let layer else {
      return
    }
        
    if let backgroundColor {
      layer.backgroundColor = backgroundColor.cgColor
    } else {
      layer.backgroundColor = nil
    }
  }
}
