/** Database-independent discovery seam. The scheduler owns admission, retry,
 * connection epochs and hint/replay delivery; a strategy owns discovery only.
 * Snapshots must follow the supplied committed-write fence. Never checkpoint
 * incomplete work or interpret a missing result as an unchanged account.
 */
export type RepairDiscoveryRequest = { userId: number; date: bigint }
export type RepairDiscoverySnapshot = {
  watermark: Date
  userFrontier?: number
  /** Proof that no candidate chat/space changed since this inclusive date.
   * This is NOT an access grant and says nothing about user-bucket changes. */
  resourcesUnchangedSince?: bigint
}

export interface RepairDiscovery {
  captureWatermark(): Promise<Date>
  prepare(
    requests: readonly RepairDiscoveryRequest[],
    watermark: Date,
  ): Promise<ReadonlyMap<number, RepairDiscoverySnapshot>>
  discover(
    request: RepairDiscoveryRequest,
    options: { snapshot?: RepairDiscoverySnapshot; shouldEmitHints: () => boolean },
  ): Promise<{ date?: bigint; seq?: number; updatesFound?: boolean }>
}
