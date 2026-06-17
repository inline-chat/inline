import AppKit
import Foundation
import Logger

final class AppInstallLocationPrompt {
  private let fileManager: FileManager
  private let workspace: NSWorkspace
  private let log = Log.scoped("AppInstallLocationPrompt")

  init(fileManager: FileManager = .default, workspace: NSWorkspace = .shared) {
    self.fileManager = fileManager
    self.workspace = workspace
  }

  @MainActor
  func presentIfNeeded(relaunch: @escaping @MainActor (URL) -> Void) {
    #if DEBUG || DEBUG_BUILD
    return
    #else
    let appURL = normalized(Bundle.main.bundleURL)
    guard appURL.pathExtension == "app", !isInApplications(appURL) else {
      return
    }

    let destinationURL = destinationURL(for: appURL)
    guard !urlsReferToSameFile(appURL, destinationURL) else {
      return
    }

    if canInstallAutomatically(to: destinationURL) {
      presentAutomaticPrompt(appURL: appURL, destinationURL: destinationURL, relaunch: relaunch)
      return
    }

    presentManualPrompt(appURL: appURL)
    #endif
  }

  @MainActor
  private func presentAutomaticPrompt(
    appURL: URL,
    destinationURL: URL,
    relaunch: @escaping @MainActor (URL) -> Void
  ) {
    let appName = displayName(for: appURL)
    let hasExistingApp = appExists(at: destinationURL)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "\(appName) is outside Applications"
    if hasExistingApp {
      alert.informativeText =
        "Move this copy to Applications, replace the existing \(appName), and restart from there?"
      alert.addButton(withTitle: "Replace and Restart")
    } else {
      alert.informativeText = "Move \(appName) to Applications and restart from there?"
      alert.addButton(withTitle: "Move and Restart")
    }
    alert.addButton(withTitle: "Not Now")

    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      let installedURL = try installApp(from: appURL, to: destinationURL)
      relaunch(installedURL)
    } catch {
      log.error("Failed to move app to Applications", error: error)
      presentInstallFailure(appURL: appURL, error: error)
    }
  }

  @MainActor
  private func presentManualPrompt(appURL: URL) {
    let appName = displayName(for: appURL)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "\(appName) is outside Applications"
    alert.informativeText = "Move \(appURL.lastPathComponent) to Applications, then open \(appName) again."
    alert.addButton(withTitle: "Show Applications Folder")
    alert.addButton(withTitle: "Not Now")

    if alert.runModal() == .alertFirstButtonReturn {
      showApplicationsFolder()
    }
  }

  @MainActor
  private func presentInstallFailure(appURL: URL, error: Error) {
    let appName = displayName(for: appURL)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Could Not Move \(appName)"
    alert.informativeText =
      "\(appName) could not move itself to Applications: \(error.localizedDescription)\n\nMove \(appURL.lastPathComponent) to Applications, then open \(appName) again."
    alert.addButton(withTitle: "Show Applications Folder")
    alert.addButton(withTitle: "OK")

    if alert.runModal() == .alertFirstButtonReturn {
      showApplicationsFolder()
    }
  }

  private func canInstallAutomatically(to destinationURL: URL) -> Bool {
    guard !isSandboxedRuntime else {
      return false
    }

    guard appExists(at: destinationURL) else {
      return true
    }

    return existingAppMatchesCurrentBundle(at: destinationURL)
  }

  private func installApp(from appURL: URL, to destinationURL: URL) throws -> URL {
    let directoryURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    guard appExists(at: destinationURL) else {
      try fileManager.copyItem(at: appURL, to: destinationURL)
      return destinationURL
    }

    guard existingAppMatchesCurrentBundle(at: destinationURL) else {
      throw InstallLocationError.existingAppMismatch(destinationURL)
    }

    let tempURL = temporaryDestinationURL(for: destinationURL)
    do {
      try fileManager.copyItem(at: appURL, to: tempURL)

      var trashedURL: NSURL?
      try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)

      try fileManager.moveItem(at: tempURL, to: destinationURL)
      return destinationURL
    } catch {
      try? fileManager.removeItem(at: tempURL)
      throw error
    }
  }

  private func isInApplications(_ appURL: URL) -> Bool {
    let appPath = normalized(appURL).path
    return applicationDirectories.contains { directoryURL in
      let directoryPath = normalized(directoryURL).path
      return appPath == directoryPath || appPath.hasPrefix(directoryPath + "/")
    }
  }

  private var applicationDirectories: [URL] {
    let urls = fileManager.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
    var paths = Set<String>()
    return urls.compactMap { url in
      let normalizedURL = normalized(url)
      guard paths.insert(normalizedURL.path).inserted else {
        return nil
      }
      return normalizedURL
    }
  }

  private var targetDirectoryURL: URL {
    fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first
      ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
  }

  private func destinationURL(for appURL: URL) -> URL {
    targetDirectoryURL.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
  }

  private func temporaryDestinationURL(for destinationURL: URL) -> URL {
    let base = destinationURL.deletingPathExtension().lastPathComponent
    return destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent(".\(base)-install-\(UUID().uuidString).app", isDirectory: true)
  }

  private func appExists(at url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private func existingAppMatchesCurrentBundle(at destinationURL: URL) -> Bool {
    guard let currentBundleID = Bundle.main.bundleIdentifier,
          let existingBundle = Bundle(url: destinationURL)
    else {
      return false
    }
    return existingBundle.bundleIdentifier == currentBundleID
  }

  private func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    guard fileManager.fileExists(atPath: rhs.path) else {
      return false
    }

    let lhsURL = normalized(lhs)
    let rhsURL = normalized(rhs)
    if lhsURL.path == rhsURL.path {
      return true
    }

    guard let lhsValues = try? lhsURL.resourceValues(forKeys: [
      .fileResourceIdentifierKey,
      .volumeIdentifierKey,
    ]),
      let rhsValues = try? rhsURL.resourceValues(forKeys: [
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
      ]),
      let lhsFileID = lhsValues.fileResourceIdentifier as? NSObject,
      let rhsFileID = rhsValues.fileResourceIdentifier as? NSObject,
      let lhsVolumeID = lhsValues.volumeIdentifier as? NSObject,
      let rhsVolumeID = rhsValues.volumeIdentifier as? NSObject
    else {
      return false
    }

    return lhsFileID.isEqual(rhsFileID) && lhsVolumeID.isEqual(rhsVolumeID)
  }

  private func displayName(for appURL: URL) -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? appURL.deletingPathExtension().lastPathComponent
  }

  private var isSandboxedRuntime: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }

  private func showApplicationsFolder() {
    if !workspace.open(targetDirectoryURL) {
      log.warning("Failed to open Applications folder")
    }
  }

  private func normalized(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}

private enum InstallLocationError: LocalizedError {
  case existingAppMismatch(URL)

  var errorDescription: String? {
    switch self {
      case let .existingAppMismatch(url):
        "An app already exists at \(url.path), but it does not match this app."
    }
  }
}
