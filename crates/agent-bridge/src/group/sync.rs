//! Thread titles, session names and archive (spec §15.7, decided Oct 26).
//!
//! - **Inline → harness, always** for an agent's work thread: Codex
//!   `thread/name/set`, Claude `renameSession`.
//! - **Harness → Inline only where reliable:** Codex `thread/name/updated`
//!   live, Claude's title on the next session list or resume. Last change
//!   wins. Off until the stage 5 lab shows it is reliable.
//! - **Group threads:** a session started from a group thread takes the
//!   thread's title once, with no ongoing sync.
//! - **Archive:** archiving a work thread archives the session where the
//!   harness has an archive (Codex `thread/archive`, `thread/unarchive`).
//!   Claude has only delete, so nothing happens. Inline never deletes a
//!   native session.

use serde::{Deserialize, Serialize};

use crate::MAX_SESSION_TITLE_CHARS;

/// Where the session was started.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkOrigin {
    /// The agent's own work thread (a DM work thread or a subthread).
    WorkThread,
    GroupThread,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeTitleSource {
    /// Codex `thread/name/updated` on a connected client.
    LiveEvent,
    /// Claude's title read from the session list or on resume.
    SessionList,
}

/// Whether harness renames flow back into Inline for this provider.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TitleSyncPolicy {
    pub harness_to_inline: bool,
}

impl TitleSyncPolicy {
    pub const ONE_WAY: Self = Self {
        harness_to_inline: false,
    };
    pub const TWO_WAY: Self = Self {
        harness_to_inline: true,
    };
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TitleEvent {
    SessionStarted {
        thread_title: Option<String>,
        at: i64,
    },
    InlineRenamed {
        title: String,
        at: i64,
    },
    NativeRenamed {
        title: String,
        at: i64,
        source: NativeTitleSource,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TitleEffect {
    RenameNative { title: String },
    RenameInline { title: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Stamped {
    title: String,
    at: i64,
}

/// Title sync state for one (thread, session).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TitleSync {
    origin: WorkOrigin,
    policy: TitleSyncPolicy,
    named: bool,
    inline: Option<Stamped>,
    native: Option<Stamped>,
}

impl TitleSync {
    pub fn new(origin: WorkOrigin, policy: TitleSyncPolicy) -> Self {
        Self {
            origin,
            policy,
            named: false,
            inline: None,
            native: None,
        }
    }

    pub fn handle(&mut self, event: TitleEvent) -> Option<TitleEffect> {
        match event {
            TitleEvent::SessionStarted { thread_title, at } => {
                let title = normalize(thread_title.as_deref()?)?;
                if self.named {
                    return None;
                }
                self.named = true;
                self.inline = Some(Stamped {
                    title: title.clone(),
                    at,
                });
                self.rename_native(title, at)
            }
            TitleEvent::InlineRenamed { title, at } => {
                let title = normalize(&title)?;
                if self.origin == WorkOrigin::GroupThread {
                    return None;
                }
                if self.inline.as_ref().is_some_and(|inline| inline.at > at) {
                    return None;
                }
                self.named = true;
                self.inline = Some(Stamped {
                    title: title.clone(),
                    at,
                });
                self.rename_native(title, at)
            }
            TitleEvent::NativeRenamed { title, at, .. } => {
                let title = normalize(&title)?;
                let echo = self
                    .native
                    .as_ref()
                    .is_some_and(|native| native.title == title);
                self.native = Some(Stamped {
                    title: title.clone(),
                    at,
                });
                if echo || self.origin == WorkOrigin::GroupThread || !self.policy.harness_to_inline
                {
                    return None;
                }
                match &self.inline {
                    Some(inline) if inline.title == title || inline.at > at => None,
                    _ => {
                        self.inline = Some(Stamped {
                            title: title.clone(),
                            at,
                        });
                        Some(TitleEffect::RenameInline { title })
                    }
                }
            }
        }
    }

    fn rename_native(&mut self, title: String, at: i64) -> Option<TitleEffect> {
        if self
            .native
            .as_ref()
            .is_some_and(|native| native.title == title)
        {
            return None;
        }
        // Remember what we set so the harness's echo is not applied back.
        self.native = Some(Stamped {
            title: title.clone(),
            at,
        });
        Some(TitleEffect::RenameNative { title })
    }
}

fn normalize(title: &str) -> Option<String> {
    let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
    if title.is_empty() {
        return None;
    }
    Some(title.chars().take(MAX_SESSION_TITLE_CHARS).collect())
}

/// Whether the harness has a native archive.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeArchive {
    /// Codex `thread/archive` and `thread/unarchive`.
    Supported,
    /// Claude: delete only, which Inline never uses.
    Unsupported,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArchiveEffect {
    ArchiveNative,
    UnarchiveNative,
    Nothing,
}

/// The native effect of archiving (`archived: true`) or unarchiving an Inline
/// thread. There is deliberately no delete effect.
pub fn archive_effect(origin: WorkOrigin, native: NativeArchive, archived: bool) -> ArchiveEffect {
    match (origin, native, archived) {
        (WorkOrigin::WorkThread, NativeArchive::Supported, true) => ArchiveEffect::ArchiveNative,
        (WorkOrigin::WorkThread, NativeArchive::Supported, false) => ArchiveEffect::UnarchiveNative,
        _ => ArchiveEffect::Nothing,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rename_native(title: &str) -> Option<TitleEffect> {
        Some(TitleEffect::RenameNative {
            title: title.into(),
        })
    }

    fn native(title: &str, at: i64) -> TitleEvent {
        TitleEvent::NativeRenamed {
            title: title.into(),
            at,
            source: NativeTitleSource::LiveEvent,
        }
    }

    #[test]
    fn work_threads_push_every_inline_rename() {
        let mut sync = TitleSync::new(WorkOrigin::WorkThread, TitleSyncPolicy::ONE_WAY);
        assert_eq!(
            sync.handle(TitleEvent::SessionStarted {
                thread_title: Some("  Fix   CI ".into()),
                at: 1
            }),
            rename_native("Fix CI")
        );
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "Fix flaky CI".into(),
                at: 2
            }),
            rename_native("Fix flaky CI")
        );
        // The same title again is a no-op; blank titles are ignored.
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "Fix flaky CI".into(),
                at: 3
            }),
            None
        );
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "   ".into(),
                at: 4
            }),
            None
        );
    }

    #[test]
    fn one_way_sync_ignores_harness_renames() {
        let mut sync = TitleSync::new(WorkOrigin::WorkThread, TitleSyncPolicy::ONE_WAY);
        sync.handle(TitleEvent::InlineRenamed {
            title: "A".into(),
            at: 1,
        });
        assert_eq!(sync.handle(native("B", 2)), None);
        // Inline still wins its own later renames.
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "C".into(),
                at: 3
            }),
            rename_native("C")
        );
    }

    #[test]
    fn two_way_sync_follows_the_last_change_and_ignores_echoes() {
        let mut sync = TitleSync::new(WorkOrigin::WorkThread, TitleSyncPolicy::TWO_WAY);
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "A".into(),
                at: 10
            }),
            rename_native("A")
        );
        // Codex echoes our own rename back.
        assert_eq!(sync.handle(native("A", 11)), None);
        // A rename in the terminal, later than Inline's, follows into Inline.
        assert_eq!(
            sync.handle(native("B", 20)),
            Some(TitleEffect::RenameInline { title: "B".into() })
        );
        // A stale harness title (older than Inline's last change) is ignored.
        sync.handle(TitleEvent::InlineRenamed {
            title: "C".into(),
            at: 30,
        });
        assert_eq!(
            sync.handle(TitleEvent::NativeRenamed {
                title: "D".into(),
                at: 25,
                source: NativeTitleSource::SessionList
            }),
            None
        );
        // An older Inline rename arriving late does not override.
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "E".into(),
                at: 5
            }),
            None
        );
    }

    #[test]
    fn group_thread_sessions_are_named_once() {
        let mut sync = TitleSync::new(WorkOrigin::GroupThread, TitleSyncPolicy::TWO_WAY);
        assert_eq!(
            sync.handle(TitleEvent::SessionStarted {
                thread_title: Some("Team standup".into()),
                at: 1
            }),
            rename_native("Team standup")
        );
        assert_eq!(
            sync.handle(TitleEvent::SessionStarted {
                thread_title: Some("Team standup 2".into()),
                at: 2
            }),
            None
        );
        assert_eq!(
            sync.handle(TitleEvent::InlineRenamed {
                title: "Renamed".into(),
                at: 3
            }),
            None
        );
        assert_eq!(sync.handle(native("Harness name", 4)), None);
    }

    #[test]
    fn untitled_threads_name_nothing() {
        let mut sync = TitleSync::new(WorkOrigin::GroupThread, TitleSyncPolicy::ONE_WAY);
        assert_eq!(
            sync.handle(TitleEvent::SessionStarted {
                thread_title: None,
                at: 1
            }),
            None
        );
    }

    #[test]
    fn long_titles_are_capped() {
        let mut sync = TitleSync::new(WorkOrigin::WorkThread, TitleSyncPolicy::ONE_WAY);
        let Some(TitleEffect::RenameNative { title }) = sync.handle(TitleEvent::InlineRenamed {
            title: "x".repeat(1_000),
            at: 1,
        }) else {
            panic!("expected a native rename");
        };
        assert_eq!(title.chars().count(), MAX_SESSION_TITLE_CHARS);
    }

    #[test]
    fn archive_maps_to_the_native_archive_and_never_deletes() {
        assert_eq!(
            archive_effect(WorkOrigin::WorkThread, NativeArchive::Supported, true),
            ArchiveEffect::ArchiveNative
        );
        assert_eq!(
            archive_effect(WorkOrigin::WorkThread, NativeArchive::Supported, false),
            ArchiveEffect::UnarchiveNative
        );
        for archived in [true, false] {
            assert_eq!(
                archive_effect(WorkOrigin::WorkThread, NativeArchive::Unsupported, archived),
                ArchiveEffect::Nothing
            );
            assert_eq!(
                archive_effect(WorkOrigin::GroupThread, NativeArchive::Supported, archived),
                ArchiveEffect::Nothing
            );
        }
    }
}
