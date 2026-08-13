from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from typing import Any, Optional
from uuid import uuid4

try:
    from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
    from fastapi.responses import HTMLResponse, RedirectResponse
    from fastapi.staticfiles import StaticFiles
    from pydantic import BaseModel, Field
except ImportError:  # Keeps the domain usable before optional API dependencies are installed.
    FastAPI = None

from .domain import Evidence, ScanBatch, all_positions, is_valid_imei, resolve_evidence
from .session_store import DashboardCell, SessionStore


class EvidenceInput(BaseModel):
    barcode: Optional[str] = None
    ocr: Optional[str] = None
    barcode_confidence: float = Field(0, ge=0, le=1)
    ocr_confidence: float = Field(0, ge=0, le=1)


class ScanRequest(BaseModel):
    tray_id: str = Field(min_length=1)
    operator_id: str = Field(min_length=1)
    batch_id: Optional[str] = None
    cells: dict[str, EvidenceInput]


class DashboardCellInput(BaseModel):
    position: str = Field(min_length=1)
    imei: Optional[str] = None
    status: str = Field(min_length=1)
    source: str = Field(min_length=1)
    confidence: float = Field(0, ge=0, le=1)
    reason: str = Field(min_length=1)


class DashboardBatchRequest(BaseModel):
    batch_id: str = Field(min_length=1)
    tray_number: int = Field(ge=1)
    cells: list[DashboardCellInput]


def process_scan(request: ScanRequest) -> dict[str, Any]:
    unknown = set(request.cells) - set(all_positions())
    if unknown:
        raise ValueError(f"unknown tray positions: {sorted(unknown)}")
    cells = [
        resolve_evidence(position, Evidence(**request.cells[position].model_dump()))
        for position in all_positions()
        if position in request.cells
    ]
    batch = ScanBatch(request.batch_id or str(uuid4()), request.tray_id, request.operator_id, cells)
    return {
        "batch_id": batch.batch_id,
        "tray_id": batch.tray_id,
        "operator_id": batch.operator_id,
        "expected_positions": list(all_positions()),
        "summary": batch.summary(),
        "duplicate_imeis": batch.duplicate_imeis(),
        "cells": [asdict(cell) for cell in cells],
    }


if FastAPI:
    app = FastAPI(title="MultiScan API", version="0.1.0")
    sessions = SessionStore()
    dashboard_path = Path(__file__).with_name("dashboard.html")
    assets_path = Path(__file__).with_name("assets")
    app.mount("/assets", StaticFiles(directory=assets_path), name="assets")

    @app.get("/", include_in_schema=False)
    def root() -> RedirectResponse:
        return RedirectResponse(url="/dashboard")

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/scan-batches")
    def scan_batch(request: ScanRequest) -> dict[str, Any]:
        try:
            return process_scan(request)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/dashboard", response_class=HTMLResponse)
    def dashboard() -> HTMLResponse:
        return HTMLResponse(dashboard_path.read_text(encoding="utf-8"))

    @app.post("/v1/sessions")
    def create_session() -> dict[str, Any]:
        return sessions.create().snapshot()

    @app.get("/v1/sessions/{session_code}")
    def get_session(session_code: str) -> dict[str, Any]:
        session = sessions.get(session_code)
        if session is None:
            raise HTTPException(status_code=404, detail="Session not found")
        return session.snapshot()

    @app.post("/v1/sessions/{session_code}/batches")
    async def add_dashboard_batch(session_code: str, request: DashboardBatchRequest) -> dict[str, Any]:
        session = sessions.get(session_code)
        if session is None:
            raise HTTPException(status_code=404, detail="Session not found")
        invalid = [
            cell.position
            for cell in request.cells
            if cell.status == "accepted" and not is_valid_imei(cell.imei)
        ]
        if invalid:
            raise HTTPException(
                status_code=422,
                detail=f"Accepted cells must contain valid 15-digit IMEIs: {invalid}",
            )
        cells = [DashboardCell(**cell.model_dump()) for cell in request.cells]
        try:
            added = sessions.add_batch(session, request.batch_id, request.tray_number, cells)
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        return {"accepted": added, **session.snapshot()}

    @app.post("/v1/sessions/{session_code}/end")
    def end_session(session_code: str) -> dict[str, Any]:
        session = sessions.end(session_code)
        if session is None:
            raise HTTPException(status_code=404, detail="Session not found")
        return session.snapshot()

    @app.websocket("/v1/sessions/{session_code}/events")
    async def session_events(websocket: WebSocket, session_code: str) -> None:
        if sessions.get(session_code) is None:
            await websocket.close(code=1008)
            return
        await websocket.accept()
        try:
            while True:
                await websocket.receive_text()
        except WebSocketDisconnect:
            return
else:
    app = None
