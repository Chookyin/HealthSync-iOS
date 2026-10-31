"""
健康数据 API 服务 v2.0
接收 iPhone 快捷指令推送的 Apple Health 数据，写入 Obsidian Vault

启动: uvicorn health_api_server:app --host 0.0.0.0 --port 8765
Auth: 环境变量 HEALTH_API_TOKEN（必填，未设置时拒绝启动）
"""

from fastapi import FastAPI, Header, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
import fcntl
import json
import math
import os
import secrets
import tempfile
import threading
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

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

VALID_TOKEN = os.environ.get("HEALTH_API_TOKEN", "").strip()
if not VALID_TOKEN:
    print("ERROR: HEALTH_API_TOKEN must be set", flush=True)
    raise SystemExit(1)

try:
    HEALTH_TIMEZONE = ZoneInfo(os.environ.get("HEALTH_TIMEZONE", "UTC"))
except ZoneInfoNotFoundError:
    print("ERROR: invalid HEALTH_TIMEZONE", flush=True)
    raise SystemExit(1)

CORS_ORIGINS = [
    origin.strip()
    for origin in os.environ.get("HEALTH_CORS_ORIGINS", "").split(",")
    if origin.strip()
]


class DevicePayload(BaseModel):
    model_config = ConfigDict(extra="allow")

    model: str = Field(default="", max_length=256)
    os: str = Field(default="", max_length=128)
    app: str = Field(default="", max_length=256)


class RangePayload(BaseModel):
    start: datetime
    end: datetime

    @field_validator("start", "end")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("range dates must include a timezone")
        return value

    @model_validator(mode="after")
    def validate_date_range(self):
        if self.end < self.start:
            raise ValueError("range end must not be earlier than start")
        return self


class ECGVoltagePayload(BaseModel):
    timeSinceSampleStart: float
    voltageMicrovolts: float
    lead: str = Field(min_length=1, max_length=128)

    @field_validator("timeSinceSampleStart", "voltageMicrovolts")
    @classmethod
    def validate_finite_values(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("ECG voltage values must be finite")
        return value


class HealthSamplePayload(BaseModel):
    model_config = ConfigDict(extra="allow")

    id: str = Field(min_length=1, max_length=256)
    type: str = Field(min_length=1, max_length=256)
    category: str = Field(default="unknown", max_length=128)
    startDate: datetime
    endDate: datetime
    value: Optional[float] = None
    unit: Optional[str] = Field(default=None, max_length=128)
    valueDescription: Optional[str] = Field(default=None, max_length=4096)
    sourceName: Optional[str] = Field(default=None, max_length=512)
    sourceBundleID: Optional[str] = Field(default=None, max_length=512)
    deviceName: Optional[str] = Field(default=None, max_length=512)
    metadata: Optional[Dict[str, str]] = None
    ecgVoltageMeasurements: Optional[List[ECGVoltagePayload]] = Field(
        default=None,
        max_length=50_000,
    )
    fingerprint: str = Field(min_length=1, max_length=512)

    @field_validator("startDate", "endDate")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("HealthKit dates must include a timezone")
        return value

    @field_validator("value")
    @classmethod
    def validate_finite_value(cls, value: Optional[float]) -> Optional[float]:
        if value is not None and not math.isfinite(value):
            raise ValueError("value must be finite")
        return value

    @model_validator(mode="after")
    def validate_date_range(self):
        if self.endDate < self.startDate:
            raise ValueError("endDate must not be earlier than startDate")
        return self


class IngestPayload(BaseModel):
    model_config = ConfigDict(extra="allow")

    device: Optional[DevicePayload] = None
    batch: List[HealthSamplePayload] = Field(default_factory=list, max_length=5000)
    range: Optional[RangePayload] = None
    cursorFingerprint: Optional[str] = Field(default=None, max_length=512)
    fullSync: bool = False

app = FastAPI(title="Health API", version="2.0")

if CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=CORS_ORIGINS,
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type"],
    )


def verify_token(authorization: Optional[str] = Header(None)):
    expected = f"Bearer {VALID_TOKEN}"
    if not authorization or not secrets.compare_digest(authorization, expected):
        raise HTTPException(status_code=401, detail="Unauthorized")


_raw_write_lock = threading.Lock()


def _backup_corrupt_file(path: str) -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = f"{path}.corrupt-{stamp}"
    os.replace(path, backup)


def _load_daily_samples(path: str) -> List[Dict[str, Any]]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, list):
            raise ValueError("daily JSON root must be a list")
        if any(not isinstance(item, dict) for item in data):
            raise ValueError("daily JSON items must be objects")
        return data
    except OSError:
        raise
    except (ValueError, json.JSONDecodeError):
        _backup_corrupt_file(path)
        return []


def _atomic_write_json(path: str, data: List[Dict[str, Any]]) -> None:
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(
        dir=directory,
        prefix=f".{os.path.basename(path)}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=1, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _merge_daily_samples(path: str,
                         items: List[Dict[str, Any]]) -> int:
    lock_path = os.path.join(RAW_DIR, ".ingest.lock")
    with _raw_write_lock:
        with open(lock_path, "a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                existing = _load_daily_samples(path)
                seen = {
                    item.get("_fingerprint")
                    for item in existing
                    if item.get("_fingerprint")
                }
                # 旧版客户端指纹在进程间不稳定；UUID 是同一 HealthKit 样本的稳定标识。
                seen_ids = {
                    item.get("id")
                    for item in existing
                    if item.get("id")
                }
                merged = list(existing)
                added = 0
                for item in items:
                    item_id = item.get("id")
                    if (item["_fingerprint"] in seen
                            or (item_id and item_id in seen_ids)):
                        continue
                    seen.add(item["_fingerprint"])
                    if item_id:
                        seen_ids.add(item_id)
                    merged.append(item)
                    added += 1
                if added:
                    _atomic_write_json(path, merged)
                return added
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def _safe_markdown_date(value: Any) -> str:
    candidate = str(value or "")
    try:
        return datetime.strptime(candidate, "%Y-%m-%d").strftime("%Y-%m-%d")
    except ValueError:
        return datetime.now(HEALTH_TIMEZONE).strftime("%Y-%m-%d")


@app.post("/api/ingest")
async def ingest_health(payload: IngestPayload, _=Depends(verify_token)):
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
    batch = payload.batch
    if not batch:
        return {"status": "ok", "accepted": 0, "skipped": 0, "note": "empty batch"}

    os.makedirs(RAW_DIR, exist_ok=True)
    accepted = 0
    skipped = 0
    by_day: dict[str, list] = {}

    for sample in batch:
        item = sample.model_dump(mode="json", exclude_none=True)
        day = sample.startDate.astimezone(HEALTH_TIMEZONE).strftime("%Y-%m-%d")
        item["_fingerprint"] = sample.fingerprint
        by_day.setdefault(day, []).append(item)
        accepted += 1

    for day, items in by_day.items():
        day_path = os.path.join(RAW_DIR, f"{day}.json")
        added = _merge_daily_samples(day_path, items)
        accepted -= len(items) - added
        skipped += len(items) - added

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
    return {
        "status": "ok",
        "service": "Health API for Hermes",
        "version": "2.0",
        "timezone": str(HEALTH_TIMEZONE),
    }


@app.post("/api/health")
async def receive_health(data: dict, _=Depends(verify_token)):
    """接收快捷指令推送的健康数据，写入 Obsidian"""
    date = _safe_markdown_date(data.get("date"))
    now = datetime.now(HEALTH_TIMEZONE).strftime("%H:%M")

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
