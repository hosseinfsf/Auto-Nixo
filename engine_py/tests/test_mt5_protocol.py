import unittest

from nixo_engine.mt5_protocol import Mt5Message, authenticated, escape, open_order, unescape


class ProtocolTests(unittest.TestCase):
    def test_percent_encoding_round_trip(self):
        value = "a%|=b\r\nc"
        self.assertEqual(unescape(escape(value)), value)

    def test_message_round_trip(self):
        msg = Mt5Message({"CMD": "OPEN", "COMMENT": "فارسی | 100%"})
        self.assertEqual(Mt5Message.decode(msg.encode()).fields, msg.fields)

    def test_auth_requires_long_token(self):
        with self.assertRaises(ValueError):
            authenticated("short")
        self.assertEqual(authenticated("x" * 32).command, "AUTH")

    def test_open_requires_sl_and_client_id(self):
        with self.assertRaises(ValueError):
            open_order(req_id="1", symbol="XAUUSD", side="buy",
                       order_type="market", lots=0.1, entry=0, sl=0,
                       tps=[], client_order_id="id")


if __name__ == "__main__":
    unittest.main()
