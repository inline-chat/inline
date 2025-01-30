import Combine
import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  @Published var sendsWithCmdEnter: Bool = false

  private init() {}
}
