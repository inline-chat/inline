import UIKit

enum SendMessageAnimationTiming {
  static let duration: TimeInterval = 0.3

  static let verticalControlPoint1 = CGPoint(x: 0.215, y: 0.61)
  static let verticalControlPoint2 = CGPoint(x: 0.355, y: 1.0)
  static let horizontalControlPoint1 = CGPoint(x: 0.215, y: 0.61)
  static let horizontalControlPoint2 = CGPoint(x: 0.355, y: 1.0)

  static var verticalTimingParameters: UICubicTimingParameters {
    UICubicTimingParameters(
      controlPoint1: verticalControlPoint1,
      controlPoint2: verticalControlPoint2
    )
  }

  static var horizontalTimingParameters: UICubicTimingParameters {
    UICubicTimingParameters(
      controlPoint1: horizontalControlPoint1,
      controlPoint2: horizontalControlPoint2
    )
  }

  static var verticalMediaTimingFunction: CAMediaTimingFunction {
    CAMediaTimingFunction(
      controlPoints: Float(verticalControlPoint1.x),
      Float(verticalControlPoint1.y),
      Float(verticalControlPoint2.x),
      Float(verticalControlPoint2.y)
    )
  }

  static func makeVerticalAnimator(duration: TimeInterval = duration) -> UIViewPropertyAnimator {
    UIViewPropertyAnimator(
      duration: duration,
      timingParameters: verticalTimingParameters
    )
  }

  static func verticalProgress(for linearProgress: CGFloat) -> CGFloat {
    cubicProgress(
      for: linearProgress,
      controlPoint1: verticalControlPoint1,
      controlPoint2: verticalControlPoint2
    )
  }

  static func verticalProgress(
    for linearProgress: CGFloat,
    in range: ClosedRange<CGFloat>
  ) -> CGFloat {
    normalizedCubicProgress(
      for: linearProgress,
      in: range,
      controlPoint1: verticalControlPoint1,
      controlPoint2: verticalControlPoint2
    )
  }

  static func horizontalProgress(for linearProgress: CGFloat) -> CGFloat {
    cubicProgress(
      for: linearProgress,
      controlPoint1: horizontalControlPoint1,
      controlPoint2: horizontalControlPoint2
    )
  }

  static func horizontalProgress(
    for linearProgress: CGFloat,
    in range: ClosedRange<CGFloat>
  ) -> CGFloat {
    normalizedCubicProgress(
      for: linearProgress,
      in: range,
      controlPoint1: horizontalControlPoint1,
      controlPoint2: horizontalControlPoint2
    )
  }

  static func retargetDuration(preparedAt _: Date, now _: Date = Date()) -> TimeInterval {
    duration
  }

  static func retargetTimingProgressRange(
    preparedAt _: Date,
    retargetDuration _: TimeInterval,
    now _: Date = Date()
  ) -> ClosedRange<CGFloat> {
    0 ... 1
  }

  private static func cubicProgress(
    for linearProgress: CGFloat,
    controlPoint1: CGPoint,
    controlPoint2: CGPoint
  ) -> CGFloat {
    let x = min(1, max(0, linearProgress))
    var lower: CGFloat = 0
    var upper: CGFloat = 1
    var t = x

    for _ in 0 ..< 10 {
      let estimatedX = cubicValue(t, controlPoint1.x, controlPoint2.x)
      if estimatedX < x {
        lower = t
      } else {
        upper = t
      }
      t = (lower + upper) * 0.5
    }

    return cubicValue(t, controlPoint1.y, controlPoint2.y)
  }

  private static func normalizedCubicProgress(
    for linearProgress: CGFloat,
    in range: ClosedRange<CGFloat>,
    controlPoint1: CGPoint,
    controlPoint2: CGPoint
  ) -> CGFloat {
    let lower = min(1, max(0, range.lowerBound))
    let upper = min(1, max(lower, range.upperBound))
    guard upper - lower > 0.001 else {
      return linearProgress >= upper ? 1 : 0
    }

    let clampedLinearProgress = min(upper, max(lower, linearProgress))
    let startValue = cubicProgress(
      for: lower,
      controlPoint1: controlPoint1,
      controlPoint2: controlPoint2
    )
    let endValue = cubicProgress(
      for: upper,
      controlPoint1: controlPoint1,
      controlPoint2: controlPoint2
    )
    guard abs(endValue - startValue) > 0.001 else {
      return (clampedLinearProgress - lower) / (upper - lower)
    }

    let value = cubicProgress(
      for: clampedLinearProgress,
      controlPoint1: controlPoint1,
      controlPoint2: controlPoint2
    )
    return min(1, max(0, (value - startValue) / (endValue - startValue)))
  }

  private static func cubicValue(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
    let oneMinusT = 1 - t
    return 3 * oneMinusT * oneMinusT * t * p1 +
      3 * oneMinusT * t * t * p2 +
      t * t * t
  }
}
