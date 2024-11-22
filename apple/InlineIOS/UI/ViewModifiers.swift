import Foundation
import SwiftUI

extension Animation {
  public static var smoothSnappy: Animation {
    .interpolatingSpring(
      duration: 0.12,
      bounce: 0
    )
  }

  public static var smoothSnappyLong: Animation {
    .interpolatingSpring(
      duration: 0.25,
      bounce: 0
    )
  }

  public static var punchySnappy: Animation {
    Animation.spring(
      response: 0.15,
      dampingFraction: 0.4,
      blendDuration: 0
    )
  }
}
