use crate::model::Memo;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

fn sticky_label(id: &str) -> String {
    format!("sticky-{}", id.replace('-', "_"))
}

fn desktop_memos(memos: &[Memo]) -> Vec<Memo> {
    memos
        .iter()
        .filter(|m| m.pinned && !m.archived && !m.deleted)
        .cloned()
        .collect()
}

/// Latest desired memo set; coalesced so rapid callers don't stampede WebView creation.
static PENDING: Mutex<Option<Vec<Memo>>> = Mutex::new(None);
/// True while a refresh worker is scheduled or running.
static SCHEDULED: AtomicBool = AtomicBool::new(false);

/// Apply one refresh pass on the UI thread.
/// Returns `true` if more sticky windows still need to be created.
fn refresh_sticky_windows_once(app: &AppHandle, memos: &[Memo]) -> Result<bool, String> {
    let memos = desktop_memos(memos);
    let wanted: HashSet<String> = memos.iter().map(|m| sticky_label(&m.id)).collect();

    let existing: Vec<String> = app
        .webview_windows()
        .keys()
        .filter(|k| k.starts_with("sticky-"))
        .cloned()
        .collect();
    for label in existing {
        if !wanted.contains(&label) {
            if let Some(w) = app.get_webview_window(&label) {
                // destroy() actually removes the window; close() is intercepted and only hides.
                let _ = w.destroy();
            }
        }
    }

    for (index, memo) in memos.iter().enumerate() {
        let label = sticky_label(&memo.id);
        if app.get_webview_window(&label).is_some() {
            if let Some(win) = app.get_webview_window(&label) {
                let _ = win.show();
            }
            continue;
        }

        // Hash route survives asset protocol better than query strings.
        let url = format!("index.html#sticky={}", memo.id);
        let x = memo.desktop_x.unwrap_or(80.0 + (index % 4) as f64 * 260.0);
        let y = memo.desktop_y.unwrap_or(80.0 + (index / 4) as f64 * 200.0);
        let w = memo.desktop_w.unwrap_or(240.0);
        let h = memo.desktop_h.unwrap_or(180.0);

        eprintln!("[memolink] create sticky window {label} -> {url}");

        WebviewWindowBuilder::new(app, &label, WebviewUrl::App(url.into()))
            .title("Memo")
            .decorations(false)
            .transparent(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .resizable(true)
            .inner_size(w, h)
            .position(x, y)
            .visible(true)
            .build()
            .map_err(|e| {
                eprintln!("[memolink] sticky window failed: {e}");
                e.to_string()
            })?;

        // Create at most one WebView per pass — WebView2 freezes on burst creates.
        let more = memos.iter().skip(index + 1).any(|m| {
            app.get_webview_window(&sticky_label(&m.id)).is_none()
        });
        return Ok(more);
    }
    Ok(false)
}

fn enqueue(memos: Vec<Memo>) {
    let mut guard = PENDING.lock().unwrap_or_else(|e| e.into_inner());
    *guard = Some(memos);
}

fn take_pending() -> Option<Vec<Memo>> {
    let mut guard = PENDING.lock().unwrap_or_else(|e| e.into_inner());
    guard.take()
}

fn kick_worker(app: AppHandle, delay_ms: u64) {
    if SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        if delay_ms > 0 {
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        }
        loop {
            let Some(memos) = take_pending() else {
                SCHEDULED.store(false, Ordering::SeqCst);
                // Race: a caller enqueued after take() but before clear.
                if PENDING
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .is_some()
                    && !SCHEDULED.swap(true, Ordering::SeqCst)
                {
                    continue;
                }
                break;
            };

            let app_main = app.clone();
            let batch = memos.clone();
            let (tx, rx) = tokio::sync::oneshot::channel::<bool>();
            if app
                .run_on_main_thread(move || {
                    let more = match refresh_sticky_windows_once(&app_main, &batch) {
                        Ok(m) => m,
                        Err(e) => {
                            eprintln!("[memolink] refresh stickies error: {e}");
                            true
                        }
                    };
                    let _ = tx.send(more);
                })
                .is_err()
            {
                SCHEDULED.store(false, Ordering::SeqCst);
                eprintln!("[memolink] run_on_main_thread failed");
                break;
            }

            let more = rx.await.unwrap_or(false);
            if more {
                // Keep working through the same snapshot unless a newer one arrived.
                {
                    let mut guard = PENDING.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.is_none() {
                        *guard = Some(memos);
                    }
                }
                tokio::time::sleep(Duration::from_millis(160)).await;
            }
        }
    });
}

/// Queue sticky refresh (coalesced + staggered) to avoid WebView2 freezes.
pub fn schedule_refresh_stickies(app: &AppHandle, memos: Vec<Memo>) {
    enqueue(memos);
    kick_worker(app.clone(), 0);
}

/// After the event loop is alive — never create WebViews inside `.setup()`.
pub fn schedule_initial_stickies(app: &AppHandle, memos: Vec<Memo>) {
    enqueue(memos);
    kick_worker(app.clone(), 450);
}

pub fn toggle_all_stickies(app: &AppHandle) {
    let stickies: Vec<_> = app
        .webview_windows()
        .into_iter()
        .filter(|(k, _)| k.starts_with("sticky-"))
        .collect();
    if stickies.is_empty() {
        return;
    }
    let any_visible = stickies
        .iter()
        .any(|(_, w)| w.is_visible().unwrap_or(false));
    for (_, w) in stickies {
        if any_visible {
            let _ = w.hide();
        } else {
            let _ = w.show();
        }
    }
}
