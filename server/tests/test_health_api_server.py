import json
import os
import tempfile
import uuid
from pathlib import Path

from fastapi.testclient import TestClient

os.environ["OBSIDIAN_VAULT"] = tempfile.mkdtemp(prefix="healthsync-tests-")
os.environ["HEALTH_API_TOKEN"] = "test-token"
os.environ["HEALTH_TIMEZONE"] = "UTC"

import health_api_server as server


client = TestClient(server.app)
AUTH = {"Authorization": "Bearer test-token"}


def sample_payload(sample_id=None, fingerprint="fingerprint", start="2026-10-30T12:00:00Z"):
    return {
        "device": {"model": "test", "os": "test", "app": "HealthSync/tests"},
        "batch": [{
            "id": sample_id or str(uuid.uuid4()),
            "type": "HKQuantityTypeIdentifierStepCount",
            "category": "activity",
            "startDate": start,
            "endDate": start,
            "value": 1234,
            "unit": "count",
            "sourceName": "Apple Watch",
            "sourceBundleID": "com.apple.health",
            "deviceName": "iPhone",
            "fingerprint": fingerprint,
        }],
        "fullSync": False,
    }


def test_health_check_reports_timezone():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["timezone"] == "UTC"


def test_authentication_is_required():
    response = client.post("/api/ingest", json=sample_payload())
    assert response.status_code == 401


def test_invalid_sample_is_rejected():
    payload = sample_payload(start="2026-10-30T12:00:00")
    response = client.post("/api/ingest", json=payload, headers=AUTH)
    assert response.status_code == 422

    payload = sample_payload(start="2026-10-30T12:00:00Z")
    payload["batch"][0]["endDate"] = "2026-10-30T11:00:00Z"
    response = client.post("/api/ingest", json=payload, headers=AUTH)
    assert response.status_code == 422


def test_ingest_deduplicates_slim_records():
    sample_id = str(uuid.uuid4())
    first = client.post(
        "/api/ingest",
        json=sample_payload(sample_id=sample_id, fingerprint="first"),
        headers=AUTH,
    )
    assert first.status_code == 200
    assert first.json()["accepted"] == 1

    duplicate = client.post(
        "/api/ingest",
        json=sample_payload(sample_id=sample_id, fingerprint="changed"),
        headers=AUTH,
    )
    assert duplicate.status_code == 200
    assert duplicate.json()["accepted"] == 0
    assert duplicate.json()["skipped"] == 1

    output = Path(os.environ["OBSIDIAN_VAULT"]) / "data/raw/2026-10-30.json"
    records = json.loads(output.read_text(encoding="utf-8"))
    record = next(
        item for item in records
        if item["type"] == "HKQuantityTypeIdentifierStepCount"
        and item["startDate"].startswith("2026-10-30T12:00:00")
    )
    assert set(record) == {
        "type", "category", "startDate", "endDate",
        "value", "unit", "sourceName",
    }
    assert "id" not in record
    assert "fingerprint" not in record
    assert "sourceBundleID" not in record


def test_ecg_waveform_payload_is_preserved():
    sample_id = str(uuid.uuid4())
    payload = sample_payload(sample_id=sample_id, fingerprint="ecg")
    payload["batch"][0].update({
        "type": "HKElectrocardiogramType",
        "category": "heart",
        "ecgVoltageMeasurements": [{
            "timeSinceSampleStart": 0.1,
            "voltageMicrovolts": 12.5,
            "lead": "appleWatchSimilarToLeadI",
        }],
    })
    response = client.post("/api/ingest", json=payload, headers=AUTH)
    assert response.status_code == 200
    output = Path(os.environ["OBSIDIAN_VAULT"]) / "data/raw/2026-10-30.json"
    records = json.loads(output.read_text(encoding="utf-8"))
    record = next(item for item in records if item["type"] == "HKElectrocardiogramType")
    assert record["ecgVoltageMeasurements"][0]["voltageMicrovolts"] == 12.5


def test_legacy_daily_files_are_migrated_and_backed_up():
    raw_dir = Path(os.environ["OBSIDIAN_VAULT"]) / "data/raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    legacy_path = raw_dir / "2026-11-01.json"
    legacy_path.write_text(json.dumps([{
        "id": str(uuid.uuid4()),
        "type": "HKQuantityTypeIdentifierHeartRate",
        "category": "heart",
        "startDate": "2026-11-01T12:00:00Z",
        "endDate": "2026-11-01T12:00:00Z",
        "value": 68,
        "unit": "count/min",
        "sourceName": "Apple Watch",
        "sourceBundleID": "com.apple.health",
        "deviceName": "Watch",
        "fingerprint": "legacy",
        "_fingerprint": "legacy",
    }]), encoding="utf-8")

    server._migrate_existing_raw_files()
    migrated = json.loads(legacy_path.read_text(encoding="utf-8"))
    assert migrated == [{
        "type": "HKQuantityTypeIdentifierHeartRate",
        "category": "heart",
        "startDate": "2026-11-01T12:00:00Z",
        "endDate": "2026-11-01T12:00:00Z",
        "value": 68,
        "unit": "count/min",
        "sourceName": "Apple Watch",
    }]
    backups = list(
        (Path(os.environ["OBSIDIAN_VAULT"]) / "data/.backups").glob(
            "raw-pre-optimized-*/2026-11-01.json"
        )
    )
    assert backups


def test_corrupt_file_is_backed_up():
    raw_dir = Path(os.environ["OBSIDIAN_VAULT"]) / "data/raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    day_file = raw_dir / "2026-10-31.json"
    day_file.write_text("{broken", encoding="utf-8")

    response = client.post(
        "/api/ingest",
        json=sample_payload(start="2026-10-31T12:00:00Z"),
        headers=AUTH,
    )
    assert response.status_code == 200
    assert any("corrupt-" in path.name for path in raw_dir.iterdir())
    assert len(json.loads(day_file.read_text(encoding="utf-8"))) == 1


def test_cors_is_not_wildcard_by_default():
    response = client.options(
        "/api/ingest",
        headers={
            "Origin": "https://example.com",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert "access-control-allow-origin" not in response.headers
