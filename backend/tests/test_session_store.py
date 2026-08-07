import unittest

from multiscan_api.session_store import DashboardCell, SessionStore


class DashboardSessionTests(unittest.TestCase):
    def test_accepted_imeis_append_including_duplicates(self) -> None:
        store = SessionStore()
        session = store.create()
        cell = DashboardCell("P1", "490154203237518", "accepted", "barcode", 0.99, "valid")

        self.assertTrue(store.add_batch(session, "batch-1", 1, [cell]))
        self.assertTrue(store.add_batch(session, "batch-2", 2, [cell]))
        self.assertEqual(["490154203237518", "490154203237518"], [item["imei"] for item in session.imeis])

    def test_retrying_batch_is_idempotent(self) -> None:
        store = SessionStore()
        session = store.create()
        cell = DashboardCell("P1", "490154203237518", "accepted", "barcode", 0.99, "valid")

        self.assertTrue(store.add_batch(session, "batch-1", 1, [cell]))
        self.assertFalse(store.add_batch(session, "batch-1", 1, [cell]))
        self.assertEqual(1, len(session.imeis))


if __name__ == "__main__":
    unittest.main()
