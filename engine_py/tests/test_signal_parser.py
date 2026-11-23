import unittest

from nixo_engine.signal_parser import SignalParseError, parse_signal


class SignalParserTests(unittest.TestCase):
    def test_parses_labelled_gold_buy_with_multiple_targets(self):
        signal = parse_signal("BUY GOLD @ 2350.5 SL 2340 TP1 2355 TP2 2360")
        self.assertEqual(signal.side, "buy")
        self.assertEqual(signal.symbol, "XAUUSD")
        self.assertEqual(signal.entry_low, 2350.5)
        self.assertEqual(signal.stop_loss, 2340)
        self.assertEqual(signal.take_profits, (2355.0, 2360.0))

    def test_parses_sell_range_and_orders_targets_nearest_first(self):
        signal = parse_signal(
            "SELL EURUSD ENTRY 1.0850-1.0860 STOP LOSS 1.0900 "
            "TAKE PROFIT 1.0800 TP2 1.0750"
        )
        self.assertEqual(signal.side, "sell")
        self.assertEqual((signal.entry_low, signal.entry_high), (1.085, 1.086))
        self.assertEqual(signal.take_profits, (1.08, 1.075))

    def test_parses_persian_digits_and_decimal_comma(self):
        signal = parse_signal("BUY XAUUSD ENTRY ۲۳۵۰,۵ SL ۲۳۴۰ TP1 ۲۳۶۰")
        self.assertEqual(signal.entry_low, 2350.5)
        self.assertEqual(signal.stop_loss, 2340.0)

    def test_accepts_explicit_market_now_without_entry(self):
        signal = parse_signal("BUY GOLD NOW SL 2300 TP1 2320")
        self.assertEqual(signal.order_type, "market")
        self.assertIsNone(signal.entry_low)

    def test_rejects_conflicting_directions(self):
        with self.assertRaisesRegex(SignalParseError, "exactly one trade direction"):
            parse_signal("BUY XAUUSD and SELL XAUUSD ENTRY 2300 SL 2290 TP1 2310")

    def test_rejects_multiple_symbols(self):
        with self.assertRaises(SignalParseError) as ctx:
            parse_signal("BUY XAUUSD EURUSD ENTRY 2300 SL 2290 TP1 2310")
        self.assertEqual(ctx.exception.code, "ambiguous_or_missing_symbol")

    def test_requires_stop_and_entry_but_not_provider_take_profit(self):
        cases = [
            "BUY XAUUSD ENTRY 2300 TP1 2310",
            "BUY XAUUSD SL 2290 TP1 2310",
        ]
        for message in cases:
            with self.subTest(message=message), self.assertRaises(SignalParseError):
                parse_signal(message)
        signal = parse_signal("BUY XAUUSD ENTRY 2300 SL 2290")
        self.assertEqual(signal.take_profits, ())

    def test_rejects_stop_on_wrong_side(self):
        with self.assertRaisesRegex(SignalParseError, "BUY stop-loss"):
            parse_signal("BUY XAUUSD ENTRY 2300 SL 2310 TP1 2320")

    def test_provider_targets_are_preserved_for_audit(self):
        signal = parse_signal("BUY XAUUSD ENTRY 2300 SL 2290 TP1 2295 TP2 2310")
        self.assertEqual(signal.take_profits, (2295.0, 2310.0))

    def test_rejects_multiple_entry_zones_and_duplicate_targets(self):
        with self.assertRaises(SignalParseError):
            parse_signal("BUY XAUUSD ENTRY 2300 @ 2301 SL 2290 TP1 2320")
        with self.assertRaises(SignalParseError):
            parse_signal("BUY XAUUSD ENTRY 2300 SL 2290 TP1 2320 TP2 2320")

    def test_rejects_incomplete_non_market_message(self):
        with self.assertRaisesRegex(SignalParseError, "entry price or explicit NOW"):
            parse_signal("BUY XAUUSD SL 2290 TP1 2310")


if __name__ == "__main__":
    unittest.main()
