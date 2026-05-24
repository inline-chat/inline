import SwiftUI

public extension EnvironmentValues {
  @Entry var logOut: () async -> Void = {}
  @Entry var keyMonitor: KeyMonitor? = nil
  @Entry var dependencies: AppDependencies? = nil
}

extension EnvironmentValues {
  @Entry var appBridge: AppBridge? = nil
}
