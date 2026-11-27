//! A small on-disk cache of user names for readable message output.
//!
//! Readable `messages list/get/wait/search` only need a sender's display name,
//! so names seen recently are reused instead of asking the server on every
//! command. Entries older than [`FRESH_FOR`] are asked for again; when that
//! lookup fails (for example the server's per-user GetUsers limit), the stale
//! name is still shown rather than failing a command whose messages were
//! already read.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use inline_protocol::proto;

pub(crate) const FRESH_FOR_SECONDS: i64 = 24 * 60 * 60;
const MAX_ENTRIES: usize = 2_000;
const FILE_NAME: &str = "user-names.json";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct CachedName {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    first_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bot: Option<bool>,
    cached_at: i64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CacheFile {
    #[serde(default)]
    api_base_url: Option<String>,
    #[serde(default)]
    users: HashMap<i64, CachedName>,
}

pub(crate) struct NameCache {
    path: PathBuf,
    api_base_url: String,
    users: HashMap<i64, CachedName>,
    dirty: bool,
}

impl NameCache {
    /// Loads the cache; a missing, unreadable or foreign-server file starts empty.
    pub(crate) fn load(data_dir: &Path, api_base_url: &str) -> Self {
        let path = data_dir.join(FILE_NAME);
        let users = fs::read_to_string(&path)
            .ok()
            .and_then(|contents| serde_json::from_str::<CacheFile>(&contents).ok())
            .filter(|file| file.api_base_url.as_deref() == Some(api_base_url))
            .map(|file| file.users)
            .unwrap_or_default();
        Self {
            path,
            api_base_url: api_base_url.to_string(),
            users,
            dirty: false,
        }
    }

    /// A cached user younger than [`FRESH_FOR_SECONDS`].
    pub(crate) fn fresh(&self, user_id: i64, now: i64) -> Option<proto::User> {
        self.users
            .get(&user_id)
            .filter(|entry| now - entry.cached_at < FRESH_FOR_SECONDS)
            .map(|entry| entry.to_user(user_id))
    }

    /// A cached user of any age, for when the server could not be asked.
    pub(crate) fn any(&self, user_id: i64) -> Option<proto::User> {
        self.users.get(&user_id).map(|entry| entry.to_user(user_id))
    }

    pub(crate) fn remember(&mut self, user: &proto::User, now: i64) {
        let entry = CachedName {
            first_name: user.first_name.clone(),
            last_name: user.last_name.clone(),
            username: user.username.clone(),
            bot: user.bot,
            cached_at: now,
        };
        self.users.insert(user.id, entry);
        self.dirty = true;
    }

    /// Writes the cache if anything changed. Failures are ignored: the cache
    /// only saves lookups, it never decides what a command prints.
    pub(crate) fn save(mut self) {
        if !self.dirty {
            return;
        }
        if self.users.len() > MAX_ENTRIES {
            let mut ages: Vec<(i64, i64)> = self
                .users
                .iter()
                .map(|(id, entry)| (entry.cached_at, *id))
                .collect();
            ages.sort_unstable();
            let excess = self.users.len() - MAX_ENTRIES;
            for (_, id) in ages.into_iter().take(excess) {
                self.users.remove(&id);
            }
        }
        let file = CacheFile {
            api_base_url: Some(self.api_base_url.clone()),
            users: std::mem::take(&mut self.users),
        };
        let _ = write_private(&self.path, &file);
    }
}

impl CachedName {
    fn to_user(&self, user_id: i64) -> proto::User {
        proto::User {
            id: user_id,
            first_name: self.first_name.clone(),
            last_name: self.last_name.clone(),
            username: self.username.clone(),
            bot: self.bot,
            min: Some(true),
            ..Default::default()
        }
    }
}

fn write_private(path: &Path, file: &CacheFile) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let payload = serde_json::to_vec(file).map_err(io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, payload)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(id: i64, first: &str) -> proto::User {
        proto::User {
            id,
            first_name: Some(first.to_string()),
            email: Some("private@example.com".to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn names_survive_a_reload_and_go_stale_after_a_day() {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = NameCache::load(dir.path(), "https://api.example/v1");
        cache.remember(&user(7, "Ava"), 1_000);
        cache.save();

        let cache = NameCache::load(dir.path(), "https://api.example/v1");
        let fresh = cache.fresh(7, 1_000 + 60).unwrap();
        assert_eq!(fresh.first_name.as_deref(), Some("Ava"));
        assert_eq!(fresh.email, None, "only names are kept on disk");
        assert!(cache.fresh(7, 1_000 + FRESH_FOR_SECONDS).is_none());
        assert!(cache.any(7).is_some(), "a stale name is still a fallback");
    }

    #[test]
    fn another_server_starts_empty() {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = NameCache::load(dir.path(), "https://api.example/v1");
        cache.remember(&user(7, "Ava"), 1_000);
        cache.save();

        let other = NameCache::load(dir.path(), "http://localhost:8000/v1");
        assert!(other.any(7).is_none());
    }

    #[test]
    fn the_oldest_names_are_dropped_past_the_cap() {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = NameCache::load(dir.path(), "a");
        for id in 0..(MAX_ENTRIES as i64 + 5) {
            cache.remember(&user(id, "x"), id);
        }
        cache.save();

        let cache = NameCache::load(dir.path(), "a");
        assert!(cache.any(4).is_none());
        assert!(cache.any(5).is_some());
        assert!(cache.any(MAX_ENTRIES as i64 + 4).is_some());
    }
}
