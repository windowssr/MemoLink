use serde::{Deserialize, Serialize};

pub const PROTO_VERSION: u32 = 1;
pub const DEFAULT_PORT: u16 = 47820;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceIdentity {
    pub device_id: String,
    pub display_name: String,
    pub public_key: String,
    pub secret: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedPeer {
    pub device_id: String,
    pub display_name: String,
    pub public_key: String,
    pub paired_at: i64,
    pub last_seen_at: Option<i64>,
    pub shared_secret: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Memo {
    pub id: String,
    pub body: String,
    pub color: String,
    pub pinned: bool,
    pub done: bool,
    pub archived: bool,
    pub deleted: bool,
    pub desktop_x: Option<f64>,
    pub desktop_y: Option<f64>,
    pub desktop_w: Option<f64>,
    pub desktop_h: Option<f64>,
    pub created_at: i64,
    pub updated_at: i64,
    pub revision: i64,
    pub origin_device_id: String,
}

impl Memo {
    pub fn wins_over(&self, other: &Memo) -> bool {
        if self.updated_at != other.updated_at {
            return self.updated_at > other.updated_at;
        }
        if self.revision != other.revision {
            return self.revision > other.revision;
        }
        self.origin_device_id > other.origin_device_id
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingPayload {
    pub v: u32,
    pub product: String,
    pub device_id: String,
    pub display_name: String,
    pub public_key: String,
    pub fingerprint: String,
    pub ticket: String,
    pub lan: LanInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LanInfo {
    pub host: String,
    pub port: u16,
    pub service: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WireMessage {
    Hello {
        #[serde(rename = "protoVersion")]
        proto_version: u32,
        #[serde(rename = "deviceId")]
        device_id: String,
        #[serde(rename = "displayName")]
        display_name: String,
        #[serde(rename = "publicKey")]
        public_key: String,
        caps: Vec<String>,
        role: String,
    },
    PairRequest {
        ticket: String,
        nonce: String,
        ts: i64,
    },
    PairOk {
        #[serde(rename = "pairedAt")]
        paired_at: i64,
        peer: PeerInfo,
        #[serde(rename = "sharedSecret")]
        shared_secret: String,
    },
    PairReject {
        reason: String,
    },
    Auth {
        #[serde(rename = "deviceId")]
        device_id: String,
        token: String,
        ts: i64,
    },
    AuthOk {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "serverTime")]
        server_time: i64,
    },
    AuthFail {
        reason: String,
    },
    SyncSnapshot {
        #[serde(rename = "sessionId")]
        session_id: String,
        memos: Vec<Memo>,
    },
    SyncPush {
        #[serde(rename = "sessionId")]
        session_id: String,
        memo: Memo,
    },
    SyncCaughtUp {
        #[serde(rename = "sessionId")]
        session_id: String,
        #[serde(rename = "pendingOutbound")]
        pending_outbound: u32,
    },
    Ping {
        ts: i64,
    },
    Pong {
        ts: i64,
        echo: i64,
    },
    Error {
        code: String,
        message: String,
        fatal: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerInfo {
    pub device_id: String,
    pub display_name: String,
    pub public_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncStatus {
    pub listening: bool,
    pub port: u16,
    pub local_ip: Option<String>,
    pub local_ips: Vec<String>,
    pub paired_count: usize,
    pub connected: bool,
    pub pending_outbound: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpsertMemoInput {
    pub id: Option<String>,
    pub body: String,
    pub color: Option<String>,
    pub pinned: Option<bool>,
    pub done: Option<bool>,
    pub archived: Option<bool>,
    pub desktop_x: Option<f64>,
    pub desktop_y: Option<f64>,
    pub desktop_w: Option<f64>,
    pub desktop_h: Option<f64>,
}
