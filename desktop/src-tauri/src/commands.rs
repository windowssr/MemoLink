use crate::model::{Memo, SyncStatus, UpsertMemoInput, DEFAULT_PORT, WireMessage};
use crate::net::{try_push_to_peer, AppState};
use std::path::PathBuf;
use tauri::State;
use uuid::Uuid;

#[tauri::command]
pub fn get_pairing_payload(
    state: State<'_, AppState>,
) -> Result<crate::model::PairingPayload, String> {
    state.pairing_payload().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn refresh_pairing_ticket(
    state: State<'_, AppState>,
) -> Result<crate::model::PairingPayload, String> {
    state.refresh_ticket();
    state.pairing_payload().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_identity(state: State<'_, AppState>) -> crate::model::DeviceIdentity {
    state.identity.lock().clone()
}

#[tauri::command]
pub fn list_peers(state: State<'_, AppState>) -> Result<Vec<crate::model::TrustedPeer>, String> {
    state.store.lock().list_peers().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn list_memos(state: State<'_, AppState>) -> Result<Vec<Memo>, String> {
    state
        .store
        .lock()
        .list_memos(false)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn list_desktop_memos(state: State<'_, AppState>) -> Result<Vec<Memo>, String> {
    let memos = state
        .store
        .lock()
        .list_memos(false)
        .map_err(|e| e.to_string())?;
    Ok(memos
        .into_iter()
        .filter(|m| m.pinned && !m.archived && !m.deleted)
        .collect())
}

#[tauri::command]
pub fn upsert_memo(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    input: UpsertMemoInput,
) -> Result<Memo, String> {
    let identity = state.identity.lock().clone();
    let now = chrono::Utc::now().timestamp_millis();
    let store = state.store.lock();

    let memo = if let Some(id) = input.id {
        let existing = store.get_memo(&id).map_err(|e| e.to_string())?;
        let Some(mut memo) = existing else {
            return Err("memo not found".into());
        };
        memo.body = input.body;
        if let Some(c) = input.color {
            memo.color = c;
        }
        if let Some(v) = input.pinned {
            memo.pinned = v;
        }
        if let Some(v) = input.done {
            memo.done = v;
        }
        if let Some(v) = input.archived {
            memo.archived = v;
        }
        if input.desktop_x.is_some() {
            memo.desktop_x = input.desktop_x;
        }
        if input.desktop_y.is_some() {
            memo.desktop_y = input.desktop_y;
        }
        if input.desktop_w.is_some() {
            memo.desktop_w = input.desktop_w;
        }
        if input.desktop_h.is_some() {
            memo.desktop_h = input.desktop_h;
        }
        memo.updated_at = now;
        memo.revision += 1;
        memo.origin_device_id = identity.device_id;
        store.upsert_memo(&memo).map_err(|e| e.to_string())?;
        memo
    } else {
        let date = chrono::Local::now().format("%Y-%m-%d").to_string();
        let body = {
            let raw = input.body.trim();
            if raw.is_empty() {
                date
            } else if raw.starts_with(&date) || raw.contains(&format!("[{date}]")) {
                input.body
            } else {
                format!("{date}\n{raw}")
            }
        };
        let memo = Memo {
            id: Uuid::new_v4().to_string(),
            body,
            color: input.color.unwrap_or_else(|| "yellow".into()),
            pinned: input.pinned.unwrap_or(true),
            done: input.done.unwrap_or(false),
            archived: input.archived.unwrap_or(false),
            deleted: false,
            desktop_x: input.desktop_x.or(Some(80.0)),
            desktop_y: input.desktop_y.or(Some(80.0)),
            desktop_w: input.desktop_w.or(Some(240.0)),
            desktop_h: input.desktop_h.or(Some(180.0)),
            created_at: now,
            updated_at: now,
            revision: 1,
            origin_device_id: identity.device_id,
        };
        store.upsert_memo(&memo).map_err(|e| e.to_string())?;
        memo
    };

    drop(store);
    try_push_to_peer(
        &state,
        WireMessage::SyncPush {
            session_id: "live".into(),
            memo: memo.clone(),
        },
    );
    let _ = state.event_tx.send(crate::net::AppEvent::MemosChanged);
    let memos = state
        .store
        .lock()
        .list_memos(false)
        .unwrap_or_default();
    crate::stickies::schedule_refresh_stickies(&app, memos);
    Ok(memo)
}

#[tauri::command]
pub fn delete_memo(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: String,
) -> Result<(), String> {
    let identity = state.identity.lock().clone();
    let now = chrono::Utc::now().timestamp_millis();
    let store = state.store.lock();
    let Some(mut memo) = store.get_memo(&id).map_err(|e| e.to_string())? else {
        return Ok(());
    };
    memo.deleted = true;
    memo.updated_at = now;
    memo.revision += 1;
    memo.origin_device_id = identity.device_id;
    store.upsert_memo(&memo).map_err(|e| e.to_string())?;
    drop(store);
    try_push_to_peer(
        &state,
        WireMessage::SyncPush {
            session_id: "live".into(),
            memo: memo.clone(),
        },
    );
    let _ = state.event_tx.send(crate::net::AppEvent::MemosChanged);
    let memos = state
        .store
        .lock()
        .list_memos(false)
        .unwrap_or_default();
    crate::stickies::schedule_refresh_stickies(&app, memos);
    Ok(())
}

#[tauri::command]
pub fn get_memo(state: State<'_, AppState>, id: String) -> Result<Option<Memo>, String> {
    state.store.lock().get_memo(&id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn refresh_stickies(app: tauri::AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let memos = state
        .store
        .lock()
        .list_memos(false)
        .map_err(|e| e.to_string())?;
    crate::stickies::schedule_refresh_stickies(&app, memos);
    Ok(())
}

#[tauri::command]
pub fn get_sync_status(state: State<'_, AppState>) -> Result<SyncStatus, String> {
    let store = state.store.lock();
    let peers = store.list_peers().map_err(|e| e.to_string())?;
    let preferred = store.get_meta("preferred_lan_host").ok().flatten();
    let ips = crate::store::list_lan_ipv4();
    let local_ip = Some(crate::store::pick_default_lan_ip(preferred.as_deref()));
    Ok(SyncStatus {
        listening: true,
        port: DEFAULT_PORT,
        local_ip,
        local_ips: ips,
        paired_count: peers.len(),
        connected: *state.connected.lock(),
        pending_outbound: 0,
    })
}

#[tauri::command]
pub fn list_lan_ips() -> Vec<String> {
    crate::store::list_lan_ipv4()
}

#[tauri::command]
pub fn set_preferred_lan_host(
    state: State<'_, AppState>,
    host: String,
) -> Result<crate::model::PairingPayload, String> {
    state
        .store
        .lock()
        .set_meta("preferred_lan_host", &host)
        .map_err(|e| e.to_string())?;
    state.pairing_payload().map_err(|e| e.to_string())
}

/// Best-effort: launch elevated helper to add firewall rule (UAC prompt).
#[tauri::command]
pub fn ensure_firewall_rule() -> Result<String, String> {
    #[cfg(target_os = "windows")]
    {
        // Prefer shipped helper next to exe / in scripts during dev
        let exe_dir = crate::store::data_dir();
        let candidates = [
            exe_dir.join("add-firewall.bat"),
            exe_dir
                .join("..")
                .join("..")
                .join("..")
                .join("..")
                .join("scripts")
                .join("add-firewall.bat"),
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts/add-firewall.bat"),
        ];
        let bat = candidates.into_iter().find(|p| p.exists());
        if let Some(bat) = bat {
            let status = std::process::Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-Command",
                    &format!(
                        "Start-Process -FilePath '{}' -Verb RunAs -Wait",
                        bat.display().to_string().replace('\'', "''")
                    ),
                ])
                .status()
                .map_err(|e| e.to_string())?;
            if status.success() {
                return Ok("已弹出管理员确认框并尝试添加防火墙规则".into());
            }
            return Err("提权添加防火墙失败，请手动右键 add-firewall.bat 以管理员运行".into());
        }

        // Fallback: try netsh directly (usually needs already-elevated process)
        let status = std::process::Command::new("netsh")
            .args([
                "advfirewall",
                "firewall",
                "add",
                "rule",
                "name=MemoLink Port 47820",
                "dir=in",
                "action=allow",
                "protocol=TCP",
                "localport=47820",
            ])
            .status()
            .map_err(|e| e.to_string())?;
        if status.success() {
            Ok("已添加端口防火墙规则".into())
        } else {
            Err("添加防火墙规则失败。请运行程序目录下的 add-firewall.bat（会提示管理员权限）".into())
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        Ok("非 Windows，无需此操作".into())
    }
}

#[tauri::command]
pub fn get_data_dir() -> String {
    crate::store::data_dir().to_string_lossy().to_string()
}

#[tauri::command]
pub fn set_autostart(enabled: bool, app: tauri::AppHandle) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    let autostart = app.autolaunch();
    if enabled {
        autostart.enable().map_err(|e| e.to_string())?;
    } else {
        autostart.disable().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn is_autostart_enabled(app: tauri::AppHandle) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().map_err(|e| e.to_string())
}
