import AppKit
import Foundation

// TimelineScrollLab: the NSScrollView-hosted timeline prototype against the custom engine.
//   --probe                  does responsive scrolling engage? (events, threads, a stall mid-momentum)
//   --compare [prefix…]      every scenario on both lists; prints the table, writes results/compare.json
//   --play [engine|engine-coast|nsscroll|tg] [--sticky] [--log file.jsonl]  a lab chat window to try by hand
//                            (--sticky: avatars and the floating date); --log records each real
//                            gesture's momentum stream beside the list's own travel
//   --gestures <path>        recorded gestures (default: the Dev build's timeline-gestures.jsonl)
//   --origin x,y             where windows open (global points, bottom-left; default slot E3, 1300,40). Claim the
//                            slot first (~/dev/inline-chat/.lab-screen/claim E3 …), and POINTER for --delivery hid.

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
  guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
  return arguments[i + 1]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

@MainActor
final class LabDelegate: NSObject, NSApplicationDelegate {
  var activity: NSObjectProtocol?
  var keep: [AnyObject] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Not frontmost, the lab would be throttled (App Nap, efficiency cores); a chat in use is not.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "timeline scroll lab"
    )
    if let at = arguments.firstIndex(of: "--play") {
      app.setActivationPolicy(.regular)
      let kind = at + 1 < arguments.count && !arguments[at + 1].hasPrefix("--") ? arguments[at + 1] : "nsscroll"
      let sticky = arguments.contains("--sticky")
      let lab = LabWindow(kind: kind.hasPrefix("engine") ? "engine" : kind, count: argument("--count").flatMap(Int.init) ?? 3000,
                          groupRun: sticky ? 6 : 4, sticky: sticky)
      if let engine = lab.subject as? EngineSubject { engine.list.coastsOnMainThread = kind == "engine-coast" }
      lab.window.level = .normal
      lab.window.styleMask.insert(.closable)
      keep.append(lab)
      if let path = argument("--log") {
        let log = GestureLog(lab: lab, path: path)
        log.start()
        keep.append(log)
      }
      app.activate()
      return
    }
    if let path = argument("--calcdump") {
      CalcDump.run(path: path)
      exit(0)
    }
    if arguments.contains("--probe") {
      Task { @MainActor in
        await Probe.run()
        exit(0)
      }
      return
    }
    if let at = arguments.firstIndex(of: "--compare") {
      let prefixes = arguments[(at + 1)...].prefix { !$0.hasPrefix("--") }
      Task { @MainActor in
        await Compare.run(prefixes: Array(prefixes))
        exit(0)
      }
      return
    }
    print("usage: TimelineScrollLab --probe | --compare [prefix…] | --play [engine|nsscroll]")
    exit(2)
  }
}

MainActor.assumeIsolated {
  let delegate = LabDelegate()
  app.delegate = delegate
  withExtendedLifetime(delegate) { app.run() }
}
