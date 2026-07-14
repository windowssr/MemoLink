mod commands;
mod model;
mod net;
mod stickies;
mod store;

use net::{ensure_identity, run_server, AppEvent, AppState};
use store::{db_path, Store};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager,
};
use tauri_plugin_autostart::MacosLauncher;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let store = Store::open(&db_path()).expect("open db");
    let identity = ensure_identity(&store).expect("identity");
    let state = AppState::new(store, identity);

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--silent"]),
        ))
        .manage(state.clone())
        .invoke_handler(tauri::generate_handler![
            commands::get_pairing_payload,
            commands::refresh_pairing_ticket,
            commands::get_identity,
            commands::list_peers,
            commands::list_memos,
            commands::list_desktop_memos,
            commands::upsert_memo,
            commands::delete_memo,
            commands::get_sync_status,
            commands::list_lan_ips,
            commands::set_preferred_lan_host,
            commands::ensure_firewall_rule,
            commands::get_data_dir,
            commands::set_autostart,
            commands::is_autostart_enabled,
            commands::get_memo,
            commands::refresh_stickies,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            let state_for_server = state.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = run_server(state_for_server).await {
                    eprintln!("[memolink] server failed: {err:#}");
                }
            });

            if let Ok(payload) = state.pairing_payload() {
                let path = store::data_dir().join("pairing.json");
                if let Ok(json) = serde_json::to_string_pretty(&payload) {
                    let _ = std::fs::create_dir_all(store::data_dir());
                    let _ = std::fs::write(&path, json);
                    eprintln!("[memolink] pairing payload -> {}", path.display());
                }
            }

            let state_for_events = state.clone();
            let handle_events = handle.clone();
            tauri::async_runtime::spawn(async move {
                let mut rx = state_for_events.event_tx.subscribe();
                loop {
                    match rx.recv().await {
                        Ok(ev) => {
                            let _ = handle_events.emit("memolink://event", &ev);
                            // Keep sticky windows in sync with DB (local commands also
                            // schedule refresh; coalescing makes double-calls cheap).
                            if matches!(
                                ev,
                                AppEvent::MemosChanged
                                    | AppEvent::PeerConnected { .. }
                                    | AppEvent::Paired { .. }
                            ) {
                                let memos = state_for_events
                                    .store
                                    .lock()
                                    .list_memos(false)
                                    .unwrap_or_default();
                                stickies::schedule_refresh_stickies(&handle_events, memos);
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(_) => break,
                    }
                }
            });

            if let Some(main) = app.get_webview_window("main") {
                let _ = main.set_title("MemoLink");
                let _ = main.set_size(tauri::LogicalSize::new(720.0, 560.0));
                let _ = main.set_min_size(Some(tauri::LogicalSize::new(560.0, 420.0)));
            }

            // Never create WebViews inside setup — that freezes WebView2 on Windows.
            // Defer until the event loop is running.
            {
                let memos = state
                    .store
                    .lock()
                    .list_memos(false)
                    .unwrap_or_default();
                stickies::schedule_initial_stickies(app.handle(), memos);
            }

            let show_i = MenuItem::with_id(app, "show", "打开控制台", true, None::<&str>)?;
            let board_i = MenuItem::with_id(app, "board", "显示/隐藏便签", true, None::<&str>)?;
            let quit_i = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_i, &board_i, &quit_i])?;

            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .tooltip("MemoLink")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "board" => stickies::toggle_all_stickies(app),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                })
                .build(app)?;

            let silent = std::env::args().any(|a| a == "--silent");
            if silent {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Only the console stays resident in the tray. Sticky windows must
                // actually close/destroy so phone show/hide can remove them.
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running MemoLink");
}
