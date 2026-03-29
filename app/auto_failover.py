"""
auto_failover.py — Background thread: detect → switch → auto-failback.

States:  HEALTHY → DEGRADED → FAILING_OVER → SECONDARY → RECOVERING → HEALTHY
3-strike threshold prevents transient blips from triggering failover.
"""
import threading
import time
import logging
from datetime import datetime, timezone

import pymysql

logger = logging.getLogger("dr.failover")


class DRState:
    HEALTHY = "HEALTHY"
    DEGRADED = "DEGRADED"
    FAILING_OVER = "FAILING_OVER"
    SECONDARY = "SECONDARY"
    RECOVERING = "RECOVERING"


class AutoFailoverManager:
    """Monitors primary DB health and switches the active database automatically."""

    def __init__(self, app=None):
        self.app = app
        self.state = DRState.HEALTHY
        self.active_db = "primary"
        self.consecutive_failures = 0
        self.consecutive_recoveries = 0
        self.failure_threshold = 3
        self.recovery_threshold = 3
        self.check_interval = 10
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._events = []             # in-memory event log (also persisted to DB)
        self.simulated_fault = False  # If True, _check_primary returns False

        if app is not None:
            self.init_app(app)

    def init_app(self, app):
        self.app = app
        self.active_db = app.config.get("ACTIVE_DB", "primary")
        self.failure_threshold = app.config.get("FAILURE_THRESHOLD", 3)
        self.check_interval = app.config.get("HEALTH_CHECK_INTERVAL", 10)
        self.recovery_threshold = app.config.get("RECOVERY_THRESHOLD", 3)
        app.extensions["failover"] = self

    # ── Public API ────────────────────────────────────────────────────────
    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True, name="healsync-failover")
        self._thread.start()
        logger.info("Auto-failover monitor started (interval=%ds, threshold=%d)",
                     self.check_interval, self.failure_threshold)

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def manual_failover(self):
        """Trigger immediate failover regardless of health."""
        with self._lock:
            if self.active_db == "secondary":
                return {"ok": False, "reason": "Already on secondary"}
            self._do_failover("manual trigger")
            return {"ok": True, "state": self.state, "active_db": self.active_db}

    def manual_failback(self):
        """Trigger immediate failback to primary."""
        with self._lock:
            if self.active_db == "primary":
                return {"ok": False, "reason": "Already on primary"}
            if not self._check_primary():
                return {"ok": False, "reason": "Primary is not healthy"}
            self._do_failback("manual trigger")
            self.simulated_fault = False  # Reset fault if manual failback is called
            return {"ok": True, "state": self.state, "active_db": self.active_db}

    def trigger_fault(self):
        """Trigger a simulated fault on the primary DB."""
        with self._lock:
            logger.warning("!!! SIMULATING PRIMARY FAULT !!!")
            self.simulated_fault = True

    def clear_fault(self):
        """Clear the simulated fault."""
        with self._lock:
            logger.info("!!! CLEARING SIMULATED PRIMARY FAULT !!!")
            self.simulated_fault = False


    def get_status(self):
        primary_ok = self._check_primary()
        secondary_ok = self._check_secondary()
        return {
            "state": self.state,
            "active_db": self.active_db,
            "primary_healthy": primary_ok,
            "secondary_healthy": secondary_ok,
            "consecutive_failures": self.consecutive_failures,
            "cluster_role": self.app.config.get("CLUSTER_ROLE", "unknown") if self.app else "unknown",
            "cluster_region": self.app.config.get("CLUSTER_REGION", "unknown") if self.app else "unknown",
        }

    def get_replication_status(self):
        """Read replication health from secondary MySQL (best-effort)."""
        if self.app and self.app.config.get("TESTING"):
            return {
                "available": True,
                "io_running": True,
                "sql_running": True,
                "seconds_behind_source": 0,
                "healthy": True,
                "details": "testing mode",
            }

        rows = self._query_secondary("SHOW REPLICA STATUS")
        if rows is None:
            rows = self._query_secondary("SHOW SLAVE STATUS")
        if not rows:
            return {
                "available": False,
                "healthy": False,
                "details": "replication status unavailable on secondary",
            }

        row = rows[0]
        io_running = row.get("Replica_IO_Running") or row.get("Slave_IO_Running")
        sql_running = row.get("Replica_SQL_Running") or row.get("Slave_SQL_Running")
        lag = row.get("Seconds_Behind_Source")
        if lag is None:
            lag = row.get("Seconds_Behind_Master")
        healthy = str(io_running).lower() == "yes" and str(sql_running).lower() == "yes"
        return {
            "available": True,
            "io_running": io_running,
            "sql_running": sql_running,
            "seconds_behind_source": lag,
            "healthy": healthy,
        }

    def wait_for_todo_replication(self, todo_id, timeout_seconds=5, poll_interval_seconds=0.2):
        """Wait until a newly written todo is visible on the secondary DB."""
        forced = None
        if self.app:
            forced = self.app.config.get("TEST_FORCE_REPLICATION_RESULT")
        if forced is not None:
            return bool(forced)
        if self.app and self.app.config.get("TESTING"):
            return True
        deadline = time.time() + max(0.0, timeout_seconds)
        interval = max(0.05, poll_interval_seconds)
        while time.time() < deadline:
            if self.todo_exists_on_secondary(todo_id):
                return True
            time.sleep(interval)
        return self.todo_exists_on_secondary(todo_id)

    def todo_exists_on_secondary(self, todo_id):
        forced = None
        if self.app:
            forced = self.app.config.get("TEST_FORCE_REPLICATION_RESULT")
        if forced is not None:
            return bool(forced)
        if self.app and self.app.config.get("TESTING"):
            return True
        rows = self._query_secondary(
            "SELECT id FROM todos WHERE id=%s LIMIT 1",
            (int(todo_id),),
        )
        return bool(rows)

    def get_events(self):
        return list(reversed(self._events[-50:]))

    # ── Background loop ───────────────────────────────────────────────────
    def _run(self):
        while not self._stop.is_set():
            try:
                self._tick()
            except Exception as e:
                logger.exception("Failover tick error: %s", e)
            self._stop.wait(self.check_interval)

    def _tick(self):
        with self._lock:
            primary_ok = self._check_primary()

            if self.active_db == "primary":
                if primary_ok:
                    self.consecutive_failures = 0
                    if self.state != DRState.HEALTHY:
                        self.state = DRState.HEALTHY
                        self._log_event("RECOVERED", "primary", "primary", "Primary recovered")
                else:
                    self.consecutive_failures += 1
                    logger.warning("Primary check failed (%d/%d)",
                                   self.consecutive_failures, self.failure_threshold)
                    if self.consecutive_failures >= self.failure_threshold:
                        self._do_failover(f"Primary unreachable ({self.consecutive_failures} failures)")
                    else:
                        self.state = DRState.DEGRADED
                        self._log_event("DEGRADED", "primary", None,
                                        f"Strike {self.consecutive_failures}/{self.failure_threshold}")

            elif self.active_db == "secondary":
                # Watch for primary recovery → auto-failback
                if primary_ok:
                    self.consecutive_recoveries += 1
                    if self.consecutive_recoveries >= self.recovery_threshold:
                        self.state = DRState.RECOVERING
                        self._do_failback("Primary recovered (auto-failback)")
                else:
                    self.consecutive_recoveries = 0

    # ── Failover / failback actions ───────────────────────────────────────
    def _do_failover(self, reason):
        self.state = DRState.FAILING_OVER
        logger.critical("⚠ FAILOVER: %s", reason)
        self._log_event("FAILOVER", "primary", "secondary", reason)

        # Switch active DB
        self.active_db = "secondary"
        if self.app:
            self.app.config["ACTIVE_DB"] = "secondary"
            self._switch_sqlalchemy("secondary")

        self.state = DRState.SECONDARY
        self.consecutive_failures = 0
        self.consecutive_recoveries = 0
        logger.info("Now running on SECONDARY database")

    def _do_failback(self, reason):
        logger.info("⟲ FAILBACK: %s", reason)
        self._log_event("FAILBACK", "secondary", "primary", reason)

        self.active_db = "primary"
        if self.app:
            self.app.config["ACTIVE_DB"] = "primary"
            self._switch_sqlalchemy("primary")

        self.state = DRState.HEALTHY
        self.consecutive_failures = 0
        self.consecutive_recoveries = 0
        logger.info("Restored to PRIMARY database")

    # ── DB health probes ──────────────────────────────────────────────────
    def _check_primary(self):
        if self.app and self.app.config.get("TESTING"):
            return True
        if self.simulated_fault:
            return False
        return self._ping(
            self.app.config["PRIMARY_DB_HOST"],
            self.app.config["PRIMARY_DB_PORT"],
            self.app.config["PRIMARY_DB_USER"],
            self.app.config["PRIMARY_DB_PASS"],
        ) if self.app else False

    def _check_secondary(self):
        if self.app and self.app.config.get("TESTING"):
            return True
        return self._ping(
            self.app.config["SECONDARY_DB_HOST"],
            self.app.config["SECONDARY_DB_PORT"],
            self.app.config["SECONDARY_DB_USER"],
            self.app.config["SECONDARY_DB_PASS"],
        ) if self.app else False

    def _query_secondary(self, query, args=None):
        if not self.app:
            return None
        conn = None
        try:
            conn = pymysql.connect(
                host=self.app.config["SECONDARY_DB_HOST"],
                port=int(self.app.config["SECONDARY_DB_PORT"]),
                user=self.app.config["SECONDARY_DB_USER"],
                password=self.app.config["SECONDARY_DB_PASS"],
                database=self.app.config.get("SECONDARY_DB_NAME"),
                connect_timeout=3,
                cursorclass=pymysql.cursors.DictCursor,
                autocommit=True,
            )
            with conn.cursor() as cur:
                cur.execute(query, args or ())
                return cur.fetchall()
        except Exception as e:
            logger.warning("Secondary query failed: %s", e)
            return None
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    @staticmethod
    def _ping(host, port, user, password):
        try:
            conn = pymysql.connect(host=host, port=int(port), user=user,
                                   password=password, connect_timeout=3)
            conn.ping(reconnect=False)
            conn.close()
            return True
        except Exception:
            return False

    # ── SQLAlchemy URI switch ─────────────────────────────────────────────
    def _switch_sqlalchemy(self, target):
        """Update the SQLAlchemy engine URI to point at the new active DB."""
        if target == "secondary":
            uri = (
                f"mysql+pymysql://{self.app.config['SECONDARY_DB_USER']}:"
                f"{self.app.config['SECONDARY_DB_PASS']}@"
                f"{self.app.config['SECONDARY_DB_HOST']}:"
                f"{self.app.config['SECONDARY_DB_PORT']}/"
                f"{self.app.config['SECONDARY_DB_NAME']}?charset=utf8mb4"
            )
        else:
            uri = (
                f"mysql+pymysql://{self.app.config['PRIMARY_DB_USER']}:"
                f"{self.app.config['PRIMARY_DB_PASS']}@"
                f"{self.app.config['PRIMARY_DB_HOST']}:"
                f"{self.app.config['PRIMARY_DB_PORT']}/"
                f"{self.app.config['PRIMARY_DB_NAME']}?charset=utf8mb4"
            )
        self.app.config["SQLALCHEMY_DATABASE_URI"] = uri
        # Existing connections are bound to the previous URI, so dispose now.
        from models import db
        with self.app.app_context():
            db.engine.dispose()

    # ── Event helpers ─────────────────────────────────────────────────────
    def _log_event(self, event_type, from_db, to_db, details):
        evt = {
            "timestamp": datetime.now(timezone.utc).isoformat() + "Z",
            "event_type": event_type,
            "from_db": from_db,
            "to_db": to_db,
            "details": details,
        }
        self._events.append(evt)
        if self.app:
            limit = int(self.app.config.get("EVENT_LOG_LIMIT", 500))
            if len(self._events) > limit:
                self._events = self._events[-limit:]
        logger.info("HealSync Event: %s", evt)

        # Persist to database (best-effort)
        try:
            if self.app:
                with self.app.app_context():
                    from models import db, DREvent
                    record = DREvent(event_type=event_type, from_db=from_db,
                                     to_db=to_db, details=details)
                    db.session.add(record)
                    db.session.commit()
        except Exception as e:
            logger.warning("Could not persist HealSync event: %s", e)
