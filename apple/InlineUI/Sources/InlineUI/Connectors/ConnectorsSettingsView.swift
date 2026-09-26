import InlineKit
import SwiftUI

public struct ConnectorsSettingsView: View {
  @Bindable private var model: ConnectorSettingsModel
  @State private var pendingDisconnect: PendingConnectorDisconnect?

  private let openAuthorizationURL: @MainActor (URL) -> Void
  private let didReceiveOAuthCallback: @MainActor () -> Void
  private let configure: (@MainActor (ConnectorKind, Int64) -> Void)?
  private let initialOAuthCallbackURL: URL?

  public init(
    model: ConnectorSettingsModel,
    openAuthorizationURL: @escaping @MainActor (URL) -> Void,
    didReceiveOAuthCallback: @escaping @MainActor () -> Void = {},
    configure: (@MainActor (ConnectorKind, Int64) -> Void)? = nil,
    initialOAuthCallbackURL: URL? = nil
  ) {
    _model = Bindable(model)
    self.openAuthorizationURL = openAuthorizationURL
    self.didReceiveOAuthCallback = didReceiveOAuthCallback
    self.configure = configure
    self.initialOAuthCallbackURL = initialOAuthCallbackURL
  }

  public var body: some View {
    connectorSurface
    .overlay {
      if model.isLoading {
        ProgressView("Loading Connectors…")
      } else if model.snapshot == nil, model.errorMessage != nil {
        VStack(spacing: 12) {
          Image(systemName: "bolt.horizontal.circle")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("Couldn’t Load Connectors")
            .font(.headline)
          Button("Try Again") {
            Task { await model.load() }
          }
        }
        .padding()
      }
    }
    .task {
      await model.load()
      if let initialOAuthCallbackURL,
         await model.handleOAuthCallback(initialOAuthCallbackURL) {
        didReceiveOAuthCallback()
      }
    }
    .refreshable {
      await model.load()
    }
    .onReceive(NotificationCenter.default.publisher(for: .connectorOAuthCallback)) { notification in
      guard let url = notification.object as? URL else { return }
      Task {
        if await model.handleOAuthCallback(url) {
          didReceiveOAuthCallback()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .connectorConfigurationUpdated)) { _ in
      Task { await model.load() }
    }
    .alert(
      "Connectors",
      isPresented: Binding(
        get: { model.snapshot != nil && model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      ),
      actions: {
        Button("OK") { model.errorMessage = nil }
      },
      message: {
        Text(model.errorMessage ?? "")
      }
    )
    .confirmationDialog(
      pendingDisconnect.map { "Disconnect \($0.provider.title)?" } ?? "Disconnect connector?",
      isPresented: Binding(
        get: { pendingDisconnect != nil },
        set: { if !$0 { pendingDisconnect = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let pendingDisconnect {
        Button("Disconnect", role: .destructive) {
          self.pendingDisconnect = nil
          Task {
            await model.disconnect(
              pendingDisconnect.provider,
              from: pendingDisconnect.scope
            )
          }
        }
      }
      Button("Cancel", role: .cancel) {
        pendingDisconnect = nil
      }
    }
  }

  @ViewBuilder
  private var connectorSurface: some View {
    #if os(iOS)
    List {
      connectorSections
    }
    .listStyle(.insetGrouped)
    #else
    Form {
      connectorSections
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    #endif
  }

  @ViewBuilder
  private var connectorSections: some View {
    Section {
      ConnectorScopePicker(
        scopes: model.scopes,
        selection: $model.selectedScopeID
      )
    } header: {
      Text("Scope")
    } footer: {
      ConnectorScopeDescription(scope: model.selectedScope)
    }

    Section {
      ForEach(model.providers) { availability in
        let provider = availability.id
        let scope = model.selectedScope
        ConnectorRow(
          availability: availability,
          scope: scope,
          connection: scope.flatMap {
            model.connection(for: provider, scopeID: $0.id)
          },
          isActive: model.activeProviders.contains(provider),
          configure: configure,
          onConnect: {
            Task {
              if let url = await model.prepareOAuth(for: provider) {
                openAuthorizationURL(url)
              }
            }
          },
          onDisconnect: {
            if let scope {
              pendingDisconnect = PendingConnectorDisconnect(
                provider: provider,
                scope: scope
              )
            }
          }
        )
      }
    } header: {
      Text("Apps & Tools")
    } footer: {
      Text("Use connectors for link previews, [[ references, and actions like creating tasks.")
    }
  }

}

private struct PendingConnectorDisconnect {
  let provider: ConnectorKind
  let scope: ConnectorScope
}

private struct ConnectorRow: View {
  let availability: ConnectorAvailability
  let scope: ConnectorScope?
  let connection: ConnectorConnection?
  let isActive: Bool
  let configure: (@MainActor (ConnectorKind, Int64) -> Void)?
  let onConnect: @MainActor () -> Void
  let onDisconnect: @MainActor () -> Void

  private var provider: ConnectorKind { availability.id }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ConnectorLabel(provider: provider, connection: connection)
        .frame(maxWidth: .infinity, alignment: .leading)

      ConnectorAction(
        provider: provider,
        isAvailable: availability.isAvailable,
        isSupportedInScope: scope.map {
          $0.allowsConnections && availability.supports($0.scope)
        } ?? false,
        scope: scope,
        connection: connection,
        isActive: isActive,
        configure: configure,
        onConnect: onConnect,
        onDisconnect: onDisconnect
      )
      #if os(macOS)
      .frame(minWidth: 104, alignment: .trailing)
      #endif
    }
    #if os(macOS)
    .frame(minHeight: 38)
    #else
    .frame(minHeight: 52)
    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
    #endif
  }
}

private struct ConnectorAction: View {
  let provider: ConnectorKind
  let isAvailable: Bool
  let isSupportedInScope: Bool
  let scope: ConnectorScope?
  let connection: ConnectorConnection?
  let isActive: Bool
  let configure: (@MainActor (ConnectorKind, Int64) -> Void)?
  let onConnect: @MainActor () -> Void
  let onDisconnect: @MainActor () -> Void

  private var configurationTitle: LocalizedStringResource {
    provider == .linear ? "Choose Team" : "Choose Source"
  }

  private var configurationAccessibilityLabel: LocalizedStringResource {
    provider == .linear ? "Choose Linear team" : "Choose Notion source"
  }

  private var configurationAccessibilityHint: LocalizedStringResource {
    provider == .linear
      ? "Select the Linear team Inline uses for tasks."
      : "Select the Notion source Inline uses for tasks."
  }

  private var connectAccessibilityLabel: LocalizedStringResource {
    switch provider {
    case .notion: "Connect Notion"
    case .linear: "Connect Linear"
    case .github: "Connect GitHub"
    }
  }

  private var unsupportedScopeLabel: LocalizedStringResource {
    if scope?.allowsConnections == false {
      return "Private spaces only"
    }
    return switch scope?.scope {
    case .user: "Spaces only"
    case .space: "Personal only"
    case nil: "Unavailable"
    }
  }

  var body: some View {
    if let connection {
      if scope?.canManage == true {
        if connection.needsConfiguration,
           let spaceID = scope?.id.spaceID,
           scope?.allowsConnections == true,
           let configure {
          HStack(spacing: 6) {
            Button(configurationTitle) {
              configure(provider, spaceID)
            }
            #if os(macOS)
            .buttonStyle(.bordered)
            .controlSize(.small)
            #else
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .frame(minHeight: 44)
            #endif
            .accessibilityLabel(configurationAccessibilityLabel)
            .accessibilityHint(configurationAccessibilityHint)
            .accessibilityIdentifier("connector.\(provider.rawValue).configure")

            connectorOptionsMenu
          }
        } else {
          connectorOptionsMenu
        }
      } else if connection.needsConfiguration {
        trailingStatus("Setup required")
      }
    } else if !isAvailable {
      trailingStatus(provider == .github ? "Coming soon" : "Unavailable")
    } else if !isSupportedInScope {
      trailingStatus(unsupportedScopeLabel)
    } else if scope?.canManage == false {
      trailingStatus("Admin required")
    } else {
      Button(action: onConnect) {
        Text("Connect")
          .frame(minWidth: 52)
      }
      #if os(macOS)
      .buttonStyle(.bordered)
      .controlSize(.small)
      #else
      .buttonStyle(.plain)
      .font(.subheadline)
      .foregroundStyle(Color.accentColor)
      .frame(minWidth: 72, minHeight: 44, alignment: .trailing)
      #endif
      .disabled(isActive || scope == nil)
      .accessibilityLabel(connectAccessibilityLabel)
      .accessibilityIdentifier("connector.\(provider.rawValue).connect")
      .overlay {
        if isActive {
          ProgressView()
            .controlSize(.small)
        }
      }
      .opacity(isActive ? 0.65 : 1)
    }
  }

  private func trailingStatus(_ title: LocalizedStringResource) -> some View {
    Text(title)
      #if os(macOS)
      .font(.caption)
      #else
      .font(.subheadline)
      .frame(minHeight: 44, alignment: .trailing)
      #endif
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private var connectorOptionsMenu: some View {
    Menu {
      if let spaceID = scope?.id.spaceID,
         scope?.allowsConnections == true,
         provider != .github,
         let configure {
        Button("Configure") {
          configure(provider, spaceID)
        }
      }

      Button("Disconnect", role: .destructive, action: onDisconnect)
    } label: {
      Label("Options for \(provider.title)", systemImage: "ellipsis")
        .labelStyle(.iconOnly)
        #if os(macOS)
        .frame(width: 24, height: 18)
        #else
        .frame(width: 44, height: 44)
        #endif
        .contentShape(Rectangle())
    }
    .menuIndicator(.hidden)
    #if os(macOS)
    .controlSize(.small)
    .menuStyle(.borderlessButton)
    #endif
    .accessibilityIdentifier("connector.\(provider.rawValue).options")
    .help("Options for \(provider.title)")
  }
}

private struct ConnectorLabel: View {
  let provider: ConnectorKind
  let connection: ConnectorConnection?

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      ConnectorIcon(provider: provider)

      VStack(alignment: .leading, spacing: 2) {
        Text(provider.title)
          #if os(macOS)
          .font(.body.weight(.medium))
          #else
          .font(.body)
          #endif

        if let connection {
          ConnectorConnectionStatus(connection: connection)
        }
      }
    }
  }
}

private struct ConnectorConnectionStatus: View {
  let connection: ConnectorConnection

  var body: some View {
    HStack(spacing: 5) {
      Text("Connected")
      Text(connection.connectedAt, format: .relative(presentation: .named))

      if connection.scopeID.spaceID != nil,
         let connectedBy = connection.connectedBy {
        Text("by")
        UserAvatar(userInfo: connectedBy, size: 16)
        Text(connectedBy.user.displayName)
          .lineLimit(1)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

private struct ConnectorIcon: View {
  let provider: ConnectorKind

  private var iconSize: CGFloat {
    #if os(macOS)
    28
    #else
    32
    #endif
  }

  private var iconCornerRadius: CGFloat {
    #if os(macOS)
    7
    #else
    8
    #endif
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
        .fill(Color.primary.opacity(0.045))

      providerMark
    }
    .frame(width: iconSize, height: iconSize)
    .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var providerMark: some View {
    switch provider {
    case .notion:
      Image(provider.assetName)
        .resizable()
        .scaledToFit()
        #if os(macOS)
        .frame(width: 19, height: 19)
        #else
        .frame(width: 23, height: 23)
        #endif
    case .linear:
      Image(provider.assetName)
        .resizable()
        .scaledToFill()
        #if os(macOS)
        .frame(width: 30, height: 30)
        #else
        .frame(width: 38, height: 38)
        #endif
        .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous))
    case .github:
      Image(provider.assetName)
        .resizable()
        .scaledToFit()
        #if os(macOS)
        .frame(width: 18, height: 18)
        #else
        .frame(width: 22, height: 22)
        #endif
    }
  }
}

private struct ConnectorScopePicker: View {
  let scopes: [ConnectorScope]
  @Binding var selection: ScopeID?

  private var personalScope: ConnectorScope? {
    scopes.first { scope in
      if case .user = scope.scope { true } else { false }
    }
  }

  private var spaceScopes: [ConnectorScope] {
    scopes.filter { scope in
      if case .space = scope.scope { true } else { false }
    }
  }

  var body: some View {
    #if os(iOS)
    Picker("Connect for", selection: $selection) {
      scopeOptions
    }
    .pickerStyle(.menu)
    #else
    LabeledContent("Connect for") {
      Picker("Connect for", selection: $selection) {
        scopeOptions
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(minWidth: 160)
    }
    #endif
  }

  @ViewBuilder
  private var scopeOptions: some View {
    if let personalScope {
      Section("Private to you") {
        Text(personalScope.name)
          .tag(Optional(personalScope.id))
      }
    }

    if !spaceScopes.isEmpty {
      Section("Shared with space members") {
        ForEach(spaceScopes) { scope in
          Text(scope.name)
            .tag(Optional(scope.id))
        }
      }
    }
  }
}

private struct ConnectorScopeDescription: View {
  let scope: ConnectorScope?

  var body: some View {
    if let scope {
      switch scope.scope {
      case .user:
        Text("Only you can use this connection.")
      case let .space(space):
        if scope.allowsConnections {
          Text("Members of \(space.displayName) can use this connection.")
        } else {
          Text("Connectors are unavailable in public spaces.")
        }
      }
    }
  }

}
