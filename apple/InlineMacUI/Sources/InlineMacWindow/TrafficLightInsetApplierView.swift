import AppKit

open class TrafficLightInsetApplierView: NSView {
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyTrafficLightsIfNeeded()
  }

  public override func layout() {
    super.layout()
    applyTrafficLightsIfNeeded()
  }

  public override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    applyTrafficLightsIfNeeded()
  }

  private func applyTrafficLightsIfNeeded() {
    (window as? TrafficLightInsetApplicable)?.applyTrafficLightsInset()
  }
}
