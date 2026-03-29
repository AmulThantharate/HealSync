"""
tests/test_app.py — pytest tests using SQLite (no MySQL needed).
"""
import os
import sys
import pytest

# Ensure app/ is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config import TestConfig
from app import create_app
from models import db as _db


@pytest.fixture
def app():
    """Create a test Flask app with SQLite in-memory DB."""
    application = create_app(config=TestConfig)
    yield application


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def db(app):
    with app.app_context():
        _db.create_all()
        yield _db
        _db.session.remove()


# ── Health ────────────────────────────────────────────────────────────────
class TestHealth:
    def test_health_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["status"] == "ok"
        assert "state" in data

    def test_health_contains_state(self, client):
        data = client.get("/health").get_json()
        assert data["state"] in ("HEALTHY", "DEGRADED", "FAILING_OVER", "SECONDARY", "RECOVERING")

    def test_live_returns_200(self, client):
        resp = client.get("/live")
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "alive"

    def test_ready_returns_200(self, client):
        resp = client.get("/ready")
        assert resp.status_code == 200
        assert resp.get_json()["status"] in ("ready", "not_ready")


# ── Status ────────────────────────────────────────────────────────────────
class TestStatus:
    def test_status_returns_json(self, client):
        resp = client.get("/api/status")
        assert resp.status_code == 200
        data = resp.get_json()
        assert "state" in data
        assert "active_db" in data
        assert "primary_healthy" in data
        assert "secondary_healthy" in data
        assert "consecutive_failures" in data

    def test_initial_state_is_healthy(self, client):
        data = client.get("/api/status").get_json()
        assert data["state"] == "HEALTHY"
        assert data["active_db"] == "primary"

    def test_replication_status_returns_json(self, client):
        resp = client.get("/api/replication")
        assert resp.status_code == 200
        data = resp.get_json()
        assert "healthy" in data
        assert "available" in data


# ── Manual Failover / Failback ────────────────────────────────────────────
class TestFailover:
    def test_manual_failover(self, client):
        resp = client.post("/api/failover")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["ok"] is True
        assert data["active_db"] == "secondary"

    def test_double_failover_returns_409(self, client):
        client.post("/api/failover")
        resp = client.post("/api/failover")
        assert resp.status_code == 409
        data = resp.get_json()
        assert data["ok"] is False

    def test_failback_when_already_primary_returns_409(self, client):
        resp = client.post("/api/failback")
        assert resp.status_code == 409
        data = resp.get_json()
        assert data["ok"] is False


# ── Events ────────────────────────────────────────────────────────────────
class TestEvents:
    def test_events_initially_empty(self, client):
        resp = client.get("/api/events")
        assert resp.status_code == 200
        assert resp.get_json() == []

    def test_events_after_failover(self, client):
        client.post("/api/failover")
        resp = client.get("/api/events")
        events = resp.get_json()
        assert len(events) >= 1
        assert any(e["event_type"] == "FAILOVER" for e in events)


# ── Dashboard ─────────────────────────────────────────────────────────────
class TestDashboard:
    def test_dashboard_loads(self, client):
        resp = client.get("/")
        assert resp.status_code == 200
        assert b"HealSync Dashboard" in resp.data


# ── Data write ────────────────────────────────────────────────────────────
class TestDataWrite:
    def test_write_and_list(self, client, db):
        # Write
        resp = client.post("/api/data",
                           json={"key": "hello", "value": "world"})
        assert resp.status_code == 201
        data = resp.get_json()
        assert data["key"] == "hello"
        assert data["written_to"] == "primary"

        # List
        resp = client.get("/api/data")
        assert resp.status_code == 200
        rows = resp.get_json()
        assert any(r["key"] == "hello" for r in rows)


class TestTodos:
    def test_create_todo_validates_required_task(self, client):
        resp = client.post("/api/todos", json={"task": ""})
        assert resp.status_code == 400
        assert "error" in resp.get_json()

    def test_create_todo_includes_replication_flag(self, client):
        resp = client.post("/api/todos", json={"task": "replication check"})
        assert resp.status_code == 201
        data = resp.get_json()
        assert "replicated_to_secondary" in data

    def test_strict_replication_ack_returns_503_when_not_confirmed(self, client, app):
        app.config["REPLICATION_STRICT_ACK"] = True
        app.config["WAIT_FOR_REPLICATION"] = True
        app.config["TEST_FORCE_REPLICATION_RESULT"] = False
        resp = client.post("/api/todos", json={"task": "strict mode"})
        assert resp.status_code == 503
        data = resp.get_json()
        assert data["replicated_to_secondary"] is False
        assert data["error"] == "replication acknowledgment timeout"
