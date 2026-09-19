import Foundation

/// Recognize both SwiftPM's Swift Testing runner and XCTest-hosted package tests.
/// Use only at external-resource boundaries; individual fixtures should still
/// inject their own dependencies rather than sharing process-wide state.
public enum TestProcess {
  public static let isRunning = ProcessInfo.processInfo.arguments.contains {
    $0.contains(".xctest") || $0 == "--testing-library"
  } || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
