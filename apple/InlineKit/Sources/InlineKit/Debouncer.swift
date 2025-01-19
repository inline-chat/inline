import Combine
import Foundation
import SwiftUI

// Debouncer class to prevent too frequent API calls
public class Debouncer: ObservableObject, @unchecked Sendable {
  @Published public var input: String = ""
  @Published public var debouncedInput: String?
  private var cancellable: AnyCancellable?

  public init(delay: TimeInterval) {
    cancellable =
      $input
      // Publishes only elements that don’t match the previous element
      .removeDuplicates()
      .debounce(for: .seconds(delay), scheduler: DispatchQueue.main)
      .sink { [weak self] value in
        self?.debouncedInput = value
      }
  }
}
