"""
config.py — Database + app configuration from environment variables.
Matches docker-compose.yml env vars and k8s/flask/configmap.yaml.
"""
import os


def _bool_env(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-change-me")
    FLASK_ENV = os.environ.get("FLASK_ENV", "development")
    TESTING = False
    DEBUG = _bool_env("DEBUG", FLASK_ENV != "production")

    # ── Primary DB (AWS RDS / local MySQL) ────────────────────────────────
    PRIMARY_DB_HOST = os.environ.get("PRIMARY_DB_HOST", "localhost")
    PRIMARY_DB_PORT = int(os.environ.get("PRIMARY_DB_PORT", 3306))
    PRIMARY_DB_NAME = os.environ.get("PRIMARY_DB_NAME", "healsync")
    PRIMARY_DB_USER = os.environ.get("PRIMARY_DB_USER", "root")
    PRIMARY_DB_PASS = os.environ.get("PRIMARY_DB_PASS", "root123")

    # ── Secondary DB ───────────────────────────────────────────────────────
    SECONDARY_DB_HOST = os.environ.get("SECONDARY_DB_HOST", "localhost")
    SECONDARY_DB_PORT = int(os.environ.get("SECONDARY_DB_PORT", 3307))
    SECONDARY_DB_NAME = os.environ.get("SECONDARY_DB_NAME", "healsync")
    SECONDARY_DB_USER = os.environ.get("SECONDARY_DB_USER", "root")
    SECONDARY_DB_PASS = os.environ.get("SECONDARY_DB_PASS", "root123")

    # ── Active target ─────────────────────────────────────────────────────
    ACTIVE_DB = os.environ.get("ACTIVE_DB", "primary")        # "primary" | "secondary"
    CLUSTER_ROLE = os.environ.get("CLUSTER_ROLE", "primary")
    CLUSTER_REGION = os.environ.get("CLUSTER_REGION", "local")

    # ── Failover tuning ───────────────────────────────────────────────────
    HEALTH_CHECK_INTERVAL = int(os.environ.get("HEALTH_CHECK_INTERVAL", 10))
    FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", 3))
    RECOVERY_THRESHOLD = int(os.environ.get("RECOVERY_THRESHOLD", 3))
    EVENT_LOG_LIMIT = int(os.environ.get("EVENT_LOG_LIMIT", 500))
    FAILOVER_MONITOR_ENABLED = _bool_env("FAILOVER_MONITOR_ENABLED", True)
    WAIT_FOR_REPLICATION = _bool_env("WAIT_FOR_REPLICATION", True)
    REPLICATION_STRICT_ACK = _bool_env("REPLICATION_STRICT_ACK", False)
    REPLICATION_WAIT_TIMEOUT_SECONDS = float(os.environ.get("REPLICATION_WAIT_TIMEOUT_SECONDS", 5))
    REPLICATION_POLL_INTERVAL_SECONDS = float(os.environ.get("REPLICATION_POLL_INTERVAL_SECONDS", 0.2))

    # ── SQLAlchemy ────────────────────────────────────────────────────────
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ENGINE_OPTIONS = {
        "pool_pre_ping": True,       # detect dead connections immediately
        "pool_recycle": 280,
        "pool_size": 5,
        "max_overflow": 10,
    }
    JSON_SORT_KEYS = False

    @classmethod
    def primary_uri(cls):
        return (
            f"mysql+pymysql://{cls.PRIMARY_DB_USER}:{cls.PRIMARY_DB_PASS}"
            f"@{cls.PRIMARY_DB_HOST}:{cls.PRIMARY_DB_PORT}/{cls.PRIMARY_DB_NAME}"
            f"?charset=utf8mb4"
        )

    @classmethod
    def secondary_uri(cls):
        return (
            f"mysql+pymysql://{cls.SECONDARY_DB_USER}:{cls.SECONDARY_DB_PASS}"
            f"@{cls.SECONDARY_DB_HOST}:{cls.SECONDARY_DB_PORT}/{cls.SECONDARY_DB_NAME}"
            f"?charset=utf8mb4"
        )


class TestConfig(Config):
    """SQLite-backed config for pytest — no MySQL dependency."""
    TESTING = True
    DEBUG = False
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    PRIMARY_DB_HOST = "sqlite"
    SECONDARY_DB_HOST = "sqlite"
    HEALTH_CHECK_INTERVAL = 999      # disable background thread in tests
    FAILURE_THRESHOLD = 2
    RECOVERY_THRESHOLD = 2
    FAILOVER_MONITOR_ENABLED = False
    EVENT_LOG_LIMIT = 50
    WAIT_FOR_REPLICATION = False
    REPLICATION_STRICT_ACK = False
    REPLICATION_WAIT_TIMEOUT_SECONDS = 0.0
    REPLICATION_POLL_INTERVAL_SECONDS = 0.0
    TEST_FORCE_REPLICATION_RESULT = None
    SQLALCHEMY_ENGINE_OPTIONS = {}
