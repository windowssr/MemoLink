use crate::model::{
    DeviceIdentity, LanInfo, PairingPayload, PeerInfo, TrustedPeer, WireMessage, DEFAULT_PORT,
    PROTO_VERSION,
};
use crate::store::Store;
use anyhow::Result;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use parking_lot::Mutex;
use rand::RngCore;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Mutex<Store>>,
    pub identity: Arc<Mutex<DeviceIdentity>>,
    pub pairing_ticket: Arc<Mutex<String>>,
    pub connected: Arc<Mutex<bool>>,
    pub event_tx: broadcast::Sender<AppEvent>,
    pub active_push: Arc<Mutex<Option<tokio::sync::mpsc::UnboundedSender<WireMessage>>>>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum AppEvent {
    MemosChanged,
    PeerConnected { device_id: String },
    PeerDisconnected,
    Paired { device_id: String, display_name: String },
}

impl AppState {
    pub fn new(store: Store, identity: DeviceIdentity) -> Self {
        let (event_tx, _) = broadcast::channel(64);
        Self {
            store: Arc::new(Mutex::new(store)),
            identity: Arc::new(Mutex::new(identity)),
            pairing_ticket: Arc::new(Mutex::new(random_ticket())),
            connected: Arc::new(Mutex::new(false)),
            event_tx,
            active_push: Arc::new(Mutex::new(None)),
        }
    }

    pub fn refresh_ticket(&self) -> String {
        let ticket = random_ticket();
        *self.pairing_ticket.lock() = ticket.clone();
        if let Ok(payload) = self.pairing_payload() {
            let path = crate::store::data_dir().join("pairing.json");
            if let Ok(json) = serde_json::to_string_pretty(&payload) {
                let _ = std::fs::create_dir_all(crate::store::data_dir());
                let _ = std::fs::write(path, json);
            }
        }
        ticket
    }

    pub fn pairing_payload(&self) -> Result<PairingPayload> {
        let identity = self.identity.lock().clone();
        let ticket = self.pairing_ticket.lock().clone();
        let preferred = self
            .store
            .lock()
            .get_meta("preferred_lan_host")
            .ok()
            .flatten();
        let host = crate::store::pick_default_lan_ip(preferred.as_deref());
        Ok(PairingPayload {
            v: PROTO_VERSION,
            product: "memolink".into(),
            device_id: identity.device_id,
            display_name: identity.display_name,
            public_key: identity.public_key.clone(),
            fingerprint: fingerprint(&identity.public_key),
            ticket,
            lan: LanInfo {
                host,
                port: DEFAULT_PORT,
                service: "_memolink._tcp.local".into(),
            },
        })
    }
}

pub fn ensure_identity(store: &Store) -> Result<DeviceIdentity> {
    if let Some(id) = store.get_identity()? {
        return Ok(id);
    }
    let device_id = Uuid::new_v4().to_string();
    let mut secret_bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut secret_bytes);
    let secret = URL_SAFE_NO_PAD.encode(secret_bytes);
    let public_key = URL_SAFE_NO_PAD.encode(Sha256::digest(secret.as_bytes()));
    let identity = DeviceIdentity {
        device_id,
        display_name: format!("{} PC", whoami_hostname()),
        public_key,
        secret,
    };
    store.save_identity(&identity)?;
    Ok(identity)
}

fn whoami_hostname() -> String {
    std::env::var_os("COMPUTERNAME")
        .or_else(|| std::env::var_os("HOSTNAME"))
        .and_then(|h| h.into_string().ok())
        .unwrap_or_else(|| "MemoLink".into())
}

fn random_ticket() -> String {
    let mut bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn fingerprint(public_key: &str) -> String {
    let digest = Sha256::digest(public_key.as_bytes());
    hex::encode(&digest[..8])
}

pub fn auth_token(shared_secret: &str, device_id: &str, ts: i64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(shared_secret.as_bytes());
    hasher.update(b"|");
    hasher.update(device_id.as_bytes());
    hasher.update(b"|");
    hasher.update(ts.to_string().as_bytes());
    URL_SAFE_NO_PAD.encode(hasher.finalize())
}

pub fn try_push_to_peer(state: &AppState, msg: WireMessage) {
    if let Some(tx) = state.active_push.lock().as_ref() {
        let _ = tx.send(msg);
    }
}

async fn read_frame(stream: &mut TcpStream) -> Result<WireMessage> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > 1_048_576 {
        anyhow::bail!("frame too large");
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).await?;
    Ok(serde_json::from_slice(&buf)?)
}

async fn write_frame(stream: &mut TcpStream, msg: &WireMessage) -> Result<()> {
    let data = serde_json::to_vec(msg)?;
    let len = (data.len() as u32).to_be_bytes();
    stream.write_all(&len).await?;
    stream.write_all(&data).await?;
    stream.flush().await?;
    Ok(())
}

pub async fn run_server(state: AppState) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", DEFAULT_PORT)).await?;
    eprintln!("[memolink] listening on :{DEFAULT_PORT}");

    loop {
        let (stream, addr) = listener.accept().await?;
        eprintln!("[memolink] incoming from {addr}");
        let state_clone = state.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_connection(state_clone, stream).await {
                eprintln!("[memolink] connection error: {err:#}");
            }
        });
    }
}

async fn handle_connection(state: AppState, mut stream: TcpStream) -> Result<()> {
    let identity = state.identity.lock().clone();

    write_frame(
        &mut stream,
        &WireMessage::Hello {
            proto_version: PROTO_VERSION,
            device_id: identity.device_id.clone(),
            display_name: identity.display_name.clone(),
            public_key: identity.public_key.clone(),
            caps: vec![
                "sync.v1".into(),
                "lan.mdns".into(),
                "layout.desktop".into(),
            ],
            role: "desktop".into(),
        },
    )
    .await?;

    let peer_hello = read_frame(&mut stream).await?;
    let (peer_device_id, peer_display_name, peer_public_key) = match peer_hello {
        WireMessage::Hello {
            device_id,
            display_name,
            public_key,
            proto_version,
            ..
        } => {
            if proto_version != PROTO_VERSION {
                write_frame(
                    &mut stream,
                    &WireMessage::Error {
                        code: "version_mismatch".into(),
                        message: "unsupported proto".into(),
                        fatal: true,
                    },
                )
                .await?;
                return Ok(());
            }
            (device_id, display_name, public_key)
        }
        _ => anyhow::bail!("expected hello"),
    };

    let next = read_frame(&mut stream).await?;
    let _shared_secret = match next {
        // Fresh or re-pair (QR / pasted JSON). Allowed even if peer already exists.
        WireMessage::PairRequest { ticket, .. } => {
            if ticket != *state.pairing_ticket.lock() {
                write_frame(
                    &mut stream,
                    &WireMessage::PairReject {
                        reason: "ticket_expired".into(),
                    },
                )
                .await?;
                return Ok(());
            }
            let mut secret_bytes = [0u8; 32];
            rand::thread_rng().fill_bytes(&mut secret_bytes);
            let shared_secret = URL_SAFE_NO_PAD.encode(secret_bytes);
            let now = chrono::Utc::now().timestamp_millis();
            let peer = TrustedPeer {
                device_id: peer_device_id.clone(),
                display_name: peer_display_name.clone(),
                public_key: peer_public_key.clone(),
                paired_at: now,
                last_seen_at: Some(now),
                shared_secret: shared_secret.clone(),
            };
            state.store.lock().upsert_peer(&peer)?;
            write_frame(
                &mut stream,
                &WireMessage::PairOk {
                    paired_at: now,
                    peer: PeerInfo {
                        device_id: identity.device_id.clone(),
                        display_name: identity.display_name.clone(),
                        public_key: identity.public_key.clone(),
                    },
                    shared_secret: shared_secret.clone(),
                },
            )
            .await?;
            let _ = state.event_tx.send(AppEvent::Paired {
                device_id: peer_device_id.clone(),
                display_name: peer_display_name.clone(),
            });
            state.refresh_ticket();

            let auth = read_frame(&mut stream).await?;
            match auth {
                WireMessage::Auth {
                    device_id,
                    token,
                    ts,
                } => {
                    let expected = auth_token(&shared_secret, &device_id, ts);
                    let skew = (chrono::Utc::now().timestamp_millis() - ts).abs();
                    if device_id != peer_device_id || token != expected || skew > 120_000 {
                        write_frame(
                            &mut stream,
                            &WireMessage::AuthFail {
                                reason: "bad_sig".into(),
                            },
                        )
                        .await?;
                        return Ok(());
                    }
                }
                _ => anyhow::bail!("expected auth after pair"),
            }
            shared_secret
        }
        // Returning peer reconnect (no ticket).
        WireMessage::Auth {
            device_id,
            token,
            ts,
        } => {
            let Some(peer) = state.store.lock().find_peer(&peer_device_id)? else {
                write_frame(
                    &mut stream,
                    &WireMessage::AuthFail {
                        reason: "unknown_device".into(),
                    },
                )
                .await?;
                return Ok(());
            };
            let shared_secret = peer.shared_secret;
            let expected = auth_token(&shared_secret, &device_id, ts);
            let skew = (chrono::Utc::now().timestamp_millis() - ts).abs();
            if device_id != peer_device_id || token != expected || skew > 120_000 {
                write_frame(
                    &mut stream,
                    &WireMessage::AuthFail {
                        reason: "bad_sig".into(),
                    },
                )
                .await?;
                return Ok(());
            }
            shared_secret
        }
        _ => {
            write_frame(
                &mut stream,
                &WireMessage::PairReject {
                    reason: "expected_pair_or_auth".into(),
                },
            )
            .await?;
            return Ok(());
        }
    };

    let session_id = Uuid::new_v4().to_string();
    write_frame(
        &mut stream,
        &WireMessage::AuthOk {
            session_id: session_id.clone(),
            server_time: chrono::Utc::now().timestamp_millis(),
        },
    )
    .await?;

    let local_memos = state.store.lock().list_memos(true)?;
    write_frame(
        &mut stream,
        &WireMessage::SyncSnapshot {
            session_id: session_id.clone(),
            memos: local_memos,
        },
    )
    .await?;

    let remote_snap = read_frame(&mut stream).await?;
    if let WireMessage::SyncSnapshot { memos, .. } = remote_snap {
        let mut changed = false;
        {
            let store = state.store.lock();
            for memo in memos {
                if store.merge_memo(&memo)? {
                    changed = true;
                }
            }
            store.touch_peer(&peer_device_id, chrono::Utc::now().timestamp_millis())?;
        }
        if changed {
            let _ = state.event_tx.send(AppEvent::MemosChanged);
        }
    }

    write_frame(
        &mut stream,
        &WireMessage::SyncCaughtUp {
            session_id: session_id.clone(),
            pending_outbound: 0,
        },
    )
    .await?;

    let (push_tx, mut push_rx) = tokio::sync::mpsc::unbounded_channel::<WireMessage>();
    *state.active_push.lock() = Some(push_tx);

    *state.connected.lock() = true;
    let _ = state.event_tx.send(AppEvent::PeerConnected {
        device_id: peer_device_id.clone(),
    });

    loop {
        tokio::select! {
            msg = read_frame(&mut stream) => {
                match msg {
                    Ok(WireMessage::SyncPush { memo, .. }) => {
                        let changed = state.store.lock().merge_memo(&memo)?;
                        if changed {
                            let _ = state.event_tx.send(AppEvent::MemosChanged);
                        }
                    }
                    Ok(WireMessage::Ping { ts }) => {
                        write_frame(&mut stream, &WireMessage::Pong {
                            ts: chrono::Utc::now().timestamp_millis(),
                            echo: ts,
                        }).await?;
                    }
                    Ok(WireMessage::Pong { .. } | WireMessage::SyncCaughtUp { .. }) => {}
                    Ok(_) => {}
                    Err(err) => {
                        eprintln!("[memolink] read end: {err:#}");
                        break;
                    }
                }
            }
            Some(out) = push_rx.recv() => {
                if let Err(err) = write_frame(&mut stream, &out).await {
                    eprintln!("[memolink] push failed: {err:#}");
                    break;
                }
            }
        }
    }

    *state.active_push.lock() = None;
    *state.connected.lock() = false;
    let _ = state.event_tx.send(AppEvent::PeerDisconnected);
    Ok(())
}
