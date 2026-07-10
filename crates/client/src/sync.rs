//! Inline-native update discovery, ordering, and bucket recovery.

use std::{
    collections::{BTreeMap, HashMap},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_util::{StreamExt, future::BoxFuture, stream};
use inline_sdk::proto;
use prost::Message as _;
use tokio::sync::{Mutex, Semaphore};

use crate::{
    BackendError, BackendResult, ClientErrorCategory, ClientEvent, ClientEventDelivery,
    ClientStore, InlineId, PendingSyncBatch, StoreError, SyncBucketKey, SyncBucketPeer,
    SyncBucketState, SyncState,
};

/// Runtime policy for Inline update discovery and bucket catch-up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SyncConfig {
    /// Safety window subtracted from the newest applied update date.
    pub last_sync_safety_gap_seconds: i64,
    /// Maximum number of bucket fetch RPCs allowed concurrently.
    pub max_concurrent_bucket_fetches: usize,
    /// Lookback used when global sync state is missing or stale.
    pub initial_lookback_seconds: i64,
    /// Age after which the global discovery cursor is reseeded.
    pub stale_state_max_age_seconds: i64,
    /// Maximum number of updates requested per catch-up slice.
    pub max_total_updates: i32,
    /// Maximum updates requested in one response page.
    pub page_limit: i32,
    /// Smaller total limit used by a bucket with no durable cursor.
    pub cold_start_total_limit: i32,
    /// Number of times to retry an EMPTY page that remains behind a realtime
    /// hint before reporting a consistency failure.
    pub inconsistent_empty_retry_attempts: u32,
    /// Delay between inconsistent EMPTY retries.
    pub inconsistent_empty_retry_delay_ms: u64,
}

impl Default for SyncConfig {
    fn default() -> Self {
        Self {
            last_sync_safety_gap_seconds: 15,
            max_concurrent_bucket_fetches: 4,
            initial_lookback_seconds: 5 * 24 * 60 * 60,
            stale_state_max_age_seconds: 14 * 24 * 60 * 60,
            max_total_updates: 1_000,
            page_limit: 200,
            cold_start_total_limit: 50,
            inconsistent_empty_retry_attempts: 3,
            inconsistent_empty_retry_delay_ms: 250,
        }
    }
}

pub(crate) trait SyncHost: Clone + Send + Sync + 'static {
    fn get_updates_state(
        &self,
        date: i64,
    ) -> BoxFuture<'static, BackendResult<proto::GetUpdatesStateResult>>;

    fn get_updates(
        &self,
        input: proto::GetUpdatesInput,
    ) -> BoxFuture<'static, BackendResult<proto::GetUpdatesResult>>;

    fn apply_sync_batch(
        &self,
        updates: Vec<proto::Update>,
        sidecars: Option<proto::UpdateSidecars>,
    ) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>>;

    /// Rebuilds authoritative current state for a bucket before a cold cursor
    /// can be advanced past history that is no longer available.
    fn repair_bucket(
        &self,
        key: SyncBucketKey,
    ) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>>;
}

#[derive(Debug)]
pub(crate) struct SyncManager {
    store: Arc<dyn ClientStore>,
    config: SyncConfig,
    bucket_locks: Mutex<HashMap<SyncBucketKey, Arc<Mutex<()>>>>,
    fetch_limiter: Arc<Semaphore>,
    sync_state_lock: Mutex<()>,
}

impl SyncManager {
    pub(crate) fn new(store: Arc<dyn ClientStore>, config: SyncConfig) -> Self {
        let max_fetches = config.max_concurrent_bucket_fetches.max(1);
        Self {
            store,
            config,
            bucket_locks: Mutex::new(HashMap::new()),
            fetch_limiter: Arc::new(Semaphore::new(max_fetches)),
            sync_state_lock: Mutex::new(()),
        }
    }

    pub(crate) async fn discover<H: SyncHost>(
        &self,
        host: &H,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let mut events = self.recover_pending_batches(host).await?;
        let state = self.prepared_sync_state().await?;
        log::debug!(
            "starting Inline update discovery from date={}",
            state.last_sync_date
        );
        let result = host.get_updates_state(state.last_sync_date).await?;
        validate_core_sync_schema(result.core_sync_schema_revision)?;
        if result.updates_found == Some(false) {
            self.update_last_sync_date(result.date).await?;
        }
        events.extend(
            self.process_bucket(host, SyncBucketKey::User, Vec::new(), None, true)
                .await?,
        );
        log::debug!(
            "finished Inline update discovery date={} events={}",
            result.date,
            events.len()
        );
        Ok(events)
    }

    pub(crate) async fn process_realtime<H: SyncHost>(
        &self,
        host: &H,
        updates: Vec<proto::Update>,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let mut events = self.recover_pending_batches(host).await?;
        let received_count = updates.len();
        let mut direct = Vec::new();
        let mut buckets = HashMap::<SyncBucketKey, Vec<proto::Update>>::new();
        let mut targets = HashMap::<SyncBucketKey, i64>::new();

        for update in updates {
            match update.update.as_ref() {
                Some(proto::update::Update::ChatHasNewUpdates(hint)) => {
                    if let Some(key) = chat_hint_bucket_key(hint) {
                        targets
                            .entry(key)
                            .and_modify(|seq| *seq = (*seq).max(i64::from(hint.update_seq)))
                            .or_insert(i64::from(hint.update_seq));
                    }
                }
                Some(proto::update::Update::SpaceHasNewUpdates(hint)) => {
                    let key = SyncBucketKey::Space {
                        space_id: InlineId::new(hint.space_id),
                    };
                    targets
                        .entry(key)
                        .and_modify(|seq| *seq = (*seq).max(i64::from(hint.update_seq)))
                        .or_insert(i64::from(hint.update_seq));
                }
                _ => {
                    let seq = update_seq(&update);
                    if seq > 0
                        && let Some(key) = bucket_key_for_update(&update)
                    {
                        buckets.entry(key).or_default().push(update);
                    } else {
                        direct.push(update);
                    }
                }
            }
        }

        if !direct.is_empty() {
            let max_date = max_update_date(&direct);
            let applied = host.apply_sync_batch(direct, None).await?;
            let applied = self
                .store
                .append_client_events(applied)
                .await
                .map_err(store_error_to_backend)?;
            self.update_last_sync_date(max_date).await?;
            events.extend(applied);
        }

        for key in targets.keys() {
            buckets.entry(*key).or_default();
        }

        let mut ordered = buckets
            .into_iter()
            .map(|(key, updates)| {
                let target = targets.get(&key).copied();
                (key, updates, target)
            })
            .collect::<Vec<_>>();
        let bucket_count = ordered.len();
        ordered.sort_by_key(|(key, _, _)| bucket_sort_key(*key));

        if let Some(user_index) = ordered
            .iter()
            .position(|(key, _, _)| *key == SyncBucketKey::User)
        {
            let (key, updates, target) = ordered.remove(user_index);
            events.extend(
                self.process_bucket(host, key, updates, target, false)
                    .await?,
            );
        }

        let concurrency = self.config.max_concurrent_bucket_fetches.max(1);
        let mut results = stream::iter(ordered)
            .map(|(key, updates, target)| async move {
                (
                    bucket_sort_key(key),
                    self.process_bucket(host, key, updates, target, false).await,
                )
            })
            .buffer_unordered(concurrency)
            .collect::<Vec<_>>()
            .await;
        results.sort_by_key(|(sort_key, _)| *sort_key);
        for (_, result) in results {
            events.extend(result?);
        }
        log::debug!(
            "processed Inline realtime batch received={received_count} buckets={bucket_count} events={}",
            events.len()
        );
        Ok(events)
    }

    async fn process_bucket<H: SyncHost>(
        &self,
        host: &H,
        key: SyncBucketKey,
        realtime_updates: Vec<proto::Update>,
        target_seq: Option<i64>,
        force_fetch: bool,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let bucket_lock = self.bucket_lock(key).await;
        let _bucket_guard = bucket_lock.lock().await;
        let mut state = self
            .store
            .sync_bucket_state(key)
            .await
            .map_err(store_error_to_backend)?;
        let mut buffered = BTreeMap::new();
        for update in realtime_updates {
            let seq = update_seq(&update);
            if seq > state.seq {
                insert_unique_update(&mut buffered, seq, update, "realtime buffer")?;
            }
        }

        let mut events = self
            .drain_contiguous(host, key, &mut state, &mut buffered)
            .await?;
        let target_seq = target_seq
            .filter(|target| *target > state.seq)
            .or_else(|| buffered.last_key_value().map(|(seq, _)| *seq));
        if !force_fetch && target_seq.is_none() && buffered.is_empty() && state.seq > 0 {
            return Ok(events);
        }

        events.extend(
            self.fetch_bucket(host, key, state, buffered, target_seq)
                .await?,
        );
        Ok(events)
    }

    async fn drain_contiguous<H: SyncHost>(
        &self,
        host: &H,
        key: SyncBucketKey,
        state: &mut SyncBucketState,
        buffered: &mut BTreeMap<i64, proto::Update>,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let mut updates = Vec::new();
        let mut next_seq = state.seq + 1;
        while let Some(update) = buffered.remove(&next_seq) {
            updates.push(update);
            next_seq += 1;
        }
        if updates.is_empty() {
            return Ok(Vec::new());
        }

        let committed = SyncBucketState {
            seq: next_seq - 1,
            date: state.date.max(max_update_date(&updates)),
        };
        let events = self
            .commit_sync_batch(host, key, committed, updates, None)
            .await?;
        self.update_last_sync_date(committed.date).await?;
        *state = committed;
        Ok(events)
    }

    async fn fetch_bucket<H: SyncHost>(
        &self,
        host: &H,
        key: SyncBucketKey,
        initial: SyncBucketState,
        buffered: BTreeMap<i64, proto::Update>,
        target_seq: Option<i64>,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let _permit = self
            .fetch_limiter
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| BackendError::new(ClientErrorCategory::Internal, "sync fetch stopped"))?;
        let mut cold_start = initial.seq == 0 || initial.date == 0;
        let mut committed_floor = initial.seq;
        let mut current_seq = initial.seq;
        let mut final_date = initial.date;
        let hard_end = target_seq.or_else(|| buffered.last_key_value().map(|(seq, _)| *seq));
        let mut buffered = buffered;
        let mut slice_end = None;
        let mut fetched = BTreeMap::<i64, proto::Update>::new();
        let mut sidecars = proto::UpdateSidecars::default();
        let mut page_count = 0_u64;
        let mut inconsistent_empty_attempts = 0_u32;
        let mut deliveries = Vec::new();

        log::debug!(
            "starting Inline bucket fetch kind={} start_seq={} target_seq={:?} cold_start={cold_start}",
            bucket_kind(key),
            current_seq,
            hard_end
        );

        loop {
            page_count += 1;
            let request_end = slice_end.or(hard_end).filter(|end| *end > current_seq);
            let response = host
                .get_updates(proto::GetUpdatesInput {
                    bucket: Some(protocol_bucket(key)),
                    start_seq: current_seq,
                    total_limit: if cold_start && slice_end.is_none() {
                        self.config.cold_start_total_limit
                    } else {
                        self.config.max_total_updates
                    },
                    seq_end: request_end.unwrap_or_default(),
                    limit: self.config.page_limit,
                    core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                })
                .await?;
            validate_core_sync_schema(response.core_sync_schema_revision)?;
            let result_type = proto::get_updates_result::ResultType::try_from(response.result_type)
                .unwrap_or(proto::get_updates_result::ResultType::Unspecified);

            if result_type == proto::get_updates_result::ResultType::TooLong {
                if response.seq <= current_seq {
                    return Err(BackendError::new(
                        ClientErrorCategory::ProtocolMismatch,
                        "bucket sync received a non-advancing TOO_LONG pointer",
                    ));
                }
                if cold_start {
                    let target_seq = response.seq;
                    let target_date = final_date.max(response.date);
                    log::warn!(
                        "repairing cold Inline bucket after TOO_LONG kind={} target_seq={target_seq}",
                        bucket_kind(key)
                    );
                    deliveries.extend(
                        self.repair_cold_bucket(host, key, target_seq, target_date)
                            .await?,
                    );
                    cold_start = false;
                    committed_floor = target_seq;
                    current_seq = target_seq;
                    final_date = target_date;
                    fetched.clear();
                    sidecars = proto::UpdateSidecars::default();
                    slice_end = None;
                    buffered.retain(|seq, _| *seq > target_seq);
                    if hard_end.is_none_or(|end| target_seq >= end) {
                        return Ok(deliveries);
                    }
                    continue;
                }
                let max_slice = current_seq + i64::from(self.config.max_total_updates);
                slice_end = Some(response.seq.min(max_slice));
                continue;
            }

            if response.seq < current_seq {
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "bucket sync server cursor moved backwards",
                ));
            }
            let previous_seq = current_seq;
            let accounting = validate_response_page(previous_seq, &response)?;
            current_seq = response.seq;
            final_date = final_date.max(response.date);
            let skipped_sequences = response
                .skipped_sequences
                .iter()
                .map(|skipped| skipped.seq)
                .collect::<std::collections::BTreeSet<_>>();
            let page_sidecars = response.sidecars;
            let page_updates = response.updates;

            let empty = result_type == proto::get_updates_result::ResultType::Empty;
            if accounting.requires_snapshot_repair {
                log::warn!(
                    "repairing Inline bucket after server-classified snapshot gap kind={} target_seq={current_seq}",
                    bucket_kind(key)
                );
                deliveries.extend(
                    self.repair_cold_bucket(host, key, current_seq, final_date)
                        .await?,
                );
                return Ok(deliveries);
            }

            if cold_start {
                if let Some(page_sidecars) = page_sidecars {
                    merge_sidecars(&mut sidecars, page_sidecars);
                }
                for update in page_updates {
                    let seq = update_seq(&update);
                    if seq > committed_floor {
                        insert_unique_update(&mut fetched, seq, update, "fetched page")?;
                    }
                }
            } else if current_seq > previous_seq {
                let mut page = BTreeMap::<i64, proto::Update>::new();
                for update in page_updates {
                    let seq = update_seq(&update);
                    insert_unique_update(&mut page, seq, update, "fetched page")?;
                }
                let buffered_sequences = buffered
                    .range(..=current_seq)
                    .map(|(seq, _)| *seq)
                    .collect::<Vec<_>>();
                for seq in &buffered_sequences {
                    if skipped_sequences.contains(seq) {
                        return Err(BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "realtime update conflicted with a server-classified skipped sequence",
                        ));
                    }
                    if let Some(update) = buffered.get(seq).cloned() {
                        insert_unique_update(&mut page, *seq, update, "fetched/realtime merge")?;
                    }
                }
                let updates = page.into_values().collect::<Vec<_>>();
                let committed = SyncBucketState {
                    seq: current_seq,
                    date: final_date.max(max_update_date(&updates)),
                };
                let has_sidecars = page_sidecars.as_ref().is_some_and(has_sidecars);
                let page_deliveries = self
                    .commit_sync_batch(
                        host,
                        key,
                        committed,
                        updates,
                        has_sidecars.then_some(page_sidecars).flatten(),
                    )
                    .await?;
                self.update_last_sync_date(committed.date).await?;
                deliveries.extend(page_deliveries);
                for seq in buffered_sequences {
                    buffered.remove(&seq);
                }
                committed_floor = committed.seq;
            }
            let final_page = response.r#final.unwrap_or(false) || empty;
            if final_page && hard_end.is_some_and(|target| current_seq < target) {
                if current_seq > previous_seq {
                    inconsistent_empty_attempts = 0;
                }
                inconsistent_empty_attempts += 1;
                if inconsistent_empty_attempts <= self.config.inconsistent_empty_retry_attempts {
                    log::warn!(
                        "retrying Inline final page behind hint kind={} server_seq={} target_seq={:?} attempt={}",
                        bucket_kind(key),
                        current_seq,
                        hard_end,
                        inconsistent_empty_attempts
                    );
                    if self.config.inconsistent_empty_retry_delay_ms > 0 {
                        tokio::time::sleep(Duration::from_millis(
                            self.config.inconsistent_empty_retry_delay_ms,
                        ))
                        .await;
                    }
                    continue;
                }
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "bucket sync final response remained behind the requested target",
                ));
            }
            inconsistent_empty_attempts = 0;
            if current_seq == previous_seq && !final_page {
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "bucket sync received a non-progress response",
                ));
            }
            if let Some(end) = slice_end
                && current_seq >= end
            {
                slice_end = None;
                if hard_end.is_some_and(|target| current_seq < target) {
                    continue;
                }
            }
            if hard_end.is_some_and(|target| current_seq >= target) || final_page {
                break;
            }
        }

        if !cold_start {
            log::debug!(
                "finished incremental Inline bucket fetch kind={} pages={page_count} end_seq={} events={}",
                bucket_kind(key),
                committed_floor,
                deliveries.len()
            );
            return Ok(deliveries);
        }

        for (seq, update) in buffered {
            if seq > committed_floor && seq <= current_seq {
                insert_unique_update(&mut fetched, seq, update, "fetched/realtime merge")?;
            }
        }
        let updates = fetched.into_values().collect::<Vec<_>>();
        let max_delivered_seq = updates.iter().map(update_seq).max().unwrap_or(initial.seq);
        if current_seq > max_delivered_seq {
            log::warn!(
                "advancing cold Inline bucket pointer with explicit sequence accounting kind={} delivered_seq={max_delivered_seq} pointer_seq={current_seq}",
                bucket_kind(key)
            );
        }
        let committed = SyncBucketState {
            seq: current_seq,
            date: final_date.max(max_update_date(&updates)),
        };
        if cold_start {
            let events = self
                .repair_cold_bucket(host, key, committed.seq, committed.date)
                .await?;
            log::debug!(
                "finished cold Inline bucket snapshot kind={} pages={page_count} end_seq={} events={}",
                bucket_kind(key),
                committed.seq,
                events.len()
            );
            deliveries.extend(events);
            return Ok(deliveries);
        }
        let has_sidecars = has_sidecars(&sidecars);
        let update_count = updates.len();
        let events = self
            .commit_sync_batch(
                host,
                key,
                committed,
                updates,
                has_sidecars.then_some(sidecars),
            )
            .await?;
        self.update_last_sync_date(committed.date).await?;
        log::debug!(
            "finished Inline bucket fetch kind={} pages={page_count} end_seq={} updates={} events={}",
            bucket_kind(key),
            committed.seq,
            update_count,
            events.len()
        );
        deliveries.extend(events);
        Ok(deliveries)
    }

    async fn repair_cold_bucket<H: SyncHost>(
        &self,
        host: &H,
        key: SyncBucketKey,
        target_seq: i64,
        target_date: i64,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let events = host.repair_bucket(key).await?;
        self.commit_cold_pointer(key, target_seq, target_date, events)
            .await
    }

    async fn commit_cold_pointer(
        &self,
        key: SyncBucketKey,
        target_seq: i64,
        target_date: i64,
        events: Vec<ClientEvent>,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let committed = SyncBucketState {
            seq: target_seq,
            date: target_date,
        };
        // Cold repair has already rebuilt its durable snapshot. Commit the
        // resulting events and cursor together; an intermediate empty journal
        // could otherwise recover the cursor without reproducing these events.
        let deliveries = self
            .store
            .commit_pending_sync_batch_with_events(key, committed, events)
            .await
            .map_err(store_error_to_backend)?;
        self.update_last_sync_date(committed.date).await?;
        Ok(deliveries)
    }

    async fn commit_sync_batch<H: SyncHost>(
        &self,
        host: &H,
        key: SyncBucketKey,
        committed_state: SyncBucketState,
        updates: Vec<proto::Update>,
        sidecars: Option<proto::UpdateSidecars>,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        validate_journal_updates(&updates)?;
        let payload = encode_pending_payload(&updates, sidecars.as_ref())?;
        self.store
            .save_pending_sync_batch(PendingSyncBatch {
                key,
                committed_state,
                payload,
            })
            .await
            .map_err(store_error_to_backend)?;
        let events = match host.apply_sync_batch(updates, sidecars).await {
            Ok(events) => events,
            Err(error) => {
                if is_permanent_sync_error(&error) {
                    self.store
                        .discard_pending_sync_batch(key)
                        .await
                        .map_err(store_error_to_backend)?;
                }
                return Err(error);
            }
        };
        let deliveries = self
            .store
            .commit_pending_sync_batch_with_events(key, committed_state, events)
            .await
            .map_err(store_error_to_backend)?;
        Ok(deliveries)
    }

    async fn recover_pending_batches<H: SyncHost>(
        &self,
        host: &H,
    ) -> BackendResult<Vec<ClientEventDelivery>> {
        let batches = self
            .store
            .pending_sync_batches()
            .await
            .map_err(store_error_to_backend)?;
        let mut events = Vec::new();
        let mut refetch = BTreeMap::<(u8, i64), (SyncBucketKey, i64)>::new();
        for batch in batches {
            let decoded = decode_pending_payload(&batch.payload).and_then(|(updates, sidecars)| {
                validate_journal_updates(&updates)?;
                Ok((updates, sidecars))
            });
            let (updates, sidecars) = match decoded {
                Ok(decoded) => decoded,
                Err(error) if is_permanent_sync_error(&error) => {
                    log::warn!(
                        "discarding incompatible Inline sync journal kind={} target_seq={}",
                        bucket_kind(batch.key),
                        batch.committed_state.seq
                    );
                    self.store
                        .discard_pending_sync_batch(batch.key)
                        .await
                        .map_err(store_error_to_backend)?;
                    refetch.insert(
                        bucket_sort_key(batch.key),
                        (batch.key, batch.committed_state.seq),
                    );
                    continue;
                }
                Err(error) => return Err(error),
            };
            let applied = match host.apply_sync_batch(updates, sidecars).await {
                Ok(applied) => applied,
                Err(error) if is_permanent_sync_error(&error) => {
                    log::warn!(
                        "discarding permanently failing Inline sync journal kind={} target_seq={}",
                        bucket_kind(batch.key),
                        batch.committed_state.seq
                    );
                    self.store
                        .discard_pending_sync_batch(batch.key)
                        .await
                        .map_err(store_error_to_backend)?;
                    refetch.insert(
                        bucket_sort_key(batch.key),
                        (batch.key, batch.committed_state.seq),
                    );
                    continue;
                }
                Err(error) => return Err(error),
            };
            events.extend(
                self.store
                    .commit_pending_sync_batch_with_events(
                        batch.key,
                        batch.committed_state,
                        applied,
                    )
                    .await
                    .map_err(store_error_to_backend)?,
            );
            self.update_last_sync_date(batch.committed_state.date)
                .await?;
        }
        for (_, (key, target_seq)) in refetch {
            events.extend(
                self.process_bucket(host, key, Vec::new(), Some(target_seq), true)
                    .await?,
            );
        }
        Ok(events)
    }

    async fn bucket_lock(&self, key: SyncBucketKey) -> Arc<Mutex<()>> {
        let mut locks = self.bucket_locks.lock().await;
        locks
            .entry(key)
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    async fn prepared_sync_state(&self) -> BackendResult<SyncState> {
        let mut state = self
            .store
            .sync_state()
            .await
            .map_err(store_error_to_backend)?;
        let now = now_seconds();
        if state.last_sync_date == 0
            || now.saturating_sub(state.last_sync_date) > self.config.stale_state_max_age_seconds
        {
            state.last_sync_date = now.saturating_sub(self.config.initial_lookback_seconds);
            self.store
                .save_sync_state(state)
                .await
                .map_err(store_error_to_backend)?;
        }
        Ok(state)
    }

    async fn update_last_sync_date(&self, max_applied_date: i64) -> BackendResult<()> {
        if max_applied_date <= 0 {
            return Ok(());
        }
        let _guard = self.sync_state_lock.lock().await;
        let current = self
            .store
            .sync_state()
            .await
            .map_err(store_error_to_backend)?;
        let proposed = max_applied_date.saturating_sub(self.config.last_sync_safety_gap_seconds);
        if proposed <= current.last_sync_date {
            return Ok(());
        }
        self.store
            .save_sync_state(SyncState {
                last_sync_date: proposed,
            })
            .await
            .map_err(store_error_to_backend)
    }
}

fn bucket_key_for_update(update: &proto::Update) -> Option<SyncBucketKey> {
    use proto::update::Update;
    match update.update.as_ref()? {
        Update::NewMessage(value) => value
            .message
            .as_ref()?
            .peer_id
            .as_ref()
            .and_then(chat_bucket),
        Update::EditMessage(value) => value
            .message
            .as_ref()?
            .peer_id
            .as_ref()
            .and_then(chat_bucket),
        Update::DeleteMessages(value) => value.peer_id.as_ref().and_then(chat_bucket),
        Update::ClearChatHistory(value) => match value.target.as_ref()? {
            proto::update_clear_chat_history::Target::PeerId(peer) => chat_bucket(peer),
            proto::update_clear_chat_history::Target::SpaceId(space_id) => {
                Some(SyncBucketKey::Space {
                    space_id: InlineId::new(*space_id),
                })
            }
        },
        Update::MessageAttachment(value) => value.peer_id.as_ref().and_then(chat_bucket),
        Update::UpdateReaction(value) => value
            .reaction
            .as_ref()
            .map(|reaction| chat_key(reaction.chat_id)),
        Update::DeleteReaction(value) => Some(chat_key(value.chat_id)),
        Update::DeleteChat(value) => value.peer_id.as_ref().and_then(chat_bucket),
        Update::MarkAsUnread(value) => value.peer_id.as_ref().and_then(chat_bucket),
        Update::SpaceMemberAdd(value) => value
            .member
            .as_ref()
            .map(|member| space_key(member.space_id)),
        Update::SpaceMemberDelete(value) => Some(space_key(value.space_id)),
        Update::SpaceMemberUpdate(value) => value
            .member
            .as_ref()
            .map(|member| space_key(member.space_id)),
        Update::JoinSpace(_)
        | Update::UpdateUserStatus(_)
        | Update::UpdateUserSettings(_)
        | Update::UpdatedUser(_)
        | Update::DialogArchived(_)
        | Update::DialogNotificationSettings(_)
        | Update::DialogFollowMode(_)
        | Update::UpdateReadMaxId(_)
        | Update::ChatOpen(_) => Some(SyncBucketKey::User),
        Update::NewChat(value) => value.chat.as_ref()?.peer_id.as_ref().and_then(chat_bucket),
        Update::ChatMoved(value) => value.chat.as_ref()?.peer_id.as_ref().and_then(chat_bucket),
        Update::ParticipantAdd(value) => Some(chat_key(value.chat_id)),
        Update::ParticipantDelete(value) => Some(chat_key(value.chat_id)),
        Update::ParticipantGroupAdd(value) => Some(chat_key(value.chat_id)),
        Update::ParticipantGroupDelete(value) => Some(chat_key(value.chat_id)),
        Update::ChatVisibility(value) => Some(chat_key(value.chat_id)),
        Update::ChatInfo(value) => Some(chat_key(value.chat_id)),
        Update::PinnedMessages(value) => value.peer_id.as_ref().and_then(chat_bucket),
        Update::ChatSkipPts(value) => Some(chat_key(value.chat_id)),
        Update::SpaceSettings(value) => Some(space_key(value.space_id)),
        _ => None,
    }
}

fn chat_hint_bucket_key(hint: &proto::UpdateChatHasNewUpdates) -> Option<SyncBucketKey> {
    hint.peer_id
        .as_ref()
        .and_then(chat_bucket)
        .or_else(|| (hint.chat_id != 0).then(|| chat_key(hint.chat_id)))
}

fn chat_bucket(peer: &proto::Peer) -> Option<SyncBucketKey> {
    let peer = match peer.r#type.as_ref()? {
        proto::peer::Type::User(user) => SyncBucketPeer::User {
            user_id: InlineId::new(user.user_id),
        },
        proto::peer::Type::Chat(chat) => SyncBucketPeer::Chat {
            chat_id: InlineId::new(chat.chat_id),
        },
    };
    Some(SyncBucketKey::Chat { peer })
}

fn chat_key(chat_id: i64) -> SyncBucketKey {
    SyncBucketKey::Chat {
        peer: SyncBucketPeer::Chat {
            chat_id: InlineId::new(chat_id),
        },
    }
}

fn space_key(space_id: i64) -> SyncBucketKey {
    SyncBucketKey::Space {
        space_id: InlineId::new(space_id),
    }
}

fn protocol_bucket(key: SyncBucketKey) -> proto::UpdateBucket {
    let r#type = match key {
        SyncBucketKey::User => proto::update_bucket::Type::User(proto::UpdateBucketUser {}),
        SyncBucketKey::Space { space_id } => {
            proto::update_bucket::Type::Space(proto::UpdateBucketSpace {
                space_id: space_id.get(),
            })
        }
        SyncBucketKey::Chat { peer } => {
            let r#type = match peer {
                SyncBucketPeer::User { user_id } => {
                    proto::input_peer::Type::User(proto::InputPeerUser {
                        user_id: user_id.get(),
                    })
                }
                SyncBucketPeer::Chat { chat_id } => {
                    proto::input_peer::Type::Chat(proto::InputPeerChat {
                        chat_id: chat_id.get(),
                    })
                }
            };
            proto::update_bucket::Type::Chat(proto::UpdateBucketChat {
                peer_id: Some(proto::InputPeer {
                    r#type: Some(r#type),
                }),
            })
        }
    };
    proto::UpdateBucket {
        r#type: Some(r#type),
    }
}

fn update_seq(update: &proto::Update) -> i64 {
    i64::from(update.seq.unwrap_or_default())
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct PageAccounting {
    requires_snapshot_repair: bool,
}

fn validate_response_page(
    previous_seq: i64,
    response: &proto::GetUpdatesResult,
) -> BackendResult<PageAccounting> {
    use proto::get_updates_result::ResultType;
    use proto::sync_skipped_sequence::Reason;

    let result_type = ResultType::try_from(response.result_type).map_err(|_| {
        BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            "bucket sync response used an unknown result type",
        )
    })?;
    if !matches!(result_type, ResultType::Slice | ResultType::Empty) {
        return Err(BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            "bucket sync response used an invalid page result type",
        ));
    }
    if response.seq < previous_seq {
        return Err(BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            "bucket sync page cursor moved backwards",
        ));
    }

    let mut accounted = BTreeMap::<i64, &'static str>::new();
    for update in &response.updates {
        let seq = update_seq(update);
        validate_page_sequence(previous_seq, response.seq, seq)?;
        if accounted.insert(seq, "update").is_some() {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "bucket sync page contained a duplicate sequence",
            ));
        }
    }

    let mut requires_snapshot_repair = false;
    for skipped in &response.skipped_sequences {
        validate_page_sequence(previous_seq, response.seq, skipped.seq)?;
        let reason = Reason::try_from(skipped.reason).map_err(|_| {
            BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "bucket sync page used an unknown skipped-sequence reason",
            )
        })?;
        match reason {
            Reason::IrrelevantToBucket => {}
            Reason::SnapshotRepairRequired => requires_snapshot_repair = true,
            Reason::Unspecified => {
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "bucket sync page used an unspecified skipped-sequence reason",
                ));
            }
        }
        if accounted.insert(skipped.seq, "skip").is_some() {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "bucket sync page accounted for one sequence more than once",
            ));
        }
    }

    let delta = response.seq.saturating_sub(previous_seq);
    let accounted_count = i64::try_from(accounted.len()).map_err(|_| {
        BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            "bucket sync page sequence count overflowed",
        )
    })?;
    if accounted_count != delta {
        return Err(BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            "bucket sync page did not account for every advanced sequence",
        ));
    }

    Ok(PageAccounting {
        requires_snapshot_repair,
    })
}

fn validate_page_sequence(previous_seq: i64, response_seq: i64, seq: i64) -> BackendResult<()> {
    if seq <= previous_seq || seq > response_seq {
        return Err(BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            "bucket sync page contained a sequence outside its cursor envelope",
        ));
    }
    Ok(())
}

fn insert_unique_update(
    updates: &mut BTreeMap<i64, proto::Update>,
    seq: i64,
    update: proto::Update,
    source: &'static str,
) -> BackendResult<()> {
    if let Some(existing) = updates.get(&seq) {
        if existing == &update {
            return Ok(());
        }
        return Err(BackendError::new(
            ClientErrorCategory::ProtocolMismatch,
            format!("conflicting Inline updates shared sequence {seq} in {source}"),
        ));
    }
    updates.insert(seq, update);
    Ok(())
}

fn validate_journal_updates(updates: &[proto::Update]) -> BackendResult<()> {
    for update in updates {
        if update_seq(update) <= 0 {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "lossless sync journal contained an unsequenced update",
            ));
        }
        match update.update.as_ref() {
            Some(proto::update::Update::ChatHasNewUpdates(_))
            | Some(proto::update::Update::SpaceHasNewUpdates(_)) => {
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "lossless sync journal contained a realtime hint",
                ));
            }
            Some(_) => {}
            None => {
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "lossless sync journal contained an unknown or missing update payload",
                ));
            }
        }
    }
    Ok(())
}

fn is_permanent_sync_error(error: &BackendError) -> bool {
    matches!(
        error.category,
        ClientErrorCategory::ProtocolMismatch | ClientErrorCategory::Unsupported
    )
}

fn max_update_date(updates: &[proto::Update]) -> i64 {
    updates
        .iter()
        .filter_map(|update| update.date)
        .max()
        .unwrap_or_default()
}

fn merge_sidecars(target: &mut proto::UpdateSidecars, page: proto::UpdateSidecars) {
    target.users.extend(page.users);
    target.chats.extend(page.chats);
    target.dialogs.extend(page.dialogs);
    target.spaces.extend(page.spaces);
    target.user_groups.extend(page.user_groups);
}

fn has_sidecars(sidecars: &proto::UpdateSidecars) -> bool {
    !sidecars.users.is_empty()
        || !sidecars.chats.is_empty()
        || !sidecars.dialogs.is_empty()
        || !sidecars.spaces.is_empty()
        || !sidecars.user_groups.is_empty()
}

fn bucket_sort_key(key: SyncBucketKey) -> (u8, i64) {
    match key {
        SyncBucketKey::User => (0, 0),
        SyncBucketKey::Space { space_id } => (1, space_id.get()),
        SyncBucketKey::Chat {
            peer: SyncBucketPeer::User { user_id },
        } => (2, user_id.get()),
        SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat { chat_id },
        } => (3, chat_id.get()),
    }
}

fn bucket_kind(key: SyncBucketKey) -> &'static str {
    match key {
        SyncBucketKey::User => "user",
        SyncBucketKey::Space { .. } => "space",
        SyncBucketKey::Chat { .. } => "chat",
    }
}

fn store_error_to_backend(error: StoreError) -> BackendError {
    BackendError::new(error.category, error.message)
}

fn validate_core_sync_schema(server_revision: u32) -> BackendResult<()> {
    if server_revision == crate::CORE_SYNC_SCHEMA_REVISION {
        return Ok(());
    }
    Err(BackendError::new(
        ClientErrorCategory::ProtocolMismatch,
        format!(
            "incompatible Inline sync schema: client={} server={server_revision}",
            crate::CORE_SYNC_SCHEMA_REVISION
        ),
    ))
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

const PENDING_SYNC_PAYLOAD_MAGIC: &[u8; 4] = b"ISB1";
const MAX_PENDING_SYNC_ITEMS: usize = 100_000;
const MAX_PENDING_SYNC_ITEM_BYTES: usize = 64 * 1024 * 1024;

fn encode_pending_payload(
    updates: &[proto::Update],
    sidecars: Option<&proto::UpdateSidecars>,
) -> BackendResult<Vec<u8>> {
    if updates.len() > MAX_PENDING_SYNC_ITEMS {
        return Err(BackendError::new(
            ClientErrorCategory::Internal,
            "sync batch is too large to journal",
        ));
    }
    let mut payload = Vec::new();
    payload.extend_from_slice(PENDING_SYNC_PAYLOAD_MAGIC);
    append_u32(&mut payload, updates.len())?;
    for update in updates {
        let encoded = update.encode_to_vec();
        append_bytes(&mut payload, &encoded)?;
    }
    match sidecars {
        Some(sidecars) => {
            payload.push(1);
            append_bytes(&mut payload, &sidecars.encode_to_vec())?;
        }
        None => payload.push(0),
    }
    Ok(payload)
}

fn decode_pending_payload(
    payload: &[u8],
) -> BackendResult<(Vec<proto::Update>, Option<proto::UpdateSidecars>)> {
    if !payload.starts_with(PENDING_SYNC_PAYLOAD_MAGIC) {
        return Err(invalid_pending_payload("unsupported journal version"));
    }
    let mut offset = PENDING_SYNC_PAYLOAD_MAGIC.len();
    let count = read_u32(payload, &mut offset)?;
    if count > MAX_PENDING_SYNC_ITEMS {
        return Err(invalid_pending_payload("update count exceeds safety limit"));
    }
    let mut updates = Vec::with_capacity(count);
    for _ in 0..count {
        let bytes = read_bytes(payload, &mut offset)?;
        updates.push(
            proto::Update::decode(bytes)
                .map_err(|_| invalid_pending_payload("update protobuf is invalid"))?,
        );
    }
    let sidecars = match payload.get(offset).copied() {
        Some(0) => {
            offset += 1;
            None
        }
        Some(1) => {
            offset += 1;
            let bytes = read_bytes(payload, &mut offset)?;
            Some(
                proto::UpdateSidecars::decode(bytes)
                    .map_err(|_| invalid_pending_payload("sidecars protobuf is invalid"))?,
            )
        }
        _ => return Err(invalid_pending_payload("sidecars flag is invalid")),
    };
    if offset != payload.len() {
        return Err(invalid_pending_payload("journal has trailing bytes"));
    }
    Ok((updates, sidecars))
}

fn append_u32(payload: &mut Vec<u8>, value: usize) -> BackendResult<()> {
    let value = u32::try_from(value).map_err(|_| {
        BackendError::new(
            ClientErrorCategory::Internal,
            "sync journal length exceeds u32",
        )
    })?;
    payload.extend_from_slice(&value.to_le_bytes());
    Ok(())
}

fn append_bytes(payload: &mut Vec<u8>, bytes: &[u8]) -> BackendResult<()> {
    if bytes.len() > MAX_PENDING_SYNC_ITEM_BYTES {
        return Err(BackendError::new(
            ClientErrorCategory::Internal,
            "sync journal item exceeds safety limit",
        ));
    }
    append_u32(payload, bytes.len())?;
    payload.extend_from_slice(bytes);
    Ok(())
}

fn read_u32(payload: &[u8], offset: &mut usize) -> BackendResult<usize> {
    let end = offset.saturating_add(4);
    let bytes = payload
        .get(*offset..end)
        .ok_or_else(|| invalid_pending_payload("journal is truncated"))?;
    *offset = end;
    Ok(u32::from_le_bytes(
        bytes
            .try_into()
            .map_err(|_| invalid_pending_payload("length is invalid"))?,
    ) as usize)
}

fn read_bytes<'a>(payload: &'a [u8], offset: &mut usize) -> BackendResult<&'a [u8]> {
    let length = read_u32(payload, offset)?;
    if length > MAX_PENDING_SYNC_ITEM_BYTES {
        return Err(invalid_pending_payload("journal item exceeds safety limit"));
    }
    let end = offset.saturating_add(length);
    let bytes = payload
        .get(*offset..end)
        .ok_or_else(|| invalid_pending_payload("journal item is truncated"))?;
    *offset = end;
    Ok(bytes)
}

fn invalid_pending_payload(message: &'static str) -> BackendError {
    BackendError::new(
        ClientErrorCategory::ProtocolMismatch,
        format!("invalid pending sync journal: {message}"),
    )
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        sync::{
            Arc,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
    };

    use super::*;
    use crate::InMemoryStore;

    #[derive(Clone, Debug)]
    struct FakeHost {
        state: proto::GetUpdatesStateResult,
        responses: Arc<Mutex<VecDeque<BackendResult<proto::GetUpdatesResult>>>>,
        requests: Arc<Mutex<Vec<proto::GetUpdatesInput>>>,
        applied: Arc<Mutex<Vec<Vec<proto::Update>>>>,
        repaired_buckets: Arc<Mutex<Vec<SyncBucketKey>>>,
        fail_apply: Arc<AtomicBool>,
        fetch_delay_ms: u64,
        fetches_in_flight: Arc<AtomicUsize>,
        max_fetches_in_flight: Arc<AtomicUsize>,
    }

    impl FakeHost {
        fn new(responses: Vec<proto::GetUpdatesResult>) -> Self {
            Self {
                state: proto::GetUpdatesStateResult {
                    date: 100,
                    updates_found: Some(true),
                    core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                },
                responses: Arc::new(Mutex::new(
                    responses.into_iter().map(Ok).collect::<VecDeque<_>>(),
                )),
                requests: Arc::new(Mutex::new(Vec::new())),
                applied: Arc::new(Mutex::new(Vec::new())),
                repaired_buckets: Arc::new(Mutex::new(Vec::new())),
                fail_apply: Arc::new(AtomicBool::new(false)),
                fetch_delay_ms: 0,
                fetches_in_flight: Arc::new(AtomicUsize::new(0)),
                max_fetches_in_flight: Arc::new(AtomicUsize::new(0)),
            }
        }

        fn failing_apply(mut self) -> Self {
            self.fail_apply = Arc::new(AtomicBool::new(true));
            self
        }

        fn with_fetch_delay(mut self, delay_ms: u64) -> Self {
            self.fetch_delay_ms = delay_ms;
            self
        }
    }

    impl SyncHost for FakeHost {
        fn get_updates_state(
            &self,
            _date: i64,
        ) -> BoxFuture<'static, BackendResult<proto::GetUpdatesStateResult>> {
            let state = self.state.clone();
            Box::pin(async move { Ok(state) })
        }

        fn get_updates(
            &self,
            input: proto::GetUpdatesInput,
        ) -> BoxFuture<'static, BackendResult<proto::GetUpdatesResult>> {
            let host = self.clone();
            Box::pin(async move {
                let in_flight = host.fetches_in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                host.max_fetches_in_flight
                    .fetch_max(in_flight, Ordering::SeqCst);
                if host.fetch_delay_ms > 0 {
                    tokio::time::sleep(std::time::Duration::from_millis(host.fetch_delay_ms)).await;
                }
                host.requests.lock().await.push(input);
                let response = host.responses.lock().await.pop_front().unwrap_or_else(|| {
                    Err(BackendError::new(
                        ClientErrorCategory::Internal,
                        "missing fake getUpdates response",
                    ))
                });
                host.fetches_in_flight.fetch_sub(1, Ordering::SeqCst);
                response
            })
        }

        fn apply_sync_batch(
            &self,
            updates: Vec<proto::Update>,
            _sidecars: Option<proto::UpdateSidecars>,
        ) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
            let host = self.clone();
            Box::pin(async move {
                if host.fail_apply.load(Ordering::Relaxed) {
                    return Err(BackendError::new(
                        ClientErrorCategory::Internal,
                        "fake apply failure",
                    ));
                }
                host.applied.lock().await.push(updates.clone());
                Ok(updates
                    .iter()
                    .filter_map(|update| match update.update.as_ref() {
                        Some(proto::update::Update::NewMessage(update)) => {
                            let message = update.message.as_ref()?;
                            Some(ClientEvent::MessageUpserted {
                                chat_id: InlineId::new(message.chat_id),
                                message_id: InlineId::new(message.id),
                            })
                        }
                        _ => None,
                    })
                    .collect())
            })
        }

        fn repair_bucket(
            &self,
            key: SyncBucketKey,
        ) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
            let host = self.clone();
            Box::pin(async move {
                host.repaired_buckets.lock().await.push(key);
                Ok(Vec::new())
            })
        }
    }

    #[tokio::test]
    async fn hint_only_recovery_pages_to_target_and_persists_cursor() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        store
            .save_sync_bucket_state(key, SyncBucketState { seq: 1, date: 10 })
            .await
            .unwrap();
        let host = FakeHost::new(vec![
            updates_result(vec![message_update(2, 20, 7, 102)], 2, 20, false),
            updates_result(vec![message_update(3, 30, 7, 103)], 3, 30, true),
        ]);
        let sync = SyncManager::new(store.clone(), SyncConfig::default());

        let events = sync
            .process_realtime(&host, vec![chat_hint(7, 3)])
            .await
            .unwrap();

        assert_eq!(events.len(), 2);
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 3, date: 30 }
        );
        let requests = host.requests.lock().await;
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].start_seq, 1);
        assert_eq!(requests[0].seq_end, 3);
        assert_eq!(requests[1].start_seq, 2);
        assert_eq!(requests[1].seq_end, 3);
    }

    #[tokio::test]
    async fn warm_catchup_commits_progress_across_more_than_128_pages() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        store
            .save_sync_bucket_state(key, SyncBucketState { seq: 1, date: 10 })
            .await
            .unwrap();
        let responses = (2..=131)
            .map(|seq| {
                updates_result(
                    vec![message_update(seq, i64::from(seq), 7, i64::from(seq) + 100)],
                    i64::from(seq),
                    i64::from(seq),
                    seq == 131,
                )
            })
            .collect::<Vec<_>>();
        let host = FakeHost::new(responses);
        let sync = SyncManager::new(store.clone(), SyncConfig::default());

        let events = sync
            .process_realtime(&host, vec![chat_hint(7, 131)])
            .await
            .unwrap();

        assert_eq!(events.len(), 130);
        assert_eq!(host.requests.lock().await.len(), 130);
        assert_eq!(host.applied.lock().await.len(), 130);
        assert_eq!(store.sync_bucket_state(key).await.unwrap().seq, 131);
        assert!(store.pending_sync_batches().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn gap_recovery_merges_buffered_realtime_update_before_commit() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        store
            .save_sync_bucket_state(key, SyncBucketState { seq: 1, date: 10 })
            .await
            .unwrap();
        let host = FakeHost::new(vec![
            updates_result(vec![message_update(2, 20, 7, 102)], 2, 20, false),
            updates_result(vec![message_update(3, 30, 7, 103)], 3, 30, true),
        ]);
        let sync = SyncManager::new(store.clone(), SyncConfig::default());

        sync.process_realtime(&host, vec![message_update(3, 30, 7, 103)])
            .await
            .unwrap();

        let applied = host.applied.lock().await;
        assert_eq!(applied.len(), 2);
        assert_eq!(
            applied
                .iter()
                .flat_map(|batch| batch.iter().map(update_seq))
                .collect::<Vec<_>>(),
            vec![2, 3]
        );
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 3, date: 30 }
        );
    }

    #[tokio::test]
    async fn apply_failure_does_not_advance_bucket_cursor() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        store
            .save_sync_bucket_state(key, SyncBucketState { seq: 1, date: 10 })
            .await
            .unwrap();
        let host = FakeHost::new(vec![updates_result(
            vec![message_update(2, 20, 7, 101)],
            2,
            20,
            true,
        )])
        .failing_apply();
        let sync = SyncManager::new(store.clone(), SyncConfig::default());

        let error = sync
            .process_realtime(&host, vec![chat_hint(7, 2)])
            .await
            .unwrap_err();

        assert_eq!(error.category, ClientErrorCategory::Internal);
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 1, date: 10 }
        );
        assert_eq!(store.pending_sync_batches().await.unwrap().len(), 1);

        host.fail_apply.store(false, Ordering::Relaxed);
        let recovered = sync.process_realtime(&host, Vec::new()).await.unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 2, date: 20 }
        );
        assert!(store.pending_sync_batches().await.unwrap().is_empty());
    }

    #[test]
    fn pending_sync_payload_round_trips_updates_and_sidecars() {
        let updates = vec![message_update(2, 20, 7, 102)];
        let sidecars = proto::UpdateSidecars {
            users: vec![proto::User {
                id: 42,
                ..Default::default()
            }],
            ..Default::default()
        };
        let payload = encode_pending_payload(&updates, Some(&sidecars)).unwrap();

        let (decoded_updates, decoded_sidecars) = decode_pending_payload(&payload).unwrap();
        assert_eq!(decoded_updates, updates);
        assert_eq!(decoded_sidecars, Some(sidecars));
    }

    #[tokio::test]
    async fn incompatible_pending_journal_is_discarded_and_refetched_without_advancing_first() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        store
            .save_sync_bucket_state(key, SyncBucketState { seq: 1, date: 10 })
            .await
            .unwrap();
        let invalid = proto::Update {
            seq: Some(2),
            date: Some(20),
            update: None,
        };
        store
            .save_pending_sync_batch(PendingSyncBatch {
                key,
                committed_state: SyncBucketState { seq: 2, date: 20 },
                payload: encode_pending_payload(&[invalid], None).unwrap(),
            })
            .await
            .unwrap();
        let host = FakeHost::new(vec![updates_result(
            vec![message_update(2, 20, 7, 102)],
            2,
            20,
            true,
        )]);
        let sync = SyncManager::new(store.clone(), SyncConfig::default());

        let events = sync.process_realtime(&host, Vec::new()).await.unwrap();

        assert_eq!(events.len(), 1);
        assert_eq!(host.requests.lock().await.len(), 1);
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 2, date: 20 }
        );
        assert!(store.pending_sync_batches().await.unwrap().is_empty());
    }

    #[test]
    fn page_envelope_rejects_missing_duplicate_and_out_of_range_sequences() {
        let missing = updates_result(vec![message_update(2, 20, 7, 102)], 3, 30, true);
        assert!(validate_response_page(1, &missing).is_err());

        let duplicate = updates_result(
            vec![message_update(2, 20, 7, 102), message_update(2, 20, 7, 102)],
            2,
            20,
            true,
        );
        assert!(validate_response_page(1, &duplicate).is_err());

        let out_of_range = updates_result(vec![message_update(4, 40, 7, 104)], 3, 40, true);
        assert!(validate_response_page(1, &out_of_range).is_err());
    }

    #[test]
    fn page_envelope_accepts_explicit_irrelevant_sequence_accounting() {
        let mut response = updates_result(vec![message_update(3, 30, 7, 103)], 3, 30, true);
        response.skipped_sequences = vec![proto::SyncSkippedSequence {
            seq: 2,
            reason: proto::sync_skipped_sequence::Reason::IrrelevantToBucket as i32,
        }];

        assert_eq!(
            validate_response_page(1, &response).unwrap(),
            PageAccounting::default()
        );
    }

    #[tokio::test]
    async fn empty_result_behind_hint_is_retried_without_advancing() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        store
            .save_sync_bucket_state(key, SyncBucketState { seq: 5, date: 50 })
            .await
            .unwrap();
        let empty = || proto::GetUpdatesResult {
            updates: Vec::new(),
            seq: 5,
            date: 80,
            r#final: Some(true),
            result_type: proto::get_updates_result::ResultType::Empty as i32,
            core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
            ..Default::default()
        };
        let host = FakeHost::new(vec![empty(), empty(), empty()]);
        let sync = SyncManager::new(
            store.clone(),
            SyncConfig {
                inconsistent_empty_retry_attempts: 2,
                inconsistent_empty_retry_delay_ms: 0,
                ..SyncConfig::default()
            },
        );

        let error = sync
            .process_realtime(&host, vec![chat_hint(7, 8)])
            .await
            .unwrap_err();

        assert_eq!(error.category, ClientErrorCategory::ProtocolMismatch);
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 5, date: 50 }
        );
    }

    #[tokio::test]
    async fn cold_chat_too_long_repairs_snapshot_and_advances_to_hint() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        let host = FakeHost::new(vec![
            proto::GetUpdatesResult {
                updates: Vec::new(),
                seq: 400,
                date: 80,
                r#final: Some(false),
                result_type: proto::get_updates_result::ResultType::TooLong as i32,
                core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                ..Default::default()
            },
            skipped_result(400, 500, 90),
        ]);
        let sync = SyncManager::new(store.clone(), SyncConfig::default());

        sync.process_realtime(&host, vec![chat_hint(7, 500)])
            .await
            .unwrap();

        assert_eq!(host.repaired_buckets.lock().await.as_slice(), &[key]);
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 500, date: 90 }
        );
        assert_eq!(host.requests.lock().await.len(), 2);
    }

    #[tokio::test]
    async fn cold_pointer_commits_lossless_events_without_an_empty_journal() {
        let store = Arc::new(InMemoryStore::new());
        let key = chat_key(7);
        let sync = SyncManager::new(store.clone(), SyncConfig::default());
        let event = ClientEvent::MessageDeleted {
            chat_id: InlineId::new(7),
            message_id: InlineId::new(101),
        };

        let deliveries = sync
            .commit_cold_pointer(key, 500, 80, vec![event.clone()])
            .await
            .unwrap();

        assert_eq!(deliveries.len(), 1);
        assert_eq!(deliveries[0].event, event);
        assert!(deliveries[0].delivery_id.is_some());
        assert!(store.pending_sync_batches().await.unwrap().is_empty());
        assert_eq!(
            store.sync_bucket_state(key).await.unwrap(),
            SyncBucketState { seq: 500, date: 80 }
        );
        assert_eq!(store.pending_client_events().await.unwrap(), deliveries);
    }

    #[tokio::test]
    async fn cold_user_and_space_too_long_require_snapshots_before_advancing() {
        for key in [
            SyncBucketKey::User,
            SyncBucketKey::Space {
                space_id: InlineId::new(9),
            },
        ] {
            let store = Arc::new(InMemoryStore::new());
            let host = FakeHost::new(vec![
                proto::GetUpdatesResult {
                    updates: Vec::new(),
                    seq: 400,
                    date: 80,
                    r#final: Some(false),
                    result_type: proto::get_updates_result::ResultType::TooLong as i32,
                    core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                    ..Default::default()
                },
                skipped_result(400, 500, 90),
            ]);
            let sync = SyncManager::new(store.clone(), SyncConfig::default());

            sync.fetch_bucket(
                &host,
                key,
                SyncBucketState::default(),
                BTreeMap::new(),
                Some(500),
            )
            .await
            .unwrap();

            assert_eq!(host.repaired_buckets.lock().await.as_slice(), &[key]);
            assert_eq!(
                store.sync_bucket_state(key).await.unwrap(),
                SyncBucketState { seq: 500, date: 90 }
            );
        }
    }

    #[tokio::test]
    async fn independent_bucket_fetches_use_configured_concurrency() {
        let store = Arc::new(InMemoryStore::new());
        let empty = |date| proto::GetUpdatesResult {
            updates: Vec::new(),
            seq: 1,
            date,
            r#final: Some(true),
            result_type: proto::get_updates_result::ResultType::Empty as i32,
            skipped_sequences: vec![proto::SyncSkippedSequence {
                seq: 1,
                reason: proto::sync_skipped_sequence::Reason::IrrelevantToBucket as i32,
            }],
            core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
            ..Default::default()
        };
        let host = FakeHost::new(vec![empty(100), empty(200)]).with_fetch_delay(25);
        let sync = SyncManager::new(
            store.clone(),
            SyncConfig {
                max_concurrent_bucket_fetches: 2,
                ..SyncConfig::default()
            },
        );

        sync.process_realtime(&host, vec![chat_hint(7, 1), chat_hint(8, 1)])
            .await
            .unwrap();

        assert_eq!(host.max_fetches_in_flight.load(Ordering::SeqCst), 2);
        assert_eq!(store.sync_bucket_state(chat_key(7)).await.unwrap().seq, 1);
        assert_eq!(store.sync_bucket_state(chat_key(8)).await.unwrap().seq, 1);
        assert_eq!(store.sync_state().await.unwrap().last_sync_date, 185);
    }

    fn updates_result(
        updates: Vec<proto::Update>,
        seq: i64,
        date: i64,
        final_page: bool,
    ) -> proto::GetUpdatesResult {
        proto::GetUpdatesResult {
            updates,
            seq,
            date,
            r#final: Some(final_page),
            result_type: proto::get_updates_result::ResultType::Slice as i32,
            core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
            ..Default::default()
        }
    }

    fn skipped_result(start_seq: i64, end_seq: i64, date: i64) -> proto::GetUpdatesResult {
        proto::GetUpdatesResult {
            updates: Vec::new(),
            seq: end_seq,
            date,
            r#final: Some(true),
            result_type: proto::get_updates_result::ResultType::Empty as i32,
            skipped_sequences: ((start_seq + 1)..=end_seq)
                .map(|seq| proto::SyncSkippedSequence {
                    seq,
                    reason: proto::sync_skipped_sequence::Reason::IrrelevantToBucket as i32,
                })
                .collect(),
            core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
            ..Default::default()
        }
    }

    fn chat_hint(chat_id: i64, seq: i32) -> proto::Update {
        proto::Update {
            seq: None,
            date: None,
            update: Some(proto::update::Update::ChatHasNewUpdates(
                proto::UpdateChatHasNewUpdates {
                    chat_id,
                    update_seq: seq,
                    peer_id: Some(chat_peer(chat_id)),
                },
            )),
        }
    }

    fn message_update(seq: i32, date: i64, chat_id: i64, message_id: i64) -> proto::Update {
        proto::Update {
            seq: Some(seq),
            date: Some(date),
            update: Some(proto::update::Update::NewMessage(proto::UpdateNewMessage {
                message: Some(proto::Message {
                    id: message_id,
                    chat_id,
                    peer_id: Some(chat_peer(chat_id)),
                    ..Default::default()
                }),
            })),
        }
    }

    fn chat_peer(chat_id: i64) -> proto::Peer {
        proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id })),
        }
    }
}
