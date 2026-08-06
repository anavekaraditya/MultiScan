import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from multiscan_api.domain import Evidence, ScanStatus, all_positions, is_valid_imei, resolve_evidence


class ImeiTests(unittest.TestCase):
    def test_luhn_validation(self):
        self.assertTrue(is_valid_imei("490154203237518"))
        self.assertFalse(is_valid_imei("490154203237519"))
        self.assertFalse(is_valid_imei("49015420323751"))

    def test_agreement_is_accepted(self):
        result = resolve_evidence("R1C1", Evidence("490154203237518", "490154203237518"))
        self.assertEqual(result.status, ScanStatus.ACCEPTED)
        self.assertEqual(result.imei, "490154203237518")

    def test_conflict_requires_review(self):
        result = resolve_evidence("R1C1", Evidence("490154203237518", "490154203237519", 1, 1))
        self.assertEqual(result.status, ScanStatus.REVIEW)
        self.assertIsNone(result.imei)

    def test_empty_cell_requires_retake(self):
        self.assertEqual(resolve_evidence("R3C5", Evidence()).status, ScanStatus.RETAKE)

    def test_grid_has_fifteen_positions(self):
        self.assertEqual(len(all_positions()), 15)
        self.assertEqual(all_positions()[0], "R1C1")
        self.assertEqual(all_positions()[-1], "R3C5")


if __name__ == "__main__":
    unittest.main()
