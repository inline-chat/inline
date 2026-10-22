import AppKit
import Charts
import InlineGrid
import InlineKit
import InlineRTC
import SwiftUI

/// Opt-in window for people debugging their own call. Reachable from the Help
/// menu only, so the default call experience never shows any of this.
@MainActor
final class GridCallDiagnosticsWindowController: NSWindowController, NSWindowDelegate {
  private static var shared: GridCallDiagnosticsWindowController?

  static func show(sender: Any? = nil) {
    if shared == nil {
      shared = GridCallDiagnosticsWindowController()
    }
    shared?.showWindow(sender)
  }

  private init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 380)),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    window.title = "Call Diagnostics"
    window.minSize = NSSize(width: 380, height: 320)
    window.setFrameAutosaveName("GridCallDiagnosticsWindow")
    window.contentViewController = NSHostingController(rootView: GridCallDiagnosticsView())
    window.delegate = self
    window.center()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_: Notification) {
    Self.shared = nil
  }
}

@MainActor
@Observable
private final class GridCallDiagnosticsModel {
  private(set) var report: InlineRTCDiagnosticsReport?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var names: [String: String] = [:]

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        let report = await GridRuntime.existing?.callDiagnostics()
        self?.report = report
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  func name(_ identity: String) -> String {
    if let cached = names[identity] { return cached }
    // Grid identities are `inline-grid-user-<userID>-<membershipID>`.
    let parts = identity.split(separator: "-")
    let resolved = parts.count >= 4
      ? Int64(parts[3]).flatMap { ObjectCache.shared.getUser(id: $0)?.user.displayName }
      : nil
    guard let resolved else { return identity }
    names[identity] = resolved
    return resolved
  }

  func reportText() -> String {
    guard let report else { return "No call diagnostics recorded." }
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    return report.text(
      header: ["Inline \(version) (\(build)) · macOS \(os) · \(Self.hardwareModel)"],
      displayName: { [self] identity in "\(name(identity)) [\(identity)]" }
    )
  }

  private static let hardwareModel: String = {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
  }()
}

private enum GridDiagnosticsTab: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case details = "Details"
  case log = "Log"

  var id: Self { self }
}

private struct GridCallDiagnosticsView: View {
  @State private var model = GridCallDiagnosticsModel()
  @State private var tab: GridDiagnosticsTab = .overview
  @State private var copied = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("", selection: $tab) {
          ForEach(GridDiagnosticsTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.reportText(), forType: .string)
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
          }
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help("Copy report")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      Divider()
      Group {
        if let report = model.report, report.callStartedAt != nil {
          switch tab {
          case .overview: GridDiagnosticsOverview(report: report, name: model.name)
          case .details: GridDiagnosticsDetails(report: report)
          case .log: GridDiagnosticsLog(events: report.events, name: model.name)
          }
        } else {
          ContentUnavailableView(
            "No call yet",
            systemImage: "waveform",
            description: Text("Join a room. Stats are recorded while you’re in a call.")
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .font(.system(size: 12))
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }
}

// MARK: - Overview

private struct GridDiagnosticsOverview: View {
  let report: InlineRTCDiagnosticsReport
  let name: (String) -> String

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        GridDiagnosticsVerdictLine(verdict: GridDiagnosticsVerdict(report: report, name: name))
        if let latest = report.latest {
          HStack(alignment: .top) {
            metric("Delay", latest.worstIncoming.map { latest.estimatedDelay(for: $0).totalMilliseconds }.map(ms))
            metric("Round trip", latest.uplinkRoundTripMilliseconds.map(ms))
            metric("Loss", latest.incoming.compactMap(\.lossPercent).max().map(percent))
          }
          GridDiagnosticsSparkline(
            title: "Delay",
            points: report.samples.compactMap { sample in
              sample.worstIncoming.map { (sample.time, sample.estimatedDelay(for: $0).totalMilliseconds) }
            }
          )
          if !latest.incoming.isEmpty {
            GridDiagnosticsPeople(sample: latest, name: name)
          }
        }
      }
      .padding(12)
    }
  }

  private func metric(_ title: String, _ value: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).foregroundStyle(.secondary)
      Text(value ?? "–").font(.system(size: 17, weight: .medium)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct GridDiagnosticsVerdict {
  enum Level { case good, warning, bad }

  let level: Level
  let message: String

  init(report: InlineRTCDiagnosticsReport, name: (String) -> String) {
    let rtc = report.state?.rtc
    switch rtc?.state {
    case .reconnecting?, .backingOff?:
      self.init(.bad, "Reconnecting")
      return
    case let .failed(_, message)?:
      self.init(.bad, message)
      return
    case .connected?, nil:
      break
    default:
      if rtc?.target == nil {
        self.init(.good, "Call ended · history kept until your next call")
      } else {
        self.init(.warning, "Connecting")
      }
      return
    }
    guard let latest = report.latest else {
      self.init(.good, "Collecting stats")
      return
    }
    if let worst = latest.worstIncoming {
      let estimate = latest.estimatedDelay(for: worst)
      if estimate.totalMilliseconds >= 600 {
        let cause = estimate.receiveBufferMilliseconds >= estimate.networkMilliseconds
          ? "audio is queued in your receive buffer after a network hiccup"
          : "the network round trip is slow"
        self.init(estimate.totalMilliseconds >= 1_000 ? .bad : .warning, "High delay from \(name(worst.participantIdentity)): \(cause)")
        return
      }
      if let loss = worst.lossPercent, loss >= 5 {
        self.init(.warning, "\(Int(loss))% of \(name(worst.participantIdentity))’s audio is being lost")
        return
      }
    }
    if let local = latest.publisher?.local ?? latest.subscriber?.local, local.isRelay || local.isTCP {
      self.init(.warning, "Connected through a \(local.isTCP ? "TCP " : "")relay, which can add delay")
      return
    }
    if latest.localConnectionQuality == "poor" || latest.localConnectionQuality == "lost" {
      self.init(.warning, "Your connection is \(latest.localConnectionQuality)")
      return
    }
    self.init(.good, "Looks good")
  }

  private init(_ level: Level, _ message: String) {
    self.level = level
    self.message = message
  }
}

private struct GridDiagnosticsVerdictLine: View {
  let verdict: GridDiagnosticsVerdict

  var body: some View {
    Label {
      Text(verdict.message)
    } icon: {
      Circle().fill(color).frame(width: 7, height: 7)
    }
    .foregroundStyle(verdict.level == .good ? .primary : color)
  }

  private var color: Color {
    switch verdict.level {
    case .good: .green
    case .warning: .orange
    case .bad: .red
    }
  }
}

private struct GridDiagnosticsSparkline: View {
  let title: String
  let points: [(Date, Double)]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(title) · last \(minutes) min").foregroundStyle(.tertiary)
      Chart(points.indices, id: \.self) { index in
        LineMark(x: .value("Time", points[index].0), y: .value(title, points[index].1))
          .interpolationMethod(.monotone)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
      }
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
          AxisGridLine()
          AxisValueLabel { Text(value.as(Double.self).map(ms) ?? "") }
        }
      }
      .frame(height: 56)
    }
  }

  private var minutes: Int {
    guard let first = points.first?.0, let last = points.last?.0 else { return 0 }
    return max(1, Int((last.timeIntervalSince(first) / 60).rounded(.up)))
  }
}

private struct GridDiagnosticsPeople: View {
  let sample: InlineRTCDiagnosticsSample
  let name: (String) -> String

  var body: some View {
    SwiftUI.Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
      GridRow {
        Text("Person")
        Text("Delay").gridColumnAlignment(.trailing)
        Text("Buffer").gridColumnAlignment(.trailing)
        Text("Loss").gridColumnAlignment(.trailing)
      }
      .foregroundStyle(.tertiary)
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(sample.incoming) { incoming in
        let delay = sample.estimatedDelay(for: incoming).totalMilliseconds
        GridRow {
          Text(name(incoming.participantIdentity)).lineLimit(1)
          Text(ms(delay)).foregroundStyle(delay >= 600 ? .orange : .primary)
          Text(incoming.receiveBufferMilliseconds.map(ms) ?? "–")
          Text(incoming.lossPercent.map(percent) ?? "–")
        }
        .monospacedDigit()
      }
    }
  }
}

// MARK: - Details

private struct GridDiagnosticsDetails: View {
  let report: InlineRTCDiagnosticsReport

  var body: some View {
    Form {
      if let latest = report.latest {
        Section("Network") {
          row("State", report.state.map { InlineRTCDiagnosticsReportStateLabel.label($0.rtc) })
          row("Server", [latest.server.host, latest.server.region].compactMap(\.self).joined(separator: " · "))
          row("Send path", latest.publisher.map(path))
          row("Receive path", latest.subscriber.map(path))
          row("Round trip", latest.uplinkRoundTripMilliseconds.map(ms))
          row("Bitrate", "out \(kbps(latest.outgoing?.bitrateKbps)) · in \(kbps(latest.incoming.compactMap(\.bitrateKbps).reduce(0, +)))")
          row("Upload loss", latest.outgoing?.serverReportedLossPercent.map(percent))
          row("Quality", latest.localConnectionQuality)
          GridDiagnosticsSparkline(
            title: "Round trip",
            points: report.samples.compactMap { sample in sample.uplinkRoundTripMilliseconds.map { (sample.time, $0) } }
          )
        }
      }
      if let audio = report.state?.audio {
        Section("Audio") {
          row("Input", device(audio.input?.activeDeviceName, delay: audio.route?.measuredInputDelayMilliseconds))
          row("Output", device(audio.output?.activeDeviceName, delay: audio.route?.measuredOutputDelayMilliseconds))
          row("Health", "capture \(audio.isCaptureHealthy ? "ok" : "unhealthy") · playout \(audio.isPlayoutHealthy ? "ok" : "unhealthy")")
          if let processing = audio.processing {
            row(
              "Processing",
              "echo \(processing.echoCancellationEffective.rawValue) · noise \(processing.noiseSuppressionEffective.rawValue) · gain \(processing.automaticGainControlEffective.rawValue)"
            )
          }
          row("Mic", report.latest?.outgoing.map { $0.muted ? "muted" : "\($0.codec ?? "on")" })
        }
      }
    }
    .formStyle(.grouped)
  }

  private func row(_ title: String, _ value: String?) -> some View {
    LabeledContent(title) {
      Text(value?.isEmpty == false ? value! : "–").textSelection(.enabled).monospacedDigit()
    }
  }

  private func path(_ transport: InlineRTCTransportStats) -> String {
    transport.local?.summary ?? "–"
  }

  private func device(_ name: String?, delay: UInt16?) -> String {
    [name, delay.map { "\($0) ms" }].compactMap(\.self).joined(separator: " · ")
  }
}

/// Short state label shared by the details tab.
private enum InlineRTCDiagnosticsReportStateLabel {
  static func label(_ rtc: InlineRTCConnectionSnapshot) -> String {
    let reconnects = rtc.reconnectCount == 0 ? "" : " · \(rtc.reconnectCount) reconnects"
    switch rtc.state {
    case .connected: return "Connected\(reconnects)"
    case .reconnecting: return "Reconnecting\(reconnects)"
    case .idle: return "Not in a call"
    case let .failed(_, message): return "Failed: \(message)"
    default: return "Connecting\(reconnects)"
    }
  }
}

// MARK: - Log

private struct GridDiagnosticsLog: View {
  let events: [InlineRTCDiagnosticsEvent]
  let name: (String) -> String

  var body: some View {
    List(events.reversed()) { event in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Self.time(event.time)).foregroundStyle(.tertiary).monospacedDigit()
        Text(displayMessage(event.message))
          .foregroundStyle(color(event.severity))
          .textSelection(.enabled)
      }
    }
    .listStyle(.plain)
  }

  private func displayMessage(_ message: String) -> String {
    message.replacing(/inline-grid-user-\d+-\d+/) { name(String($0.output)) }
  }

  private func color(_ severity: InlineRTCDiagnosticsEvent.Severity) -> Color {
    switch severity {
    case .info: .primary
    case .warning: .orange
    case .error: .red
    }
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static func time(_ date: Date) -> String { formatter.string(from: date) }
}

// MARK: - Formatting

private func ms(_ value: Double) -> String {
  value >= 1_000 ? String(format: "%.1f s", value / 1_000) : "\(Int(value.rounded())) ms"
}

private func percent(_ value: Double) -> String {
  String(format: "%.1f%%", value)
}

private func kbps(_ value: Double?) -> String {
  value.map { "\(Int($0.rounded())) kbps" } ?? "–"
}
