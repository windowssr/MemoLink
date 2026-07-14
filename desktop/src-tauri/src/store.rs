use crate::model::{DeviceIdentity, Memo, TrustedPeer};
use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};
// local_ip_address used by list_lan_ipv4

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // One-time migrate from old AppData location if present.
        if !path.exists() {
            if let Some(old) = dirs::data_dir().map(|d| d.join("MemoLink").join("memolink.db")) {
                if old.exists() {
                    let _ = std::fs::copy(&old, path);
                    eprintln!(
                        "[memolink] migrated db {} -> {}",
                        old.display(),
                        path.display()
                    );
                }
            }
        }
        let conn = Connection::open(path).context("open sqlite")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        self.conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS identity (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              device_id TEXT NOT NULL,
              display_name TEXT NOT NULL,
              public_key TEXT NOT NULL,
              secret TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS peers (
              device_id TEXT PRIMARY KEY,
              display_name TEXT NOT NULL,
              public_key TEXT NOT NULL,
              paired_at INTEGER NOT NULL,
              last_seen_at INTEGER,
              shared_secret TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS memos (
              id TEXT PRIMARY KEY,
              body TEXT NOT NULL,
              color TEXT NOT NULL,
              pinned INTEGER NOT NULL,
              done INTEGER NOT NULL,
              archived INTEGER NOT NULL,
              deleted INTEGER NOT NULL,
              desktop_x REAL,
              desktop_y REAL,
              desktop_w REAL,
              desktop_h REAL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              revision INTEGER NOT NULL,
              origin_device_id TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            "#,
        )?;
        Ok(())
    }

    pub fn get_identity(&self) -> Result<Option<DeviceIdentity>> {
        let mut stmt = self.conn.prepare(
            "SELECT device_id, display_name, public_key, secret FROM identity WHERE id = 1",
        )?;
        let mut rows = stmt.query([])?;
        if let Some(row) = rows.next()? {
            Ok(Some(DeviceIdentity {
                device_id: row.get(0)?,
                display_name: row.get(1)?,
                public_key: row.get(2)?,
                secret: row.get(3)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn save_identity(&self, identity: &DeviceIdentity) -> Result<()> {
        self.conn.execute(
            "INSERT INTO identity (id, device_id, display_name, public_key, secret)
             VALUES (1, ?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET
               device_id=excluded.device_id,
               display_name=excluded.display_name,
               public_key=excluded.public_key,
               secret=excluded.secret",
            params![
                identity.device_id,
                identity.display_name,
                identity.public_key,
                identity.secret
            ],
        )?;
        Ok(())
    }

    pub fn list_peers(&self) -> Result<Vec<TrustedPeer>> {
        let mut stmt = self.conn.prepare(
            "SELECT device_id, display_name, public_key, paired_at, last_seen_at, shared_secret FROM peers",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(TrustedPeer {
                device_id: row.get(0)?,
                display_name: row.get(1)?,
                public_key: row.get(2)?,
                paired_at: row.get(3)?,
                last_seen_at: row.get(4)?,
                shared_secret: row.get(5)?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn upsert_peer(&self, peer: &TrustedPeer) -> Result<()> {
        self.conn.execute(
            "INSERT INTO peers (device_id, display_name, public_key, paired_at, last_seen_at, shared_secret)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(device_id) DO UPDATE SET
               display_name=excluded.display_name,
               public_key=excluded.public_key,
               paired_at=excluded.paired_at,
               last_seen_at=excluded.last_seen_at,
               shared_secret=excluded.shared_secret",
            params![
                peer.device_id,
                peer.display_name,
                peer.public_key,
                peer.paired_at,
                peer.last_seen_at,
                peer.shared_secret
            ],
        )?;
        Ok(())
    }

    pub fn find_peer(&self, device_id: &str) -> Result<Option<TrustedPeer>> {
        let mut stmt = self.conn.prepare(
            "SELECT device_id, display_name, public_key, paired_at, last_seen_at, shared_secret
             FROM peers WHERE device_id = ?1",
        )?;
        let mut rows = stmt.query(params![device_id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(TrustedPeer {
                device_id: row.get(0)?,
                display_name: row.get(1)?,
                public_key: row.get(2)?,
                paired_at: row.get(3)?,
                last_seen_at: row.get(4)?,
                shared_secret: row.get(5)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn touch_peer(&self, device_id: &str, ts: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE peers SET last_seen_at = ?1 WHERE device_id = ?2",
            params![ts, device_id],
        )?;
        Ok(())
    }

    pub fn list_memos(&self, include_deleted: bool) -> Result<Vec<Memo>> {
        let sql = if include_deleted {
            "SELECT id, body, color, pinned, done, archived, deleted, desktop_x, desktop_y, desktop_w, desktop_h, created_at, updated_at, revision, origin_device_id FROM memos"
        } else {
            "SELECT id, body, color, pinned, done, archived, deleted, desktop_x, desktop_y, desktop_w, desktop_h, created_at, updated_at, revision, origin_device_id FROM memos WHERE deleted = 0"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let rows = stmt.query_map([], |row| {
            Ok(Memo {
                id: row.get(0)?,
                body: row.get(1)?,
                color: row.get(2)?,
                pinned: row.get::<_, i64>(3)? != 0,
                done: row.get::<_, i64>(4)? != 0,
                archived: row.get::<_, i64>(5)? != 0,
                deleted: row.get::<_, i64>(6)? != 0,
                desktop_x: row.get(7)?,
                desktop_y: row.get(8)?,
                desktop_w: row.get(9)?,
                desktop_h: row.get(10)?,
                created_at: row.get(11)?,
                updated_at: row.get(12)?,
                revision: row.get(13)?,
                origin_device_id: row.get(14)?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn get_memo(&self, id: &str) -> Result<Option<Memo>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, body, color, pinned, done, archived, deleted, desktop_x, desktop_y, desktop_w, desktop_h, created_at, updated_at, revision, origin_device_id FROM memos WHERE id = ?1",
        )?;
        let mut rows = stmt.query(params![id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(Memo {
                id: row.get(0)?,
                body: row.get(1)?,
                color: row.get(2)?,
                pinned: row.get::<_, i64>(3)? != 0,
                done: row.get::<_, i64>(4)? != 0,
                archived: row.get::<_, i64>(5)? != 0,
                deleted: row.get::<_, i64>(6)? != 0,
                desktop_x: row.get(7)?,
                desktop_y: row.get(8)?,
                desktop_w: row.get(9)?,
                desktop_h: row.get(10)?,
                created_at: row.get(11)?,
                updated_at: row.get(12)?,
                revision: row.get(13)?,
                origin_device_id: row.get(14)?,
            }))
        } else {
            Ok(None)
        }
    }

    pub fn upsert_memo(&self, memo: &Memo) -> Result<()> {
        self.conn.execute(
            "INSERT INTO memos (id, body, color, pinned, done, archived, deleted, desktop_x, desktop_y, desktop_w, desktop_h, created_at, updated_at, revision, origin_device_id)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
             ON CONFLICT(id) DO UPDATE SET
               body=excluded.body,
               color=excluded.color,
               pinned=excluded.pinned,
               done=excluded.done,
               archived=excluded.archived,
               deleted=excluded.deleted,
               desktop_x=excluded.desktop_x,
               desktop_y=excluded.desktop_y,
               desktop_w=excluded.desktop_w,
               desktop_h=excluded.desktop_h,
               created_at=excluded.created_at,
               updated_at=excluded.updated_at,
               revision=excluded.revision,
               origin_device_id=excluded.origin_device_id",
            params![
                memo.id,
                memo.body,
                memo.color,
                memo.pinned as i64,
                memo.done as i64,
                memo.archived as i64,
                memo.deleted as i64,
                memo.desktop_x,
                memo.desktop_y,
                memo.desktop_w,
                memo.desktop_h,
                memo.created_at,
                memo.updated_at,
                memo.revision,
                memo.origin_device_id
            ],
        )?;
        Ok(())
    }

    pub fn merge_memo(&self, incoming: &Memo) -> Result<bool> {
        match self.get_memo(&incoming.id)? {
            None => {
                self.upsert_memo(incoming)?;
                Ok(true)
            }
            Some(existing) => {
                if incoming.wins_over(&existing) {
                    self.upsert_memo(incoming)?;
                    Ok(true)
                } else {
                    Ok(false)
                }
            }
        }
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_meta(&self, key: &str) -> Result<Option<String>> {
        let mut stmt = self.conn.prepare("SELECT value FROM meta WHERE key = ?1")?;
        let mut rows = stmt.query(params![key])?;
        if let Some(row) = rows.next()? {
            Ok(Some(row.get(0)?))
        } else {
            Ok(None)
        }
    }
}

/// Data lives next to the executable (program directory).
pub fn data_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn db_path() -> PathBuf {
    data_dir().join("memolink.db")
}

pub fn list_lan_ipv4() -> Vec<String> {
    let mut ips = Vec::new();
    if let Ok(ifaces) = local_ip_address::list_afinet_netifas() {
        for (name, ip) in ifaces {
            let s = ip.to_string();
            if s.starts_with("127.") {
                continue;
            }
            // Skip obvious virtual adapters when ranking later; still list them.
            let _ = name;
            if s.parse::<std::net::Ipv4Addr>().is_ok() {
                if !ips.contains(&s) {
                    ips.push(s);
                }
            }
        }
    }
    ips.sort_by(|a, b| {
        rank_ip(b)
            .cmp(&rank_ip(a))
            .then_with(|| a.cmp(b))
    });
    ips
}

fn rank_ip(ip: &str) -> i32 {
    if ip.starts_with("192.168.") {
        // Common home Wi-Fi; deprioritize VirtualBox/host-only ranges a bit
        if ip.starts_with("192.168.56.") || ip.starts_with("192.168.137.") {
            return 50;
        }
        return 100;
    }
    if ip.starts_with("10.") {
        return 80;
    }
    if ip.starts_with("172.") {
        return 70;
    }
    10
}

pub fn pick_default_lan_ip(preferred: Option<&str>) -> String {
    let ips = list_lan_ipv4();
    if let Some(p) = preferred {
        if ips.iter().any(|x| x == p) {
            return p.to_string();
        }
    }
    ips.into_iter()
        .next()
        .or_else(|| local_ip_address::local_ip().ok().map(|ip| ip.to_string()))
        .unwrap_or_else(|| "127.0.0.1".into())
}
