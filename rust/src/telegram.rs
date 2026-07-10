use std::{
    path::Path,
    sync::{Arc, Mutex, OnceLock},
};

use crate::{
    dedup::{ActionStatus, DedupStore, IdempotencyKey},
    patterns::{default_rules, match_actions},
};
use chrono::Utc;
use grammers_client::{
    client::{LoginToken, PasswordToken, UpdatesConfiguration},
    update::Update,
    Client, SignInError,
};
use grammers_mtsender::SenderPool;
use grammers_session::storages::SqliteSession;
use serde::{Deserialize, Serialize};
use tokio::task::JoinHandle;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelegramClientRequest {
    pub api_id: i32,
    pub api_hash: String,
    pub phone: String,
    pub channel_id: i64,
    pub session_path: String,
    pub state_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelegramLoginStatus {
    pub ok: bool,
    pub authorized: bool,
    pub needs_code: bool,
    pub needs_password: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelegramMessageEvent {
    pub ok: bool,
    pub channel_id: i64,
    pub channel_title: String,
    pub message_id: i32,
    pub dedup_keys: Vec<String>,
    pub text: String,
    pub received_at_ms: i64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TelegramActionStatus {
    Pending,
    Simulated,
    Submitted,
    Failed,
    Rejected,
}

struct LoginState {
    client: Client,
    _session: Arc<SqliteSession>,
    runner: JoinHandle<()>,
    request: TelegramClientRequest,
    token: Option<LoginToken>,
    password_token: Option<PasswordToken>,
}

static LOGIN_STATE: OnceLock<Mutex<Option<LoginState>>> = OnceLock::new();

fn login_state() -> &'static Mutex<Option<LoginState>> {
    LOGIN_STATE.get_or_init(|| Mutex::new(None))
}

pub async fn request_code(request: TelegramClientRequest) -> anyhow::Result<TelegramLoginStatus> {
    let mut state = connect_for_login(request).await?;
    if state.client.is_authorized().await? {
        *login_state().lock().expect("telegram login state poisoned") = Some(state);
        return Ok(TelegramLoginStatus {
            ok: true,
            authorized: true,
            needs_code: false,
            needs_password: false,
            message: "Telegram session is already authorized.".to_string(),
        });
    }

    let token = state
        .client
        .request_login_code(&state.request.phone, &state.request.api_hash)
        .await?;
    state.token = Some(token);
    *login_state().lock().expect("telegram login state poisoned") = Some(state);
    Ok(TelegramLoginStatus {
        ok: true,
        authorized: false,
        needs_code: true,
        needs_password: false,
        message: "Telegram login code requested. Enter the code from Telegram.".to_string(),
    })
}

pub async fn sign_in(code: String) -> anyhow::Result<TelegramLoginStatus> {
    let mut state = login_state()
        .lock()
        .expect("telegram login state poisoned")
        .take()
        .ok_or_else(|| anyhow::anyhow!("Telegram login was not started"))?;
    let token = state
        .token
        .take()
        .ok_or_else(|| anyhow::anyhow!("Telegram login code was not requested"))?;

    match state.client.sign_in(&token, &code).await {
        Ok(_) => {
            *login_state().lock().expect("telegram login state poisoned") = Some(state);
            Ok(TelegramLoginStatus {
                ok: true,
                authorized: true,
                needs_code: false,
                needs_password: false,
                message: "Telegram sign-in completed.".to_string(),
            })
        }
        Err(SignInError::PasswordRequired(password_token)) => {
            state.password_token = Some(password_token);
            *login_state().lock().expect("telegram login state poisoned") = Some(state);
            Ok(TelegramLoginStatus {
                ok: true,
                authorized: false,
                needs_code: false,
                needs_password: true,
                message: "Telegram requires your 2FA password.".to_string(),
            })
        }
        Err(error) => {
            state.token = Some(token);
            *login_state().lock().expect("telegram login state poisoned") = Some(state);
            Err(error.into())
        }
    }
}

pub async fn check_password(password: String) -> anyhow::Result<TelegramLoginStatus> {
    let mut state = login_state()
        .lock()
        .expect("telegram login state poisoned")
        .take()
        .ok_or_else(|| anyhow::anyhow!("Telegram login was not started"))?;
    let token = state
        .password_token
        .take()
        .ok_or_else(|| anyhow::anyhow!("Telegram password was not requested"))?;

    match state.client.check_password(token, password).await {
        Ok(_) => {
            *login_state().lock().expect("telegram login state poisoned") = Some(state);
            Ok(TelegramLoginStatus {
                ok: true,
                authorized: true,
                needs_code: false,
                needs_password: false,
                message: "Telegram sign-in completed.".to_string(),
            })
        }
        Err(error) => Err(error.into()),
    }
}

pub async fn stream_channel_messages(
    request: TelegramClientRequest,
    sink: crate::frb_generated::StreamSink<TelegramMessageEvent>,
) {
    match stream_channel_messages_once(request, &sink).await {
        Ok(()) => {}
        Err(error) => {
            let _ = sink.add(TelegramMessageEvent::error(error.to_string()));
        }
    }
}

pub fn finalize_action(
    state_path: String,
    dedup_key: String,
    status: TelegramActionStatus,
    order_id: Option<String>,
) -> anyhow::Result<()> {
    let path = Path::new(&state_path);
    let mut store = DedupStore::load(path)?;
    store.finalize(
        &IdempotencyKey(dedup_key),
        match status {
            TelegramActionStatus::Pending => ActionStatus::Pending,
            TelegramActionStatus::Simulated => ActionStatus::Simulated,
            TelegramActionStatus::Submitted => ActionStatus::Submitted,
            TelegramActionStatus::Failed => ActionStatus::Failed,
            TelegramActionStatus::Rejected => ActionStatus::Rejected,
        },
        order_id,
    );
    store.save(path)?;
    Ok(())
}

async fn stream_channel_messages_once(
    request: TelegramClientRequest,
    sink: &crate::frb_generated::StreamSink<TelegramMessageEvent>,
) -> anyhow::Result<()> {
    let session = Arc::new(SqliteSession::open(&request.session_path).await?);
    let pool = SenderPool::new(Arc::clone(&session), request.api_id);
    let grammers_mtsender::SenderPool {
        runner,
        updates,
        handle,
    } = pool;
    let client = Client::new(handle.clone());
    let pool_runner = tokio::spawn(runner.run());

    if !client.is_authorized().await? {
        anyhow::bail!("Telegram session is not authorized. Complete Telegram sign-in first.");
    }

    let mut dialogs = client.iter_dialogs();
    let mut matched_title = request.channel_id.to_string();
    while let Some(dialog) = dialogs.next().await? {
        let peer = dialog.peer();
        if peer.id().bot_api_dialog_id() == Some(request.channel_id) {
            matched_title = peer.name().unwrap_or(&matched_title).to_string();
            break;
        }
    }
    let _session = &session;

    let mut updates = client
        .stream_updates(
            updates,
            UpdatesConfiguration {
                // Live-only stream: do not replay historical updates on app open.
                catch_up: false,
                update_queue_limit: Some(100),
                ..Default::default()
            },
        )
        .await
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;

    loop {
        match updates.next().await? {
            Update::NewMessage(message) if !message.outgoing() => {
                let Some(channel_id) = message.peer_id().bot_api_dialog_id() else {
                    continue;
                };
                if channel_id != request.channel_id {
                    continue;
                }
                let text = message.text().trim().to_string();
                if text.is_empty() {
                    continue;
                }
                let dedup_keys = {
                    let state_path = Path::new(&request.state_path);
                    let mut store = DedupStore::load(state_path)?;
                    let message_id = i64::from(message.id());
                    if !store.should_process_message(channel_id, message_id) {
                        continue;
                    }
                    let action_count = match_actions(&text, &default_rules())?.len().max(1);
                    let mut keys = Vec::with_capacity(action_count);
                    for action_ordinal in 0..action_count {
                        let Some(key) =
                            store.reserve(channel_id, message_id, action_ordinal as u32)
                        else {
                            keys.clear();
                            break;
                        };
                        keys.push(key.0);
                    }
                    store.mark_message_seen(channel_id, message_id);
                    store.save(state_path)?;
                    if keys.is_empty() {
                        continue;
                    }
                    keys
                };
                let channel_title = message
                    .peer()
                    .and_then(|peer| peer.name().map(str::to_string))
                    .unwrap_or_else(|| matched_title.clone());
                if sink
                    .add(TelegramMessageEvent {
                        ok: true,
                        channel_id: request.channel_id,
                        channel_title,
                        message_id: message.id(),
                        dedup_keys,
                        text,
                        received_at_ms: Utc::now().timestamp_millis(),
                        error: None,
                    })
                    .is_err()
                {
                    break;
                }
            }
            _ => {}
        }
    }
    updates
        .sync_update_state()
        .await
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;
    handle.quit();
    let _ = pool_runner.await;
    Ok(())
}

async fn connect_for_login(request: TelegramClientRequest) -> anyhow::Result<LoginState> {
    let session = Arc::new(SqliteSession::open(&request.session_path).await?);
    let pool = SenderPool::new(Arc::clone(&session), request.api_id);
    let grammers_mtsender::SenderPool { runner, handle, .. } = pool;
    let client = Client::new(handle);
    let pool_runner = tokio::spawn(runner.run());
    Ok(LoginState {
        client,
        _session: session,
        runner: pool_runner,
        request,
        token: None,
        password_token: None,
    })
}

impl Drop for LoginState {
    fn drop(&mut self) {
        self.runner.abort();
    }
}

impl TelegramMessageEvent {
    fn error(error: String) -> Self {
        Self {
            ok: false,
            channel_id: 0,
            channel_title: String::new(),
            message_id: 0,
            dedup_keys: Vec::new(),
            text: String::new(),
            received_at_ms: Utc::now().timestamp_millis(),
            error: Some(error),
        }
    }
}
