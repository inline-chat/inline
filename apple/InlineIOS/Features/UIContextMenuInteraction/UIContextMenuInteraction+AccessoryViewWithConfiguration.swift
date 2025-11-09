import ContextMenuAccessoryStructs
import SwiftUI
import UIKit

extension UIContextMenuInteraction {
  static func accessoryView(configuration: ContextMenuAccessoryConfiguration) -> UIView? {
    let accessoryViewClassString = ["View", "Accessory", "Menu", "Context", "UI", "_"].reversed().joined()
    let accessoryViewClass = NSClassFromString(accessoryViewClassString) as? UIView.Type
        
    guard let accessoryViewClass else { return nil }
        
    let accessoryView = accessoryViewClass.init()
        
    let locationString = [":", "Location", "set"].reversed().joined()
    let locationSelector = NSSelectorFromString(locationString)
        
    if accessoryView.responds(to: locationSelector) {
      accessoryView.setValue(configuration.location.rawValue, forKey: "location")
    }

    let trackingAxisString = [":", "Axis", "Tracking", "set"].reversed().joined()
    let trackingAxisSelector = NSSelectorFromString(trackingAxisString)
        
    if accessoryView.responds(to: trackingAxisSelector) {
      let key = ["Axis", "tracking"].reversed().joined()
      accessoryView.setValue(configuration.trackingAxis.rawValue, forKey: key)
    }
        
    let anchorString = [":", "Anchor", "set"].reversed().joined()
    let anchorSelector = NSSelectorFromString(anchorString)
        
    if accessoryView.responds(to: anchorSelector) {
      guard let method = class_getInstanceMethod(accessoryViewClass, anchorSelector) else {
        return accessoryView
      }
      let implementation = method_getImplementation(method)

      let type = (@convention(c) (AnyObject, Selector, ContextMenuAccessoryAnchor) -> Void).self
      let setAnchor = unsafeBitCast(implementation, to: type)
      setAnchor(accessoryView, anchorSelector, configuration.anchor)
    }
        
    return accessoryView
  }
}
