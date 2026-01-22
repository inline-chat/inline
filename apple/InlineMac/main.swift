import AppKit

@main
struct InlineMacMain {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }
}
