import unittest

from nixo_engine.roulette import Roulette, RouletteConfig, RouletteState


class RouletteTests(unittest.TestCase):
    def test_default_is_enabled_but_growth_trigger_gates_progression(self):
        r = Roulette(RouletteConfig(), RouletteState("tg-A"))
        self.assertTrue(r.config.enabled)
        self.assertFalse(r.check_activation(1000))
        self.assertEqual(r.current_risk_pct(), 0.5)
        self.assertTrue(r.check_activation(1030))
        self.assertEqual(r.current_risk_pct(), 0.5)

    def test_win_advances_one_step_and_loss_recedes_one(self):
        r = Roulette(RouletteConfig(activation_trigger_pct=0),
                     RouletteState("tg-A"))
        r.check_activation(1000)
        self.assertEqual(r.on_batch_result(20, 100), "win")
        self.assertEqual(r.state.step, 2)
        self.assertEqual(r.on_batch_result(-20, 100), "loss")
        self.assertEqual(r.state.step, 1)

    def test_flat_does_not_change_step(self):
        r = Roulette(RouletteConfig(activation_trigger_pct=0),
                     RouletteState("tg-A"))
        r.check_activation(1000)
        self.assertEqual(r.on_batch_result(10, 100), "flat")
        self.assertEqual(r.state.step, 1)

    def test_account_states_are_independent(self):
        a = Roulette(RouletteConfig(activation_trigger_pct=0), RouletteState("A"))
        b = Roulette(RouletteConfig(activation_trigger_pct=0), RouletteState("B"))
        a.check_activation(1000)
        b.check_activation(1000)
        a.on_batch_result(20, 100)
        self.assertEqual(a.state.step, 2)
        self.assertEqual(b.state.step, 1)

    def test_order_roulette_is_independent_and_capped(self):
        cfg = RouletteConfig(model="order", activation_trigger_pct=0, max_order_count=4)
        r = Roulette(cfg, RouletteState("tg-order"))
        r.check_activation(1000)
        self.assertEqual(r.order_count(), 1)
        for _ in range(8):
            r.on_batch_result(20, 100)
        self.assertEqual(r.order_count(), 4)

    def test_volume_risk_is_capped(self):
        r = Roulette(RouletteConfig(activation_trigger_pct=0, max_risk_pct=2.0),
                     RouletteState("tg-cap"))
        r.check_activation(1000)
        for _ in range(8):
            r.on_batch_result(20, 100)
        self.assertEqual(r.current_risk_pct(), 2.0)


if __name__ == "__main__":
    unittest.main()
