use std::{collections::BTreeMap, fs, io::Write, path::Path};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct IdempotencyKey(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    Pending,
    Simulated,
    Submitted,
    Failed,
    Rejected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionRecord {
    pub channel_id: i64,
    pub message_id: i64,
    pub action_ordinal: u32,
    pub status: ActionStatus,
    pub order_id: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DedupStore {
    pub last_processed_message_id: BTreeMap<i64, i64>,
    pub processed_actions: BTreeMap<IdempotencyKey, ActionRecord>,
}

impl DedupStore {
    pub fn key(channel_id: i64, message_id: i64, action_ordinal: u32) -> IdempotencyKey {
        let raw = format!("{channel_id}:{message_id}:{action_ordinal}");
        IdempotencyKey(hex::encode(Sha256::digest(raw.as_bytes())))
    }

    pub fn reserve(
        &mut self,
        channel_id: i64,
        message_id: i64,
        action_ordinal: u32,
    ) -> Option<IdempotencyKey> {
        let key = Self::key(channel_id, message_id, action_ordinal);
        if self.processed_actions.contains_key(&key) {
            return None;
        }
        self.processed_actions.insert(
            key.clone(),
            ActionRecord {
                channel_id,
                message_id,
                action_ordinal,
                status: ActionStatus::Pending,
                order_id: None,
                updated_at: Utc::now(),
            },
        );
        Some(key)
    }

    pub fn finalize(
        &mut self,
        key: &IdempotencyKey,
        status: ActionStatus,
        order_id: Option<String>,
    ) {
        if let Some(record) = self.processed_actions.get_mut(key) {
            record.status = status;
            record.order_id = order_id;
            record.updated_at = Utc::now();
        }
    }

    pub fn should_process_message(&self, channel_id: i64, message_id: i64) -> bool {
        self.last_processed_message_id
            .get(&channel_id)
            .is_none_or(|last| message_id > *last)
    }

    pub fn mark_message_seen(&mut self, channel_id: i64, message_id: i64) {
        self.last_processed_message_id
            .entry(channel_id)
            .and_modify(|last| *last = (*last).max(message_id))
            .or_insert(message_id);
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        Ok(serde_json::from_slice(&fs::read(path)?)?)
    }

    /// Actions reserved but never finalized — the app died between reserving
    /// the slot and hearing back from the exchange. Each one needs checking
    /// against WEEX before it can be retried or written off.
    pub fn pending_actions(&self) -> Vec<(IdempotencyKey, ActionRecord)> {
        self.processed_actions
            .iter()
            .filter(|(_, record)| record.status == ActionStatus::Pending)
            .map(|(key, record)| (key.clone(), record.clone()))
            .collect()
    }

    /// Writes the store atomically: a full temp file, fsynced, then renamed
    /// over the target. A crash mid-write leaves either the old state or the
    /// new one, never a truncated file that would read as "nothing processed"
    /// and re-submit every order.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let bytes = serde_json::to_vec_pretty(self)?;
        let temp = path.with_extension("json.tmp");
        {
            let mut file = fs::File::create(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        fs::rename(&temp, path)?;
        // Fsync the directory so the rename itself survives a power loss.
        if let Some(parent) = path.parent() {
            if let Ok(dir) = fs::File::open(parent) {
                let _ = dir.sync_all();
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserves_once_for_same_message_action() {
        let mut store = DedupStore::default();
        let first = store.reserve(3766320116, 42, 0);
        let second = store.reserve(3766320116, 42, 0);
        assert!(first.is_some());
        assert!(second.is_none());
    }

    #[test]
    fn pending_survives_restart_and_blocks_retry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let mut store = DedupStore::default();
        let key = store.reserve(1, 2, 0).unwrap();
        store.save(&path).unwrap();

        let mut loaded = DedupStore::load(&path).unwrap();
        assert!(loaded.reserve(1, 2, 0).is_none());
        assert_eq!(loaded.processed_actions[&key].status, ActionStatus::Pending);
    }

    #[test]
    fn lists_only_unfinalized_actions_for_reconciliation() {
        let mut store = DedupStore::default();
        let stuck = store.reserve(1, 2, 0).unwrap();
        let done = store.reserve(1, 3, 0).unwrap();
        store.finalize(&done, ActionStatus::Submitted, Some("o-1".to_string()));

        let pending = store.pending_actions();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].0, stuck);
        assert_eq!(pending[0].1.message_id, 2);
    }

    #[test]
    fn save_leaves_no_temp_file_behind() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let mut store = DedupStore::default();
        store.reserve(1, 2, 0);
        store.save(&path).unwrap();
        store.save(&path).unwrap();

        let leftovers: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "left temp files: {leftovers:?}");
    }

    #[test]
    fn save_replaces_previous_state_rather_than_appending() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let mut store = DedupStore::default();
        store.reserve(1, 2, 0);
        store.save(&path).unwrap();
        store.mark_message_seen(1, 99);
        store.save(&path).unwrap();

        let reloaded = DedupStore::load(&path).unwrap();
        assert_eq!(reloaded.last_processed_message_id[&1], 99);
    }
}
