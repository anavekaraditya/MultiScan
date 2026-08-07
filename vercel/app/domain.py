from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
import re


class ScanStatus(str, Enum):
    ACCEPTED = "accepted"
    REVIEW = "review"
    RETAKE = "retake"


class EvidenceSource(str, Enum):
    BARCODE = "barcode"
    OCR = "ocr"
    BOTH = "both"
    NONE = "none"


def normalize_digits(value: str | None) -> str:
    return re.sub(r"\D", "", value or "")


def is_valid_imei(value: str | None) -> bool:
    digits = normalize_digits(value)
    if len(digits) != 15:
        return False
    total = 0
    for index, char in enumerate(digits):
        digit = int(char)
        if index % 2 == 1:
            digit *= 2
            digit = digit - 9 if digit > 9 else digit
        total += digit
    return total % 10 == 0


def position_key(row: int, column: int) -> str:
    if row not in range(1, 4) or column not in range(1, 6):
        raise ValueError("tray position must be within rows 1-3 and columns 1-5")
    return f"R{row}C{column}"


@dataclass(frozen=True)
class Evidence:
    barcode: str | None = None
    ocr: str | None = None
    barcode_confidence: float = 0.0
    ocr_confidence: float = 0.0


@dataclass(frozen=True)
class CellResult:
    position: str
    imei: str | None
    status: ScanStatus
    source: EvidenceSource
    reason: str
    evidence: Evidence


def resolve_evidence(position: str, evidence: Evidence, minimum_confidence: float = 0.90) -> CellResult:
    barcode = normalize_digits(evidence.barcode)
    ocr = normalize_digits(evidence.ocr)
    barcode_valid = is_valid_imei(barcode)
    ocr_valid = is_valid_imei(ocr)

    if barcode_valid and ocr_valid and barcode == ocr:
        return CellResult(position, barcode, ScanStatus.ACCEPTED, EvidenceSource.BOTH, "barcode_and_ocr_agree", evidence)
    if barcode_valid and not ocr and evidence.barcode_confidence >= minimum_confidence:
        return CellResult(position, barcode, ScanStatus.ACCEPTED, EvidenceSource.BARCODE, "valid_barcode_high_confidence", evidence)
    if ocr_valid and not barcode and evidence.ocr_confidence >= minimum_confidence:
        return CellResult(position, ocr, ScanStatus.ACCEPTED, EvidenceSource.OCR, "valid_ocr_high_confidence", evidence)
    if barcode_valid and ocr_valid and barcode != ocr:
        return CellResult(position, None, ScanStatus.REVIEW, EvidenceSource.NONE, "barcode_ocr_conflict", evidence)
    if barcode or ocr:
        return CellResult(position, None, ScanStatus.REVIEW, EvidenceSource.NONE, "candidate_failed_confidence_or_check_digit", evidence)
    return CellResult(position, None, ScanStatus.RETAKE, EvidenceSource.NONE, "no_readable_imei", evidence)


def all_positions() -> tuple[str, ...]:
    return tuple(position_key(row, column) for row in range(1, 4) for column in range(1, 6))


@dataclass
class ScanBatch:
    batch_id: str
    tray_id: str
    operator_id: str
    cells: list[CellResult] = field(default_factory=list)

    def summary(self) -> dict[str, int]:
        return {status.value: sum(cell.status == status for cell in self.cells) for status in ScanStatus}

    def duplicate_imeis(self) -> list[str]:
        imeis = [cell.imei for cell in self.cells if cell.imei]
        return sorted({imei for imei in imeis if imeis.count(imei) > 1})
