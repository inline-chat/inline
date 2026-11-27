import AppKit
import TimelineAppKit

// TimelineMacLab: scripted experiments for the macOS message list.
//   --scenario <name>  run one experiment and exit
//   --out <path>       where its JSON goes (default results/<name>.json)

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
  guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
  return arguments[i + 1]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

@MainActor
final class LabDelegate: NSObject, NSApplicationDelegate {
  var scenario: Scenario?
  var playground: Playground?
  var activity: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A tuning knob for the fling cases: TL_GAIN=1.3 runs them with another base release gain.
    if let gain = ProcessInfo.processInfo.environment["TL_GAIN"].flatMap(Double.init) {
      NativeScrolling.releaseVelocityGain = gain
    }
    if arguments.contains("--play") {
      app.setActivationPolicy(.regular)
      playground = Playground(
        count: argument("--count").flatMap(Int.init) ?? 2000, groupRun: argument("--groups").flatMap(Int.init) ?? 4,
        showsNative: !arguments.contains("--no-native")
      )
      app.activate()
      return
    }
    if let path = argument("--replay") {
      Task { @MainActor in
        await GestureReplay.run(path: path)
        exit(0)
      }
      return
    }
    if let at = arguments.firstIndex(of: "--suite") {
      let prefixes = arguments[(at + 1)...].prefix { !$0.hasPrefix("--") }
      // Not the frontmost app, the lab would be throttled (App Nap, efficiency cores): perf cases then measure the
      // scheduler, 5× apart between runs. A latency-critical activity keeps it at full speed, as a chat in use is.
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "timeline lab suite"
      )
      Task { @MainActor in
        await SuiteRunner.run(prefixes: Array(prefixes))
        exit(0)
      }
      return
    }
    let name = argument("--scenario") ?? "native.middle"
    let out = argument("--out") ?? "results/\(name).json"
    guard let make = Scenarios.all[name] else {
      FileHandle.standardError.write("unknown scenario \(name); known: \(Scenarios.all.keys.sorted())\n".data(using: .utf8)!)
      exit(2)
    }
    if argument("--responsive") == "0" { NativeReference.FlippedView.responsive = false }
    let scenario = make()
    self.scenario = scenario
    scenario.run { probe in
      try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true
      )
      probe.write(to: out)
      print("wrote \(out): \(probe.samples.count) samples, \(probe.inputs.count) inputs")
      exit(0)
    }
  }
}

MainActor.assumeIsolated {
  let delegate = LabDelegate()
  app.delegate = delegate
  withExtendedLifetime(delegate) { app.run() }
}
