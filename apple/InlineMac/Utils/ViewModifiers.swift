import Foundation
import SwiftUI

extension View {
  // Use for macOS checks in view modifiers
  @ViewBuilder
  func conditional(_ content: @escaping (Self) -> (some View)?) -> some View {
    if let out = content(self) {
      out
    } else {
      self
    }
  }

  /// Applies the given transform if the given condition evaluates to `true`.
  /// - Parameters:
  ///   - condition: The condition to evaluate.
  ///   - transform: The transform to apply to the source `View`.
  /// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
  @ViewBuilder func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }

  // Use for checking width of the view
  @ViewBuilder func onWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
    background(
      GeometryReader { reader in
        Color.clear
          .onChange(of: reader.frame(in: .global).width) { newValue in
            action(newValue)
          }
      }
    )
  }

  func eraseToAnyView() -> AnyView {
    AnyView(self)
  }
}

extension View {
  func debugBackground() -> some View {
    #if DEBUG
    background(Color.red.opacity(0.3))
    #else
    self
    #endif
  }

  func debugBackground2() -> some View {
    #if DEBUG
    background(Color.blue.opacity(0.3))
    #else
    self
    #endif
  }

  func debugBackground3() -> some View {
    #if DEBUG
    background(Color.black.opacity(0.3))
    #else
    self
    #endif
  }

  func debugBorder() -> some View {
    #if DEBUG
    overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 1))
    #else
    self
    #endif
  }
}

extension View {
  func flippedUpsideDown() -> some View {
    scaleEffect(CGSize(width: 1.0, height: -1.0))
  }
}

extension View {
  func disableAnimations() -> some View {
    transaction { transaction in
      transaction.disablesAnimations = true
      transaction.animation = nil
    }
  }
}

public extension Animation {
  static var fastFeedback: Animation {
    // .easeOut(duration: 0.06)
    // .easeInOut(duration: 0.06)
    .easeIn(duration: 0.04)
  }
  
  static var mediumFeedback: Animation {
    .easeOut(duration: 0.08)
  }

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

  static var smoothSnappier: Animation {
    .interpolatingSpring(
      duration: 0.2,
      bounce: 0
    )
  }
}

extension View {
  #if os(iOS)
  func onBackground(_ f: @escaping () -> Void) -> some View {
    onReceive(
      NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification),
      perform: { _ in f() }
    )
  }

  func onForeground(_ f: @escaping () -> Void) -> some View {
    onReceive(
      NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification),
      perform: { _ in f() }
    )
  }
  #else
  func onBackground(_ f: @escaping () -> Void) -> some View {
    onReceive(
      NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification),
      perform: { _ in f() }
    )
  }

  func onForeground(_ f: @escaping () -> Void) -> some View {
    onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
      perform: { _ in f() }
    )
  }
  #endif
}
