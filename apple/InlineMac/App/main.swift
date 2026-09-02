import AppKit
import Logger

PerformanceTrace.event("MacProcessEntry", category: .launch)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
