import Foundation
import SwiftUI

public extension Animation {
  static var smoothSnappy: Animation {
    .interpolatingSpring(
      duration: 0.25,
      bounce: 0
    )
  }

  static var punchySnappy: Animation {
    Animation.spring(
      response: 0.15,
      dampingFraction: 0.4,
      blendDuration: 0
    )
  }
}
