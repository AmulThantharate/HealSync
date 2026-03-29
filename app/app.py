"""
app.py — Flask HealSync dashboard with all routes.
Run: flask run  (dev)  or  gunicorn --factory app:create_app  (prod)
"""
import os
import sys
import logging
import atexit
from datetime import datetime, timezone

from flask import Flask, render_template, jsonify, request, current_app
from werkzeug.exceptions import BadRequest, HTTPException

# Ensure app directory is on sys.path
sys.path.insert(0, os.path.dirname(__file__))

from config import Config
from models import db, TestData, Todo
from auto_failover import AutoFailoverManager

# ── Logging ───────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("dr.app")


def _failover():
    return current_app.extensions["failover"]


def create_app(config=None):
    """Flask application factory."""
    app = Flask(__name__, template_folder="templates")

    # Load config
    if config:
        app.config.from_object(config)
    else:
        app.config.from_object(Config)

    # Set SQLAlchemy URI based on active DB
    if not app.config.get("SQLALCHEMY_DATABASE_URI"):
        if app.config.get("ACTIVE_DB") == "secondary":
            app.config["SQLALCHEMY_DATABASE_URI"] = (
                f"mysql+pymysql://{app.config['SECONDARY_DB_USER']}:{app.config['SECONDARY_DB_PASS']}"
                f"@{app.config['SECONDARY_DB_HOST']}:{app.config['SECONDARY_DB_PORT']}"
                f"/{app.config['SECONDARY_DB_NAME']}?charset=utf8mb4"
            )
        else:
            app.config["SQLALCHEMY_DATABASE_URI"] = (
                f"mysql+pymysql://{app.config['PRIMARY_DB_USER']}:{app.config['PRIMARY_DB_PASS']}"
                f"@{app.config['PRIMARY_DB_HOST']}:{app.config['PRIMARY_DB_PORT']}"
                f"/{app.config['PRIMARY_DB_NAME']}?charset=utf8mb4"
            )

    # Init extensions
    db.init_app(app)
    failover_mgr = AutoFailoverManager(app)

    with app.app_context():
        db.create_all()

    if app.config.get("FLASK_ENV") == "production" and app.config.get("SECRET_KEY") == "dev-secret-change-me":
        logger.warning("SECRET_KEY is using a default development value in production.")

    @app.after_request
    def add_security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.teardown_appcontext
    def shutdown_session(exception=None):
        db.session.remove()

    @app.errorhandler(BadRequest)
    def bad_request(error):
        return jsonify({"error": "invalid request", "details": str(error)}), 400

    @app.errorhandler(Exception)
    def unhandled_error(error):
        if isinstance(error, HTTPException):
            return jsonify({"error": error.name.lower(), "details": error.description}), error.code
        logger.exception("Unhandled error: %s", error)
        return jsonify({"error": "internal server error"}), 500

    # Start auto-failover monitor (skip in tests & reloader subprocess)
    if (not app.config.get("TESTING")
            and app.config.get("FAILOVER_MONITOR_ENABLED", True)
            and app.config.get("HEALTH_CHECK_INTERVAL", 10) < 900
            and os.environ.get("WERKZEUG_RUN_MAIN") != "true"):
        failover_mgr.start()
        atexit.register(failover_mgr.stop)

    # ── Register routes ───────────────────────────────────────────────
    @app.route("/")
    def dashboard():
        return render_template("index.html")

    @app.route("/health")
    def health():
        """Backward-compatible health endpoint."""
        status = _failover().get_status()
        ok = status["state"] not in ("FAILING_OVER",)
        return jsonify({"status": "ok" if ok else "failing_over", **status}), 200 if ok else 503

    @app.route("/live")
    def live():
        """Liveness should only assert that process is serving traffic."""
        return jsonify({"status": "alive"}), 200

    @app.route("/ready")
    def ready():
        """Readiness verifies that the app can currently serve normally."""
        status = _failover().get_status()
        ok = status["state"] not in ("FAILING_OVER",)
        return jsonify({"status": "ready" if ok else "not_ready", **status}), 200 if ok else 503

    @app.route("/api/status")
    def api_status():
        return jsonify(_failover().get_status())

    @app.route("/api/replication")
    def api_replication():
        return jsonify(_failover().get_replication_status())

    @app.route("/api/failover", methods=["POST"])
    def api_failover():
        result = _failover().manual_failover()
        code = 200 if result["ok"] else 409
        return jsonify(result), code

    @app.route("/api/failback", methods=["POST"])
    def api_failback():
        result = _failover().manual_failback()
        code = 200 if result["ok"] else 409
        return jsonify(result), code

    @app.route("/api/events")
    def api_events():
        # Return in-memory events (always available, even if DB is down)
        return jsonify(_failover().get_events())

    @app.route("/api/todos", methods=["GET"])
    def api_todos_list():
        try:
            rows = Todo.query.order_by(Todo.created_at.desc()).limit(50).all()
            return jsonify([r.to_dict() for r in rows])
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/todos", methods=["POST"])
    def api_todos_write():
        body = request.get_json(silent=True) or {}
        task = (body.get("task") or "").strip()
        if not task:
            return jsonify({"error": "task is required"}), 400
        if len(task) > 255:
            return jsonify({"error": "task must be <= 255 chars"}), 400

        active_db = _failover().active_db

        try:
            row = Todo(task=task, written_to=active_db)
            db.session.add(row)
            db.session.commit()
            payload = row.to_dict()

            # If write happened on primary, optionally wait until row is visible on secondary.
            if active_db == "primary":
                if app.config.get("WAIT_FOR_REPLICATION", True):
                    replicated = _failover().wait_for_todo_replication(
                        row.id,
                        timeout_seconds=float(app.config.get("REPLICATION_WAIT_TIMEOUT_SECONDS", 5)),
                        poll_interval_seconds=float(app.config.get("REPLICATION_POLL_INTERVAL_SECONDS", 0.2)),
                    )
                else:
                    replicated = _failover().todo_exists_on_secondary(row.id)
                payload["replicated_to_secondary"] = replicated
            else:
                payload["replicated_to_secondary"] = None

            # NEW: Trigger fault after 4 todos in primary
            if active_db == "primary":
                count = Todo.query.filter_by(written_to="primary").count()
                if count >= 4:
                    logger.critical("!!! PRIMARY DB FAULT DETECTED AFTER 4 TODOS !!!")
                    _failover().trigger_fault()

            if (
                active_db == "primary"
                and app.config.get("REPLICATION_STRICT_ACK", False)
                and payload["replicated_to_secondary"] is False
            ):
                return jsonify({
                    "error": "replication acknowledgment timeout",
                    "details": "write committed on primary but not yet confirmed on secondary",
                    "todo_id": row.id,
                    "replicated_to_secondary": False,
                }), 503

            return jsonify(payload), 201
        except Exception as e:
            db.session.rollback()
            return jsonify({"error": str(e)}), 500

    @app.route("/api/data", methods=["GET"])
    def api_data_list():
        try:
            rows = TestData.query.order_by(TestData.created_at.desc()).limit(20).all()
            return jsonify([r.to_dict() for r in rows])
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    @app.route("/api/data", methods=["POST"])
    def api_data_write():
        body = request.get_json(silent=True) or {}
        key = (body.get("key") or f"test-{datetime.now(timezone.utc).strftime('%H%M%S')}").strip()
        value = str(body.get("value", "hello from HealSync app"))
        if len(key) > 100:
            return jsonify({"error": "key must be <= 100 chars"}), 400
        try:
            row = TestData(key=key, value=value, written_to=_failover().active_db)
            db.session.add(row)
            db.session.commit()
            return jsonify(row.to_dict()), 201
        except Exception as e:
            db.session.rollback()
            return jsonify({"error": str(e)}), 500

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5000, debug=app.config.get("DEBUG", False), use_reloader=False)
