from __future__ import annotations

from dataclasses import asdict
from typing import Any
from uuid import uuid4

try:
    from fastapi import FastAPI, HTTPException
    from pydantic import BaseModel, Field
except ImportError:  # Keeps the domain usable before optional API dependencies are installed.
    FastAPI = None

from .domain import Evidence, ScanBatch, all_positions, resolve_evidence


class EvidenceInput(BaseModel):
    barcode: str | None = None
    ocr: str | None = None
    barcode_confidence: float = Field(0, ge=0, le=1)
    ocr_confidence: float = Field(0, ge=0, le=1)


class ScanRequest(BaseModel):
    tray_id: str = Field(min_length=1)
    operator_id: str = Field(min_length=1)
    batch_id: str | None = None
    cells: dict[str, EvidenceInput]


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

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/scan-batches")
    def scan_batch(request: ScanRequest) -> dict[str, Any]:
        try:
            return process_scan(request)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
else:
    app = None
