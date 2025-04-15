import SwiftUI

public extension EnvironmentValues {
  @Entry var logOut: () async -> Void = {}
  @Entry var keyMonitor: KeyMonitor? = nil
}
