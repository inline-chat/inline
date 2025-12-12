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

  public static let integrationsServerURL: String = {
    if ProjectConfig.useProductionApi {
      return "https://api.inline.chat"
    }

    #if targetEnvironment(simulator)
    return "http://127.0.0.1:8000"
    #elseif DEBUG && os(iOS)
    print(
      "This URL will not work out of the box on iOS device. Use simulator or copy this URL and open on the desktop browser that has the server running, for example: https://127.0.0.1:8000/integrations/<linear|notion>/integrate"
    )
    // UNSUPPORTED
    return "http://\(ProjectConfig.devHost):8000"
    #elseif DEBUG && os(macOS)
    return "http://127.0.0.1:8000"
    #else
    return "https://api.inline.chat"
    #endif
  }()
}
