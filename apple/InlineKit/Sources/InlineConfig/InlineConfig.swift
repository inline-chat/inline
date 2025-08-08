public enum InlineConfig {
  public static let SentryDSN =
    "https://29d251d24fed22f6dcf9a1f1a85e80fe@o4507951796322304.ingest.us.sentry.io/4508386227716096"

  public static let realtimeServerURL: String = {
    if ProjectConfig.useProductionApi {
      return "wss://api.inline.chat/realtime"
    }

    #if targetEnvironment(simulator)
    return "ws://localhost:8000/realtime"
    #elseif DEBUG && os(iOS)
    return "ws://\(ProjectConfig.devHost):8000/realtime"
    #elseif DEBUG && os(macOS)
    return "ws://\(ProjectConfig.devHost):8000/realtime"
    #else
    return "wss://api.inline.chat/realtime"
    #endif
  }()
}
