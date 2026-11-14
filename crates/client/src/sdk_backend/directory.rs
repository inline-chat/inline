//! Account-scoped directory operations. Cached identities never authorize writes.
use super::*;
use crate::{
    AccountDirectoryState, AccountDirectoryWrite, SearchUsersRequest, SpaceMembersPage,
    SpaceMembersRequest, UsersPage, UsersRequest,
};

const MAX_SPACES: usize = 1000;

impl SdkBackend {
    pub(super) async fn cached_account_directory(&self) -> BackendResult<AccountStateSnapshot> {
        let _lease = self.account_write_lease(self.source_generation()).await?;
        let directory = self
            .store
            .account_directory()
            .await
            .map_err(store_error_to_backend)?;
        let mut snapshot = directory.snapshot;
        snapshot.deleted_chat_ids = self
            .store
            .deleted_chat_ids()
            .await
            .map_err(store_error_to_backend)?;
        // Sidecars may improve display metadata, but cannot add accessible IDs.
        for space in &mut snapshot.spaces {
            if let Some(cached) = self
                .store
                .space(space.space_id)
                .await
                .map_err(store_error_to_backend)?
            {
                if cached.seq.unwrap_or_default() >= space.seq.unwrap_or_default() {
                    *space = cached;
                }
            }
        }
        Ok(snapshot)
    }

    pub(super) async fn refresh_account_directory(&self) -> BackendResult<AccountStateSnapshot> {
        let generation = self.source_generation();
        let mut directory = self
            .store
            .account_directory()
            .await
            .map_err(store_error_to_backend)?;
        let revision = directory.revision;
        let session = self.require_session().await?;
        // Two directory calls plus at most eight workspace details, within a
        // shared wall-clock budget. The persisted cursor rotates fairly.
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        let timeout = || {
            BackendError::new(
                ClientErrorCategory::Timeout,
                "workspace refresh time budget exhausted",
            )
        };
        let me =
            tokio::time::timeout_at(deadline, self.call_realtime(&session, proto::GetMeInput {}))
                .await
                .map_err(|_| timeout())??
                .user
                .ok_or_else(|| {
                    BackendError::new(
                        ClientErrorCategory::ProtocolMismatch,
                        "directory refresh omitted current user",
                    )
                })?;
        if me.id <= 0 {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "directory refresh returned an invalid current-user ID",
            ));
        }
        let result = tokio::time::timeout_at(
            deadline,
            self.call_realtime(&session, proto::GetSpacesInput {}),
        )
        .await
        .map_err(|_| timeout())??;
        if result.spaces.len() > MAX_SPACES {
            return Err(BackendError::new(
                ClientErrorCategory::Unsupported,
                "workspace directory exceeds bounded snapshot capacity",
            ));
        }
        if directory
            .account_user_id
            .is_some_and(|user| user.get() != me.id)
        {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "directory refresh changed account identity",
            ));
        }
        let mut listed = result.spaces;
        listed.sort_by_key(|space| space.id);
        if listed.iter().any(|space| space.id <= 0)
            || listed.windows(2).any(|pair| pair[0].id == pair[1].id)
        {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "invalid workspace directory identity",
            ));
        }
        let live_ids: HashSet<_> = listed.iter().map(|space| InlineId::new(space.id)).collect();
        let previous_ids: HashSet<_> = directory
            .snapshot
            .spaces
            .iter()
            .map(|space| space.space_id)
            .collect();
        for id in previous_ids.difference(&live_ids) {
            if !directory.snapshot.removed_space_ids.contains(id) {
                directory.snapshot.removed_space_ids.push(*id);
            }
        }
        directory
            .snapshot
            .removed_space_ids
            .retain(|id| !live_ids.contains(id));
        directory
            .snapshot
            .removed_space_ids
            .sort_by_key(|id| id.get());
        directory
            .snapshot
            .space_memberships
            .retain(|member| live_ids.contains(&member.space_id));
        directory
            .complete_roster_space_ids
            .retain(|id| live_ids.contains(id));
        // getSpaces itself proves only membership; actual roles remain unknown
        // until getSpace supplies a current-user membership row.
        let mut spaces: HashMap<_, _> = listed
            .iter()
            .map(|space| (InlineId::new(space.id), space_record_from_proto(space)))
            .collect();
        for existing in &directory.snapshot.spaces {
            if let Some(listed) = spaces.get_mut(&existing.space_id) {
                if existing.seq.unwrap_or_default() > listed.seq.unwrap_or_default() {
                    *listed = existing.clone();
                }
            }
        }
        let cursor = directory
            .refresh_cursor
            .map(InlineId::get)
            .unwrap_or_default();
        let split = listed.partition_point(|space| space.id <= cursor);
        listed.rotate_left(split);
        let mut write = AccountDirectoryWrite {
            users: vec![user_record_from_proto(&me)],
            ..Default::default()
        };
        let total = listed.len();
        let mut attempted = 0;
        let mut successful = 0;
        for listed in listed.into_iter().take(8) {
            if tokio::time::Instant::now() >= deadline {
                break;
            }
            attempted += 1;
            directory.refresh_cursor = Some(InlineId::new(listed.id));
            let detail = match tokio::time::timeout_at(
                deadline,
                self.call_realtime(
                    &session,
                    proto::GetSpaceInput {
                        space_id: listed.id,
                    },
                ),
            )
            .await
            {
                Ok(Ok(detail)) => detail,
                Ok(Err(error))
                    if matches!(
                        error.category,
                        ClientErrorCategory::AuthRequired
                            | ClientErrorCategory::AuthExpired
                            | ClientErrorCategory::ReloginRequired
                    ) =>
                {
                    return Err(error);
                }
                // Failed refresh is not evidence of removal. Other proven
                // workspace details still publish, and this one retries later.
                _ => continue,
            };
            let Some(snapshot) = detail.space.filter(|space| space.id == listed.id) else {
                continue;
            };
            let Some(member) = detail
                .membership
                .filter(|member| member.space_id == listed.id && member.user_id == me.id)
            else {
                continue;
            };
            let cursor = self
                .store
                .sync_bucket_state(crate::SyncBucketKey::Space {
                    space_id: InlineId::new(listed.id),
                })
                .await
                .map_err(store_error_to_backend)?;
            if cursor.seq > 0 && snapshot.seq.is_none_or(|seq| i64::from(seq) < cursor.seq) {
                continue;
            }
            let mut space = space_record_from_proto(&snapshot);
            if let Some(settings) = detail.settings {
                space.grid_enabled = Some(settings.grid_enabled);
            }
            spaces.insert(space.space_id, space.clone());
            write.spaces.push(space);
            let member = space_member_record_from_proto(&member);
            directory
                .snapshot
                .space_memberships
                .retain(|old| old.space_id != member.space_id);
            directory.snapshot.space_memberships.push(member.clone());
            write.members.push(member);
            successful += 1;
        }
        directory.snapshot.spaces = spaces.into_values().collect();
        directory
            .snapshot
            .spaces
            .sort_by_key(|space| space.space_id.get());
        directory.snapshot.spaces_complete = attempted == total && successful == total;
        directory.account_user_id = Some(InlineId::new(me.id));
        let _lease = self.account_write_lease(generation).await?;
        if !self
            .store
            .commit_account_directory(revision, directory, write)
            .await
            .map_err(store_error_to_backend)?
        {
            return Err(BackendError::new(
                ClientErrorCategory::Network,
                "workspace directory changed while refresh was in flight; retry",
            ));
        }
        drop(_lease);
        self.cached_account_directory().await
    }

    pub(super) async fn remember_directory_account(&self, user_id: InlineId) -> BackendResult<()> {
        loop {
            let mut state = self
                .store
                .account_directory()
                .await
                .map_err(store_error_to_backend)?;
            if state.account_user_id == Some(user_id) {
                return Ok(());
            }
            if state.account_user_id.is_some() {
                state = AccountDirectoryState {
                    revision: state.revision,
                    ..Default::default()
                };
            }
            let revision = state.revision;
            state.account_user_id = Some(user_id);
            if self
                .store
                .record_account_directory(revision, state)
                .await
                .map_err(store_error_to_backend)?
            {
                return Ok(());
            }
        }
    }

    pub(super) async fn update_directory_membership(
        &self,
        member: Option<SpaceMemberRecord>,
        space_id: InlineId,
        user_id: InlineId,
    ) -> BackendResult<()> {
        loop {
            let mut directory = self
                .store
                .account_directory()
                .await
                .map_err(store_error_to_backend)?;
            let revision = directory.revision;
            if directory.account_user_id != Some(user_id) {
                if self
                    .store
                    .record_account_directory(revision, directory)
                    .await
                    .map_err(store_error_to_backend)?
                {
                    return Ok(());
                }
                continue;
            }
            directory
                .snapshot
                .space_memberships
                .retain(|entry| entry.space_id != space_id);
            if let Some(member) = &member {
                if directory.snapshot.removed_space_ids.contains(&space_id) {
                    directory
                        .complete_roster_space_ids
                        .retain(|id| *id != space_id);
                }
                directory.snapshot.space_memberships.push(member.clone());
                directory
                    .snapshot
                    .removed_space_ids
                    .retain(|id| *id != space_id);
                if !directory
                    .snapshot
                    .spaces
                    .iter()
                    .any(|space| space.space_id == space_id)
                {
                    if let Some(space) = self
                        .store
                        .space(space_id)
                        .await
                        .map_err(store_error_to_backend)?
                    {
                        directory.snapshot.spaces.push(space);
                    } else {
                        directory.snapshot.spaces_complete = false;
                    }
                }
            } else {
                directory
                    .snapshot
                    .spaces
                    .retain(|space| space.space_id != space_id);
                directory
                    .complete_roster_space_ids
                    .retain(|id| *id != space_id);
                if !directory.snapshot.removed_space_ids.contains(&space_id) {
                    directory.snapshot.removed_space_ids.push(space_id);
                }
            }
            if self
                .store
                .record_account_directory(revision, directory)
                .await
                .map_err(store_error_to_backend)?
            {
                return Ok(());
            }
        }
    }

    pub(super) async fn lookup_source_users(
        &self,
        request: UsersRequest,
    ) -> BackendResult<UsersPage> {
        let generation = self.source_generation();
        if request.user_ids.len() > 50 || request.user_ids.iter().any(|id| id.get() <= 0) {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "user lookup requires at most 50 positive IDs",
            ));
        }
        let session = self.require_session().await?;
        let ids: HashSet<_> = request.user_ids.iter().copied().collect();
        let result = self
            .call_realtime(
                &session,
                proto::GetUsersInput {
                    user_ids: request.user_ids.into_iter().map(InlineId::get).collect(),
                },
            )
            .await?;
        if result
            .users
            .iter()
            .any(|user| !ids.contains(&InlineId::new(user.id)))
        {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "user lookup returned an unexpected ID",
            ));
        }
        let users: Vec<_> = result.users.iter().map(user_record_from_proto).collect();
        let complete = users
            .iter()
            .map(|user| user.user_id)
            .collect::<HashSet<_>>()
            == ids;
        let _lease = self.account_write_lease(generation).await?;
        self.store
            .record_users(users.clone())
            .await
            .map_err(store_error_to_backend)?;
        Ok(UsersPage { users, complete })
    }

    pub(super) async fn search_source_users(
        &self,
        request: SearchUsersRequest,
    ) -> BackendResult<UsersPage> {
        let generation = self.source_generation();
        let query = request.query.trim();
        if query.len() > 256 {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "user search query is too long",
            ));
        }
        let session = self.require_session().await?;
        let limit = request.limit.unwrap_or(20).clamp(1, 20) as i32;
        let result = self
            .call_realtime(
                &session,
                proto::SearchUsersInput {
                    query: query.to_owned(),
                    limit: Some(limit),
                },
            )
            .await?;
        let users: Vec<_> = result
            .users
            .iter()
            .take(limit as usize)
            .map(user_record_from_proto)
            .collect();
        let _lease = self.account_write_lease(generation).await?;
        self.store
            .record_users(users.clone())
            .await
            .map_err(store_error_to_backend)?;
        Ok(UsersPage {
            users,
            complete: false,
        })
    }

    pub(super) async fn source_space_members(
        &self,
        request: SpaceMembersRequest,
    ) -> BackendResult<SpaceMembersPage> {
        let generation = self.source_generation();
        if request.space_id.get() <= 0 {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "workspace ID must be positive",
            ));
        }
        let after = request
            .cursor
            .as_deref()
            .filter(|cursor| !cursor.is_empty())
            .map(str::parse::<i64>)
            .transpose()
            .map_err(|_| {
                BackendError::new(ClientErrorCategory::InvalidInput, "invalid member cursor")
            })?
            .unwrap_or_default();
        if after < 0 || (request.refresh && after != 0) {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "refresh requires the first member page",
            ));
        }
        let mut directory = self
            .store
            .account_directory()
            .await
            .map_err(store_error_to_backend)?;
        if directory
            .snapshot
            .removed_space_ids
            .contains(&request.space_id)
        {
            return Err(BackendError::new(
                ClientErrorCategory::NotFound,
                "workspace access was removed",
            ));
        }
        if !request.refresh
            && (directory.account_user_id.is_none()
                || !directory
                    .snapshot
                    .spaces
                    .iter()
                    .any(|space| space.space_id == request.space_id))
        {
            return Err(BackendError::new(
                ClientErrorCategory::NotFound,
                "workspace access has not been source-confirmed; refresh membership first",
            ));
        }
        if request.refresh {
            let revision = directory.revision;
            let session = self.require_session().await?;
            let result = self
                .call_realtime(
                    &session,
                    proto::GetSpaceMembersInput {
                        space_id: request.space_id.get(),
                    },
                )
                .await?;
            let mut member_ids = HashSet::new();
            if result.members.len() > 100_000
                || result.users.len() > 100_000
                || result.members.iter().any(|member| {
                    member.space_id != request.space_id.get()
                        || member.user_id <= 0
                        || !member_ids.insert(member.user_id)
                })
                || result
                    .users
                    .iter()
                    .any(|user| user.id <= 0 || !member_ids.contains(&user.id))
            {
                return Err(BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "invalid or oversized member snapshot",
                ));
            }
            if !directory
                .complete_roster_space_ids
                .contains(&request.space_id)
            {
                directory.complete_roster_space_ids.push(request.space_id);
            }
            let cursor = self
                .store
                .sync_bucket_state(crate::SyncBucketKey::Space {
                    space_id: request.space_id,
                })
                .await
                .map_err(store_error_to_backend)?;
            if cursor.seq > 0 && result.seq.is_none_or(|seq| i64::from(seq) < cursor.seq) {
                return Err(BackendError::new(
                    ClientErrorCategory::Network,
                    "workspace member snapshot is older than synchronized state",
                ));
            }
            let write = AccountDirectoryWrite {
                users: result.users.iter().map(user_record_from_proto).collect(),
                rosters: vec![(
                    request.space_id,
                    result
                        .members
                        .iter()
                        .map(space_member_record_from_proto)
                        .collect(),
                )],
                ..Default::default()
            };
            let _lease = self.account_write_lease(generation).await?;
            if !self
                .store
                .commit_account_directory(revision, directory.clone(), write)
                .await
                .map_err(store_error_to_backend)?
            {
                return Err(BackendError::new(
                    ClientErrorCategory::Network,
                    "workspace changed while member refresh was in flight",
                ));
            }
        }
        let _lease = self.account_write_lease(generation).await?;
        let mut members = self
            .store
            .space_members(request.space_id)
            .await
            .map_err(store_error_to_backend)?;
        members.retain(|member| member.user_id.get() > after);
        members.sort_by_key(|member| member.user_id.get());
        let limit = request.limit.unwrap_or(100).clamp(1, 100) as usize;
        let has_more = members.len() > limit;
        members.truncate(limit);
        let mut users = Vec::new();
        for member in &members {
            if let Some(user) = self
                .store
                .user(member.user_id)
                .await
                .map_err(store_error_to_backend)?
            {
                users.push(user);
            }
        }
        Ok(SpaceMembersPage {
            next_cursor: if has_more {
                members
                    .last()
                    .map(|member| member.user_id.get().to_string())
            } else {
                None
            },
            complete: !has_more
                && directory
                    .complete_roster_space_ids
                    .contains(&request.space_id),
            members,
            users,
        })
    }
}
