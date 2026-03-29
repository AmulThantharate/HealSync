"""
models.py — SQLAlchemy models for the HealSync application.
"""
from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class DREvent(db.Model):
    """Logs every failover / failback / health-change event."""
    __tablename__ = "dr_events"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    timestamp = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), nullable=False)
    event_type = db.Column(db.String(50), nullable=False)       # FAILOVER, FAILBACK, DEGRADED, RECOVERED
    from_db = db.Column(db.String(20), nullable=True)           # primary / secondary
    to_db = db.Column(db.String(20), nullable=True)             # primary / secondary
    details = db.Column(db.Text, nullable=True)

    def to_dict(self):
        return {
            "id": self.id,
            "timestamp": self.timestamp.isoformat() + "Z",
            "event_type": self.event_type,
            "from_db": self.from_db,
            "to_db": self.to_db,
            "details": self.details,
        }


class Todo(db.Model):
    """Todo model for the application."""
    __tablename__ = "todos"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    task = db.Column(db.String(255), nullable=False)
    completed = db.Column(db.Boolean, default=False)
    written_to = db.Column(db.String(20), nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id": self.id,
            "task": self.task,
            "completed": self.completed,
            "written_to": self.written_to,
            "created_at": self.created_at.isoformat() + "Z",
        }


class TestData(db.Model):
    """Simple key-value store to prove writes go to the active DB."""
    __tablename__ = "test_data"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    key = db.Column(db.String(100), nullable=False)
    value = db.Column(db.Text, nullable=True)
    written_to = db.Column(db.String(20), nullable=False)       # which DB received the write
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id": self.id,
            "key": self.key,
            "value": self.value,
            "written_to": self.written_to,
            "created_at": self.created_at.isoformat() + "Z",
        }
