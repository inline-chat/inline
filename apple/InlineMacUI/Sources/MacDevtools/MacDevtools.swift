import Foundation

public enum MacDevtools {
  public static func bootstrap() {
    MacDevtoolsLogCapture.shared.bootstrap()
  }

  public static var captureEnabled: Bool {
    MacDevtoolsLogCapture.shared.isEnabled
  }

  public static var logFileURL: URL? {
    try? MacDevtoolsPaths.logFileURL()
  }
}
