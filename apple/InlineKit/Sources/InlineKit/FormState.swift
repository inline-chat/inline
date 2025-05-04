import SwiftUI

public enum FormStateData: Equatable {
  case idle
  case loading
  case error(String?)
  case succeeded
}

// A helper for easier state management for simple forms
public class FormStateObject: ObservableObject {
  @Published public private(set) var state: FormStateData

  public var isLoading: Bool {
    state == FormStateData.loading
  }
  
  public var error: String? {
    if case let .error(error) = state {
      return error
    }
    return nil
  }
  
  public var hasSucceeded: Bool {
    state == FormStateData.succeeded
  }

  public init() {
    state = .idle
  }

  public func reset() {
    state = .idle
  }

  public func startLoading() {
    state = .loading
  }

  public func failed(error: String?) {
    state = .error(error)
  }

  public func succeeded() {
    state = .succeeded
  }
}

@propertyWrapper
@MainActor
public struct FormState: DynamicProperty {
  @StateObject private var state = FormStateObject()

  public init() {}
  public var wrappedValue: FormStateObject {
    state
  }
}
