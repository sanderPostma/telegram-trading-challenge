use std::{collections::BTreeMap, fs, path::Path};

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

    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, serde_json::to_vec_pretty(self)?)?;
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
}
