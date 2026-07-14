import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { QRCodeSVG } from "qrcode.react";
import "./App.css";

type Memo = {
  id: string;
  body: string;
  color: string;
  pinned: boolean;
  done: boolean;
  archived: boolean;
  deleted: boolean;
  desktopX?: number | null;
  desktopY?: number | null;
  desktopW?: number | null;
  desktopH?: number | null;
  createdAt: number;
  updatedAt: number;
  revision: number;
  originDeviceId: string;
};

type PairingPayload = {
  v: number;
  product: string;
  deviceId: string;
  displayName: string;
  publicKey: string;
  fingerprint: string;
  ticket: string;
  lan: { host: string; port: number; service: string };
};

type SyncStatus = {
  listening: boolean;
  port: number;
  localIp?: string | null;
  localIps?: string[];
  pairedCount: number;
  connected: boolean;
  pendingOutbound: number;
};

type Peer = {
  deviceId: string;
  displayName: string;
  publicKey: string;
  pairedAt: number;
  lastSeenAt?: number | null;
};

const COLORS: Record<string, string> = {
  yellow: "#f5e6a8",
  pink: "#f3c6d4",
  blue: "#c7dff5",
  green: "#cfe8c9",
  gray: "#e2e2e2",
};

function useView(): { kind: "main" } | { kind: "sticky"; id: string } {
  // Prefer hash: asset protocol often drops query strings on sticky windows.
  const hash = window.location.hash || "";
  if (hash.startsWith("#sticky=")) {
    return { kind: "sticky", id: decodeURIComponent(hash.slice("#sticky=".length)) };
  }
  const params = new URLSearchParams(window.location.search);
  if (params.get("view") === "sticky") {
    return { kind: "sticky", id: params.get("id") || "" };
  }
  return { kind: "main" };
}

function formatDate(ts: number): string {
  const d = new Date(ts);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function previewText(body: string): string {
  const line =
    body
      .split("\n")
      .map((s) => s.trim())
      .find((s) => s && !/^\d{4}-\d{2}-\d{2}/.test(s)) || body.trim();
  return line.slice(0, 18) || "便签";
}

function StickyView({ id }: { id: string }) {
  const [memo, setMemo] = useState<Memo | null>(null);
  const [loading, setLoading] = useState(true);
  const [compact, setCompact] = useState(false);
  const expandedSize = useRef({ w: 240, h: 180 });
  const savingRef = useRef(false);

  const reload = useCallback(async () => {
    if (!id) {
      setMemo(null);
      setLoading(false);
      return;
    }
    try {
      const m = await invoke<Memo | null>("get_memo", { id });
      // Desktop-visible stickies are pinned && !archived && !deleted
      setMemo(m && !m.deleted && !m.archived && m.pinned ? m : null);
    } catch (e) {
      console.error("get_memo failed", e);
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    setLoading(true);
    reload();
    const un = listen<{ kind?: string }>("memolink://event", (ev) => {
      // Avoid reload storms while saving; only care about memo changes
      if (savingRef.current) return;
      const kind = ev.payload?.kind;
      if (!kind || kind === "memosChanged") {
        reload();
      }
    });
    return () => {
      un.then((f) => f());
    };
  }, [reload]);

  if (loading) {
    return (
      <div className="sticky-window empty" style={{ background: "#f5e6a8" }}>
        加载中…
      </div>
    );
  }

  if (!memo) {
    return <div className="sticky-window empty">已关闭</div>;
  }

  const dateLabel = formatDate(memo.createdAt);

  const patch = async (partial: Partial<Memo> & { body?: string }) => {
    savingRef.current = true;
    try {
      await invoke("upsert_memo", {
        input: {
          id: memo.id,
          body: partial.body ?? memo.body,
          color: partial.color ?? memo.color,
          pinned: partial.pinned ?? memo.pinned,
          done: partial.done ?? memo.done,
          archived: partial.archived ?? memo.archived,
          desktopX: memo.desktopX,
          desktopY: memo.desktopY,
          desktopW: memo.desktopW,
          desktopH: memo.desktopH,
        },
      });
      await reload();
    } finally {
      // allow events after a short delay
      setTimeout(() => {
        savingRef.current = false;
      }, 300);
    }
  };

  const toggleCompact = async () => {
    const win = getCurrentWindow();
    if (!compact) {
      try {
        const size = await win.innerSize();
        const factor = await win.scaleFactor();
        expandedSize.current = {
          w: Math.max(160, size.width / factor),
          h: Math.max(120, size.height / factor),
        };
      } catch {
        /* ignore */
      }
      await win.setSize(new LogicalSize(168, 36));
      setCompact(true);
    } else {
      const { w, h } = expandedSize.current;
      await win.setSize(new LogicalSize(w, h));
      setCompact(false);
    }
  };

  const closeSticky = async () => {
    await patch({ archived: true, pinned: false });
    await getCurrentWindow().hide();
  };

  if (compact) {
    return (
      <div
        className="sticky-chip"
        style={{ background: COLORS[memo.color] || COLORS.yellow }}
      >
        <div
          className="chip-drag"
          data-tauri-drag-region
          onPointerDown={(e) => {
            // Fallback: explicit startDragging (Windows needs a solid drag region)
            if (e.button !== 0) return;
            if ((e.target as HTMLElement).closest("button")) return;
            getCurrentWindow().startDragging().catch(() => {});
          }}
          onDoubleClick={toggleCompact}
          title="拖动移动 · 双击展开"
        >
          <span className="chip-date">{dateLabel}</span>
          <span className="chip-text">{previewText(memo.body)}</span>
        </div>
        <button
          className="chip-btn"
          onClick={(e) => {
            e.stopPropagation();
            toggleCompact();
          }}
          title="展开"
        >
          ▢
        </button>
        <button
          className="chip-btn"
          onClick={(e) => {
            e.stopPropagation();
            closeSticky();
          }}
          title="关闭"
        >
          ×
        </button>
      </div>
    );
  }

  return (
    <div
      className={`sticky-window ${memo.done ? "done" : ""}`}
      style={{ background: COLORS[memo.color] || COLORS.yellow }}
    >
      <div className="sticky-bar" data-tauri-drag-region>
        <button
          className="check"
          onClick={() => patch({ done: !memo.done })}
          title="完成"
        >
          {memo.done ? "✓" : "○"}
        </button>
        <span className="sticky-date">{dateLabel}</span>
        <span className="bar-spacer" data-tauri-drag-region />
        <button
          className="icon-btn"
          onClick={toggleCompact}
          title="最小弹窗"
        >
          –
        </button>
        <button className="icon-btn" onClick={closeSticky} title="关闭">
          ×
        </button>
      </div>
      <textarea
        key={memo.updatedAt}
        defaultValue={memo.body}
        onBlur={(e) => {
          if (e.target.value !== memo.body) {
            patch({ body: e.target.value });
          }
        }}
      />
    </div>
  );
}

function MainView() {
  const [payload, setPayload] = useState<PairingPayload | null>(null);
  const [status, setStatus] = useState<SyncStatus | null>(null);
  const [peers, setPeers] = useState<Peer[]>([]);
  const [memos, setMemos] = useState<Memo[]>([]);
  const [draft, setDraft] = useState("");
  const [autostart, setAutostart] = useState(false);
  const [copied, setCopied] = useState(false);
  const [dataDir, setDataDir] = useState("");
  const [fwMsg, setFwMsg] = useState("");

  const [tab, setTab] = useState<"pair" | "notes" | "devices" | "settings">(
    "pair",
  );

  const qrValue = useMemo(
    () => (payload ? JSON.stringify(payload) : ""),
    [payload],
  );

  const reload = useCallback(async () => {
    const [p, s, peerList, memoList, auto, dir] = await Promise.all([
      invoke<PairingPayload>("get_pairing_payload"),
      invoke<SyncStatus>("get_sync_status"),
      invoke<Peer[]>("list_peers"),
      invoke<Memo[]>("list_memos"),
      invoke<boolean>("is_autostart_enabled"),
      invoke<string>("get_data_dir"),
    ]);
    setPayload(p);
    setStatus(s);
    setPeers(peerList);
    setMemos(memoList.filter((m) => !m.deleted));
    setAutostart(auto);
    setDataDir(dir);
  }, []);

  useEffect(() => {
    reload();
    // Backend already schedules initial stickies after boot; only nudge once
    // after the console is ready (avoids create-storm with setup).
    const boot = window.setTimeout(() => {
      invoke("refresh_stickies").catch(() => {});
    }, 600);
    const un = listen("memolink://event", () => reload());
    const timer = setInterval(() => {
      invoke<SyncStatus>("get_sync_status").then(setStatus).catch(() => {});
    }, 3000);
    return () => {
      un.then((f) => f());
      clearInterval(timer);
      clearTimeout(boot);
    };
  }, [reload]);

  const refreshTicket = async () => {
    const p = await invoke<PairingPayload>("refresh_pairing_ticket");
    setPayload(p);
  };

  const addMemo = async () => {
    if (!draft.trim()) return;
    await invoke("upsert_memo", {
      input: {
        body: draft.trim(),
        color: "yellow",
        pinned: true,
        done: false,
      },
    });
    setDraft("");
    reload();
  };

  const setDesktopVisible = async (memo: Memo, visible: boolean) => {
    await invoke("upsert_memo", {
      input: {
        id: memo.id,
        body: memo.body,
        color: memo.color,
        pinned: visible,
        done: memo.done,
        archived: visible ? false : memo.archived,
        desktopX: memo.desktopX,
        desktopY: memo.desktopY,
        desktopW: memo.desktopW,
        desktopH: memo.desktopH,
      },
    });
    await invoke("refresh_stickies");
    reload();
  };

  const deleteMemo = async (memo: Memo) => {
    if (!confirm(`删除便签？\n${memo.body.slice(0, 40) || "(空)"}`)) return;
    await invoke("delete_memo", { id: memo.id });
    await invoke("refresh_stickies");
    reload();
  };

  const toggleAutostart = async () => {
    await invoke("set_autostart", { enabled: !autostart });
    setAutostart(!autostart);
  };

  const copyPairing = async () => {
    if (!qrValue) return;
    await navigator.clipboard.writeText(qrValue);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  const changeLanIp = async (host: string) => {
    const p = await invoke<PairingPayload>("set_preferred_lan_host", { host });
    setPayload(p);
    const s = await invoke<SyncStatus>("get_sync_status");
    setStatus(s);
  };

  const addFirewall = async () => {
    try {
      const msg = await invoke<string>("ensure_firewall_rule");
      setFwMsg(msg);
    } catch (e) {
      setFwMsg(String(e));
    }
  };

  const visibleCount = memos.filter((m) => m.pinned && !m.archived).length;

  return (
    <div className="shell">
      <aside className="nav">
        <div className="nav-brand">
          <strong>MemoLink</strong>
          <span className={status?.connected ? "ok" : "muted"}>
            {status?.connected ? "已连接" : "未连接"}
          </span>
        </div>
        <nav className="nav-list">
          {(
            [
              ["pair", "配对同步"],
              ["notes", "便签"],
              ["devices", "设备"],
              ["settings", "设置"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              className={tab === id ? "nav-item active" : "nav-item"}
              onClick={() => setTab(id)}
            >
              {label}
            </button>
          ))}
        </nav>
        <button
          className="nav-hide"
          onClick={() => getCurrentWindow().hide()}
        >
          隐藏到托盘
        </button>
      </aside>

      <main className="content">
        {tab === "pair" && (
          <div className="content-scroll">
            <h1>配对同步</h1>
            <section className="card">
              <div className="row">
                <strong>状态</strong>
                <span className={status?.connected ? "ok" : "muted"}>
                  {status?.connected ? "已连接手机" : "等待连接"}
                </span>
              </div>
              <div className="muted small">
                监听 {status?.localIp || "…"}:{status?.port} · 已配对{" "}
                {status?.pairedCount ?? 0} 台
              </div>
              <p className="warn small">
                手机必须连同一 WiFi（关掉 5G/4G 流量），否则会超时。
              </p>
              {(status?.localIps?.length ?? 0) > 0 && (
                <label className="ip-pick">
                  <span className="muted small">配对用局域网 IP</span>
                  <select
                    value={payload?.lan.host || status?.localIp || ""}
                    onChange={(e) => changeLanIp(e.target.value)}
                  >
                    {(status?.localIps || []).map((ip) => (
                      <option key={ip} value={ip}>
                        {ip}
                      </option>
                    ))}
                  </select>
                </label>
              )}
              <button className="ghost" onClick={addFirewall}>
                放行防火墙端口 47820
              </button>
              {fwMsg && <p className="muted small">{fwMsg}</p>}
            </section>

            <section className="card center">
              <h2>扫码配对</h2>
              {qrValue && (
                <div className="qr-wrap">
                  <QRCodeSVG value={qrValue} size={200} />
                </div>
              )}
              <p className="muted small">
                相机不可用时，点下方复制后到手机「粘贴 JSON」。
              </p>
              <div className="row" style={{ marginTop: 8 }}>
                <button onClick={refreshTicket}>刷新二维码</button>
                <button
                  className="ghost"
                  style={{ marginTop: 0, width: "auto" }}
                  onClick={copyPairing}
                >
                  {copied ? "已复制" : "复制配对 JSON"}
                </button>
              </div>
            </section>
          </div>
        )}

        {tab === "notes" && (
          <div className="content-scroll">
            <h1>便签</h1>
            <section className="card">
              <h2>快速记</h2>
              <textarea
                className="draft"
                placeholder="写一条便签…"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
              />
              <button onClick={addMemo}>添加到桌面</button>
            </section>

            <section className="card">
              <div className="row">
                <h2 style={{ margin: 0 }}>管理</h2>
                <span className="muted small">
                  桌面显示 {visibleCount}/{memos.length}
                </span>
              </div>
              {memos.length === 0 && <p className="muted">暂无便签</p>}
              <ul className="memo-manage">
                {memos.map((m) => {
                  const onDesktop = m.pinned && !m.archived;
                  return (
                    <li key={m.id} className="memo-manage-item">
                      <div className="memo-manage-main">
                        <span className="memo-date">
                          {new Date(m.createdAt).toLocaleDateString("zh-CN")}
                        </span>
                        <span className={`memo-body ${m.done ? "strike" : ""}`}>
                          {m.body || "(空)"}
                        </span>
                      </div>
                      <div className="memo-manage-actions">
                        <button
                          className={onDesktop ? "mini on" : "mini"}
                          onClick={() => setDesktopVisible(m, !onDesktop)}
                        >
                          {onDesktop ? "显示中" : "已隐藏"}
                        </button>
                        <button
                          className="mini danger"
                          onClick={() => deleteMemo(m)}
                        >
                          删除
                        </button>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </section>
          </div>
        )}

        {tab === "devices" && (
          <div className="content-scroll">
            <h1>设备</h1>
            <section className="card">
              <h2>已配对设备</h2>
              {peers.length === 0 && <p className="muted">尚未配对</p>}
              {peers.map((p) => (
                <div key={p.deviceId} className="peer">
                  {p.displayName}
                </div>
              ))}
            </section>
          </div>
        )}

        {tab === "settings" && (
          <div className="content-scroll">
            <h1>设置</h1>
            <section className="card">
              <div className="row">
                <strong>开机自启</strong>
                <button onClick={toggleAutostart}>
                  {autostart ? "已开启" : "未开启"}
                </button>
              </div>
              <p className="muted small" style={{ marginTop: 12 }}>
                数据目录（程序同级）：
              </p>
              <p className="path-box">{dataDir || "…"}</p>
              <button
                className="ghost"
                onClick={() => getCurrentWindow().hide()}
              >
                隐藏到托盘
              </button>
            </section>
          </div>
        )}
      </main>
    </div>
  );
}

export default function App() {
  const view = useView();
  if (view.kind === "sticky") {
    return <StickyView id={view.id} />;
  }
  return <MainView />;
}
