import Combine
import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  @Published var messageStyle: MessageStyle = .bubble

  private init() {}

  private var cancellables: Set<AnyCancellable> = []

  func observe(_ keyPath: WritableKeyPath<AppSettings, MessageStyle>, onChange: @escaping (MessageStyle) -> Void) {
    objectWillChange
      .sink { _ in
        onChange(self[keyPath: keyPath])
      }
      .store(in: &cancellables)
  }
}

enum MessageStyle: String, CaseIterable {
  case bubble = "Bubble"
  case minimal = "Minimal"
}
