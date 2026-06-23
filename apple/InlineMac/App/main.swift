import AppKit
import Darwin

let app = NSApplication.shared

#if DEBUG
let didWriteRichTextTestBookReport = MainActor.assumeIsolated {
  RichMessageTestBookLaunchDiagnostics.writeReportIfRequested()
}
let didWriteRichTextTestBookSnapshot = MainActor.assumeIsolated {
  RichMessageTestBookLaunchDiagnostics.writeSnapshotIfRequested()
}
if RichMessageTestBookLaunchDiagnostics.shouldExitAfterArtifacts() {
  let reportOK = !RichMessageTestBookLaunchDiagnostics.shouldWriteReport() || didWriteRichTextTestBookReport
  let snapshotOK = !RichMessageTestBookLaunchDiagnostics.shouldWriteSnapshot() || didWriteRichTextTestBookSnapshot
  exit(reportOK && snapshotOK ? EXIT_SUCCESS : EXIT_FAILURE)
}
if RichMessageTestBookLaunchDiagnostics.shouldRunIsolatedTestBook() {
  MainActor.assumeIsolated {
    RichMessageTestBookLaunchDiagnostics.runIsolatedTestBook(app: app)
  }
  exit(EXIT_SUCCESS)
}
#endif

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
