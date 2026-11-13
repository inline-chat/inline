import Auth
import InlineProtocol
import RealtimeV2

/// Wrapper
public enum Api {
  public static let realtime: RealtimeV2 = {
    let realtime = RealtimeV2(
      transport: NegotiatingRealtimeTransport(
        auth: Auth.shared.handle,
        rsaPublicKeys: InlineProtocolTrustRoots.production,
        automaticallyUpgradeLegacySession: true,
        transportPreference: .stored(in: .shared)
      ),
      auth: Auth.shared.handle,
      applyUpdates: InlineApplyUpdates(),
      syncStorage: GRDBSyncStorage(),
      persistenceHandler: DefaultTransactionPersistenceHandler(),
      blockerResolver: ChatTransactionBlockerResolver(),
      storageIsReady: { AppDatabase.shared.isPersistent }
    )

    Task(priority: .utility) { @MainActor in
      await FileDownloader.shared.prepareForLaunch()
    }

    Task(priority: .background) {
      await FileNativeUploadStagingStore.shared.pruneStale()
    }

    Task(priority: .utility) {
      guard Auth.shared.handle.isLoggedIn(), AppDatabase.shared.isPersistent else { return }
      await ReservedChatIDPool.shared.scheduleRefill(realtimeV2: realtime)
    }

    Task(priority: .utility) {
      // Keep consuming connection events while the import runs, so disconnect
      // cancels old work and rearms one attempt. Ordinary updating/connected
      // cycles must not rescan the database after every incoming message.
      var importTask: Task<Void, Never>?
      defer { importTask?.cancel() }
      for await state in await realtime.connectionStates() {
        guard !Task.isCancelled else { return }
        switch state {
        case .connecting:
          importTask?.cancel()
          importTask = nil
        case .connected:
          Task(priority: .utility) { await DurableUploadCoordinator.shared.retryPendingCancellations() }
          // Once per process: resume media sends a terminated launch left in `.sending`.
          Task(priority: .userInitiated) { @MainActor in await PendingSendRecovery.recoverAfterLaunch() }
          guard importTask == nil else { continue }
          importTask = Task(priority: .utility) {
            await DialogTranslationMigration.importPending(realtime: realtime)
          }
        case .updating:
          break
        }
      }
    }

    return realtime
  }()

  /// Opens the shared persistent-storage boundary for every account-scoped
  /// producer owned by InlineKit. This keeps sidecar database work from racing
  /// ahead of the realtime admission gate after an early-launch promotion.
  public static func admitPersistentStorage() async -> Bool {
    guard await realtime.admitPersistentStorage() else { return false }
    if Auth.shared.handle.isLoggedIn() {
      await ReservedChatIDPool.shared.resume(realtimeV2: realtime)
    }
    return true
  }
}
