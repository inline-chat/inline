import Foundation

/// Plain-text export meant to be pasted into a chat with the Inline team.
/// Readable at a glance at the top, raw samples at the bottom for analysis.
public extension InlineRTCDiagnosticsReport {
  func text(
    header: [String],
    displayName: (String) -> String = { $0 }
  ) -> String {
    var lines = ["Inline call diagnostics"]
    lines += header
    lines.append("Generated \(Self.dateTime(generatedAt))")

    if let state {
      let rtc = state.rtc
      var call = "Call: \(InlineRTCDiagnosticsRecorder.label(rtc.state))"
      if let callStartedAt {
        call += " · started \(Self.time(callStartedAt)) (\(Self.duration(generatedAt.timeIntervalSince(callStartedAt))))"
      }
      call += " · reconnects \(rtc.reconnectCount)"
      call += " · mic \(rtc.microphoneMuted ? "muted" : "on")"
      lines.append(call)
      if let lastError = rtc.lastError {
        lines.append("Last error: \(lastError)")
      }
    }
    if let server = latest?.server {
      let parts = [server.host, server.region, server.nodeID, server.version.map { "v\($0)" }, server.roomSid]
      lines.append("Server: \(parts.compactMap(\.self).joined(separator: " · "))")
    }

    lines.append("")
    lines.append("Now")
    if let latest {
      if let worst = latest.worstIncoming {
        let estimate = latest.estimatedDelay(for: worst)
        lines.append(
          "  Delay (worst): \(displayName(worst.participantIdentity)) \(Self.ms(estimate.totalMilliseconds))"
            + " = network \(Self.ms(estimate.networkMilliseconds))"
            + " + receive buffer \(Self.ms(estimate.receiveBufferMilliseconds))"
            + " + devices \(Self.ms(estimate.deviceMilliseconds))"
        )
      }
      if let publisher = latest.publisher {
        var send = "  Send: \(Self.path(publisher)) · RTT \(Self.ms(latest.uplinkRoundTripMilliseconds))"
        if let outgoing = latest.outgoing {
          send += " · \(Self.kbps(outgoing.bitrateKbps)) · server loss \(Self.percent(outgoing.serverReportedLossPercent))"
          send += outgoing.muted ? " · muted" : ""
        }
        lines.append(send)
      }
      if let subscriber = latest.subscriber {
        lines.append("  Receive: \(Self.path(subscriber)) · RTT \(Self.ms(subscriber.roundTripMilliseconds))")
      }
      lines.append("  Your quality: \(latest.localConnectionQuality)")
    } else {
      lines.append("  No samples yet")
    }
    if let audio = state?.audio {
      let input = audio.input?.activeDeviceName ?? "none"
      let output = audio.output?.activeDeviceName ?? "none"
      let inputDelay = audio.route?.measuredInputDelayMilliseconds.map { " (\($0) ms)" } ?? ""
      let outputDelay = audio.route?.measuredOutputDelayMilliseconds.map { " (\($0) ms)" } ?? ""
      lines.append("  Input: \(input)\(inputDelay) · Output: \(output)\(outputDelay) · volume \(Int(audio.outputVolume * 100))%")
      lines.append(
        "  Audio: \(audio.state) · capture \(audio.isCaptureHealthy ? "healthy" : "unhealthy")"
          + " · playout \(audio.isPlayoutHealthy ? "healthy" : "unhealthy")"
      )
      if let processing = audio.processing {
        lines.append(
          "  Processing: echo \(processing.echoCancellationEffective.rawValue)"
            + " · noise \(processing.noiseSuppressionEffective.rawValue)"
            + " · gain \(processing.automaticGainControlEffective.rawValue)"
            + " · voice processing \(processing.platformVoiceProcessingActive ? "on" : "off")"
        )
      }
    }

    if let latest, !latest.incoming.isEmpty {
      lines.append("")
      lines.append("People")
      for incoming in latest.incoming {
        let estimate = latest.estimatedDelay(for: incoming)
        lines.append(
          "  \(displayName(incoming.participantIdentity)): delay \(Self.ms(estimate.totalMilliseconds))"
            + " · buffer \(Self.ms(incoming.receiveBufferMilliseconds)) (target \(Self.ms(incoming.receiveBufferTargetMilliseconds)))"
            + " · loss \(Self.percent(incoming.lossPercent))"
            + " · concealed \(Self.percent(incoming.concealedPercent))"
            + " · jitter \(Self.ms(incoming.jitterMilliseconds))"
            + " · \(Self.kbps(incoming.bitrateKbps))"
            + " · \(incoming.codec ?? "?")"
            + " · quality \(incoming.connectionQuality)"
            + (incoming.muted ? " · muted" : "")
        )
      }
    }

    if samples.count > 1 {
      lines.append("")
      lines.append("Last \(Self.duration(samples.last!.time.timeIntervalSince(samples.first!.time))) (min / median / p95 / max)")
      lines.append("  Round trip: \(Self.summary(samples.compactMap(\.uplinkRoundTripMilliseconds)))")
      lines.append("  Worst delay: \(Self.summary(samples.compactMap { s in s.worstIncoming.map { s.estimatedDelay(for: $0).totalMilliseconds } }))")
      lines.append("  Worst buffer: \(Self.summary(samples.compactMap { $0.incoming.compactMap(\.receiveBufferMilliseconds).max() }))")
      lines.append("  Worst loss in: \(Self.summary(samples.compactMap { $0.incoming.compactMap(\.lossPercent).max() }, unit: "%"))")
    }

    if !events.isEmpty {
      lines.append("")
      lines.append("Events")
      for event in events {
        let tag = event.severity == .info ? "" : " [\(event.severity.rawValue)]"
        lines.append("  \(Self.time(event.time))\(tag) \(event.message)")
      }
    }

    if !samples.isEmpty {
      lines.append("")
      lines.append("Samples (time rtt_up rtt_down worst_delay worst_buffer loss_in% kbps_out kbps_in quality)")
      for sample in samples {
        let worst = sample.worstIncoming
        let inbound = sample.incoming.compactMap(\.bitrateKbps).reduce(0, +)
        lines.append(
          [
            Self.time(sample.time),
            Self.int(sample.uplinkRoundTripMilliseconds),
            Self.int(sample.subscriber?.roundTripMilliseconds),
            Self.int(worst.map { sample.estimatedDelay(for: $0).totalMilliseconds }),
            Self.int(sample.incoming.compactMap(\.receiveBufferMilliseconds).max()),
            sample.incoming.compactMap(\.lossPercent).max().map { String(format: "%.1f", $0) } ?? "-",
            Self.int(sample.outgoing?.bitrateKbps),
            Self.int(sample.incoming.isEmpty ? nil : inbound),
            sample.localConnectionQuality,
          ].joined(separator: " ")
        )
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func path(_ transport: InlineRTCTransportStats) -> String {
    let local = transport.local?.summary ?? "?"
    let remote = transport.remote?.summary ?? "?"
    return "\(local) → \(remote)"
  }

  private static func summary(_ values: [Double], unit: String = "ms") -> String {
    guard !values.isEmpty else { return "-" }
    let sorted = values.sorted()
    func at(_ fraction: Double) -> Double {
      sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
    let format: (Double) -> String = unit == "%" ? { String(format: "%.1f%%", $0) } : { ms($0) }
    return [sorted.first!, at(0.5), at(0.95), sorted.last!].map(format).joined(separator: " / ")
  }

  static func ms(_ value: Double?) -> String {
    guard let value else { return "-" }
    if value >= 1_000 { return String(format: "%.1f s", value / 1_000) }
    return "\(Int(value.rounded())) ms"
  }

  static func percent(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.1f%%", value)
  }

  static func kbps(_ value: Double?) -> String {
    guard let value else { return "- kbps" }
    return "\(Int(value.rounded())) kbps"
  }

  private static func int(_ value: Double?) -> String {
    value.map { String(Int($0.rounded())) } ?? "-"
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds), 0)
    if total < 60 { return "\(total)s" }
    return "\(total / 60)m \(total % 60)s"
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    return formatter
  }()

  static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
  private static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }
}
