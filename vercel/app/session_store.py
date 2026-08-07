from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import secrets
from threading import Lock
from typing import Any


@dataclass(frozen=True)
class DashboardCell:
    position: str
    imei: str | None
    status: str
    source: str
    confidence: float
    reason: str


@dataclass
class DashboardSession:
    code: str
    created_at: str
    batches: list[dict[str, Any]] = field(default_factory=list)
    imeis: list[dict[str, Any]] = field(default_factory=list)
    seen_batch_ids: set[str] = field(default_factory=set)

    def snapshot(self) -> dict[str, Any]:
        return {
            "session_code": self.code,
            "created_at": self.created_at,
            "batch_count": len(self.batches),
            "device_count": len(self.imeis),
            "imeis": list(self.imeis),
            "batches": list(self.batches),
        }


class SessionStore:
    """Temporary process-local store. It intentionally has no permanent persistence."""

    def __init__(self) -> None:
        self._sessions: dict[str, DashboardSession] = {}
        self._lock = Lock()

    def create(self) -> DashboardSession:
        with self._lock:
            code = secrets.token_hex(3).upper()
            while code in self._sessions:
                code = secrets.token_hex(3).upper()
            session = DashboardSession(code, datetime.now(timezone.utc).isoformat())
            self._sessions[code] = session
            return session

    def get(self, code: str) -> DashboardSession | None:
        with self._lock:
            return self._sessions.get(code.upper())

    def add_batch(self, session: DashboardSession, batch_id: str, tray_number: int, cells: list[DashboardCell]) -> bool:
        with self._lock:
            if batch_id in session.seen_batch_ids:
                return False
            session.seen_batch_ids.add(batch_id)
            accepted = [cell for cell in cells if cell.status == "accepted" and cell.imei]
            created_at = datetime.now(timezone.utc).isoformat()
            session.batches.append({
                "batch_id": batch_id,
                "tray_number": tray_number,
                "created_at": created_at,
                "accepted_count": len(accepted),
                "total_count": len(cells),
            })
            for cell in accepted:
                session.imeis.append({
                    "imei": cell.imei,
                    "position": cell.position,
                    "tray_number": tray_number,
                    "batch_id": batch_id,
                    "source": cell.source,
                    "confidence": cell.confidence,
                    "created_at": created_at,
                })
            return True
