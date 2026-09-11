"""
健康数据 API 服务 v2.0
接收 iPhone 快捷指令推送的 Apple Health 数据，写入 Obsidian Vault

启动: uvicorn health_api_server:app --host 0.0.0.0 --port 8765
Auth: 环境变量 HEALTH_API_TOKEN（必填，未设置为空）
"""

from fastapi import FastAPI, Header, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
import os, json, threading
from datetime import datetime

VAULT = os.environ.get("OBSIDIAN_VAULT", "")
if not VAULT:
    print("ERROR: OBSIDIAN_VAULT must be set", flush=True)
    raise SystemExit(1)
HEALTH_DIR = f"{VAULT}/data/health"
SLEEP_DIR = f"{VAULT}/data/sleep"
BODY_DIR = f"{VAULT}/data/body"

# HealthSync iOS App 全量样本落盘目录（Health vault data/raw）
HEALTH_VAULT = VAULT
RAW_DIR = f"{HEALTH_VAULT}/data/raw"

VALID_TOKEN = os.environ.get("HEALTH_API_TOKEN", "")

app = FastAPI(title="Health API", version="2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def verify_token(authorization: str | None = Header(None)):
    if not authorization or authorization != f"Bearer {VALID_TOKEN}":
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.post("/api/ingest")
async def ingest_health(payload: dict, _=Depends(verify_token)):
    """HealthSync iOS App 全量健康样本接收。

    payload 结构（与 iOS HealthSampleDTO / SyncPayload 对应）：
    {
      "device": {"model": "...", "os": "...", "app": "HealthSync/1.0"},
      "batch": [
        {
          "id": "UUID", "type": "HKQuantityTypeIdentifierStepCount",
          "category": "activity", "startDate": "2026-08-24T...Z", "endDate": "...",
          "value": 1234.0, "unit": "count", "valueDescription": null,
          "sourceName": "...", "sourceBundleID": "...", "deviceName": "...",
          "metadata": {...}, "fingerprint": "..."
        }, ...
      ],
      "range": {"start": "...", "end": "..."},
      "cursorFingerprint": "...",
      "fullSync": false
    }
    落盘：Health vault data/raw/YYYY-MM-DD.json（全量明细，去重 by fingerprint）。
    """
    batch = payload.get("batch", [])
    if not isinstance(batch, list) or not batch:
        return {"status": "ok", "accepted": 0, "skipped": 0, "note": "empty batch"}

    os.makedirs(RAW_DIR, exist_ok=True)
    accepted = 0
    skipped = 0
    by_day: dict[str, list] = {}

    for item in batch:
        if not isinstance(item, dict):
            skipped += 1
            continue
        start = item.get("startDate", "")
        day = start[:10] if start else datetime.now().strftime("%Y-%m-%d")
        fp = item.get("fingerprint") or f"{item.get('type')}|{start}"
        item["_fingerprint"] = fp
        by_day.setdefault(day, []).append(item)
        accepted += 1

    for day, items in by_day.items():
        day_path = os.path.join(RAW_DIR, f"{day}.json")
        existing = []
        if os.path.exists(day_path):
            try:
                with open(day_path, "r", encoding="utf-8") as f:
                    existing = json.load(f)
            except Exception:
                existing = []
        seen = {x.get("_fingerprint") for x in existing if isinstance(x, dict)}
        merged = list(existing)
        added = 0
        for item in items:
            if item["_fingerprint"] in seen:
                continue
            seen.add(item["_fingerprint"])
            merged.append(item)
            added += 1
        with open(day_path, "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=1)
        accepted -= (len(items) - added)
        skipped += (len(items) - added)

    # 轻量触发看板刷新（后台，不阻塞响应）
    try:
        import threading
        threading.Thread(target=_refresh_dashboard, daemon=True).start()
    except Exception:
        pass

    return {"status": "ok", "accepted": accepted, "skipped": skipped,
            "days": sorted(by_day.keys())}


# 看板刷新互斥锁（2026-08-25 修复：防止高频推送导致多进程堆积内存爆炸）
_dashboard_lock = threading.Lock()
_dashboard_running = threading.Event()

def _refresh_dashboard():
    """后台刷新 Health vault 看板（若生成脚本存在）。
    互斥：同一时间只允许一个刷新在跑；正在刷新时新触发直接跳过。
    """
    import subprocess
    if _dashboard_running.is_set():
        # 已有刷新在跑，跳过本次（避免堆积）
        return
    if not _dashboard_lock.acquire(blocking=False):
        return
    _dashboard_running.set()
    script = os.environ.get("DASHBOARD_SCRIPT", "")
    try:
        if os.path.exists(script):
            try:
                subprocess.run(["/usr/bin/python3", script],
                               timeout=180, capture_output=True)
            except Exception:
                pass
    finally:
        _dashboard_running.clear()
        _dashboard_lock.release()


@app.get("/")
def root():
    return {"status": "ok", "service": "Health API for Hermes", "version": "2.0"}


@app.post("/api/health")
async def receive_health(data: dict, _=Depends(verify_token)):
    """接收快捷指令推送的健康数据，写入 Obsidian"""
    date = data.get("date", datetime.now().strftime("%Y-%m-%d"))
    now = datetime.now().strftime("%H:%M")

    os.makedirs(HEALTH_DIR, exist_ok=True)
    os.makedirs(SLEEP_DIR, exist_ok=True)
    os.makedirs(BODY_DIR, exist_ok=True)

    # --- 写入健康数据 ---
    health_path = f"{HEALTH_DIR}/health_{date}.md"
    health_lines = [
        f"# 健康数据 {date}",
        f"> 来源: Apple Health Shortcuts | 时间: {now}",
        "",
        "| 指标 | 数值 |",
        "|------|------|",
        f"| 睡眠时长 | {data.get('sleep_hours', 'N/A')} h |",
        f"| 深睡 | {data.get('deep_hours', 'N/A')} h |",
        f"| 核心睡眠 | {data.get('core_hours', 'N/A')} h |",
        f"| REM | {data.get('rem_hours', 'N/A')} h |",
        f"| 静息心率 | {data.get('resting_hr', 'N/A')} bpm |",
        f"| HRV | {data.get('hrv', 'N/A')} ms |",
        f"| 步数 | {data.get('steps', 'N/A')} |",
        f"| 活动消耗 | {data.get('active_energy', 'N/A')} kcal |",
        f"| 体重 (iOS) | {data.get('body_weight', 'N/A')} kg |",
        "",
    ]
    with open(health_path, "w") as f:
        f.write("\n".join(health_lines) + "\n")

    # --- 写入睡眠数据 ---
    if data.get("sleep_hours"):
        sleep_path = f"{SLEEP_DIR}/sleep_{date}.md"
        sleep_lines = [
            f"# 睡眠记录 {date}",
            f"> 来源: Apple Health Shortcuts | 时间: {now}",
            "",
            "| 指标 | 数值 |",
            "|------|------|",
            f"| 总睡眠 | {data.get('sleep_hours', 'N/A')} h |",
            f"| 深睡 | {data.get('deep_hours', 'N/A')} h |",
            f"| 核心睡眠 | {data.get('core_hours', 'N/A')} h |",
            f"| REM | {data.get('rem_hours', 'N/A')} h |",
            f"| 入睡时间 | {data.get('bedtime', 'N/A')} |",
            f"| 起床时间 | {data.get('wake_time', 'N/A')} |",
            "",
        ]
        with open(sleep_path, "w") as f:
            f.write("\n".join(sleep_lines) + "\n")

    # --- 写入体重数据（如果有） ---
    if data.get("body_weight"):
        body_path = f"{BODY_DIR}/body_{date}.md"
        body_lines = [
            f"# 身体数据 {date}",
            f"> 来源: Apple Health Shortcuts | 时间: {now}",
            "",
            "| 指标 | 数值 |",
            "|------|------|",
            f"| 体重 | {data['body_weight']} kg |",
            "",
        ]
        with open(body_path, "w") as f:
            f.write("\n".join(body_lines) + "\n")

    return {"status": "ok", "date": date, "files": {"health": health_path, "sleep": data.get("sleep_hours") and sleep_path or None}}


@app.get("/api/health/latest")
def get_latest(_=Depends(verify_token)):
    """获取最新一条健康数据"""
    if not os.path.exists(HEALTH_DIR):
        return {"status": "empty"}
    files = sorted([f for f in os.listdir(HEALTH_DIR) if f.startswith("health_20") and f.endswith(".md")])
    if not files:
        return {"status": "empty"}
    latest = files[-1]
    with open(f"{HEALTH_DIR}/{latest}") as f:
        content = f.read()
    return {"status": "ok", "file": latest, "content": content}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8765)