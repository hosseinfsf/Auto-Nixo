"""Per-Telegram-channel volume/order roulette, ported from documented legacy rules."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class RouletteConfig:
    enabled: bool = True
    model: str = "volume"
    base_risk_pct: float = 0.5
    activation_trigger_pct: float = 3.0
    max_risk_pct: float = 5.0
    max_steps: int = 50
    volume_step_factor: float = 2.0
    initial_order_count: int = 1
    max_order_count: int = 8

    def validate(self) -> None:
        if self.model not in {"volume", "order", "combined", "off"}:
            raise ValueError("unsupported roulette model")
        if self.base_risk_pct <= 0 or self.max_risk_pct < self.base_risk_pct:
            raise ValueError("risk percentages are invalid")
        if self.activation_trigger_pct < 0 or self.max_steps < 1:
            raise ValueError("trigger and max_steps are invalid")
        if self.volume_step_factor < 1:
            raise ValueError("volume_step_factor must be >= 1")
        if self.initial_order_count < 1 or self.max_order_count < self.initial_order_count:
            raise ValueError("order count limits are invalid")


@dataclass
class RouletteState:
    channel_id: str
    step: int = 1
    activated: bool = False
    baseline_equity: float = 0.0
    completed_batches: int = 0


class Roulette:
    """A separate state object must be loaded for each Telegram source channel."""

    def __init__(self, config: RouletteConfig, state: RouletteState):
        config.validate()
        if state.step < 1 or state.step > config.max_steps:
            raise ValueError("roulette step is outside configured limits")
        self.config = config
        self.state = state

    def check_activation(self, equity: float) -> bool:
        if equity <= 0:
            return False
        if self.state.baseline_equity <= 0:
            self.state.baseline_equity = equity
        if self.state.activated:
            return True
        if not self.config.enabled or self.config.model == "off":
            return False
        gain_pct = (equity - self.state.baseline_equity) / self.state.baseline_equity * 100
        if self.config.activation_trigger_pct <= 0 or gain_pct >= self.config.activation_trigger_pct:
            self.state.activated = True
        return self.state.activated

    def current_risk_pct(self) -> float:
        if not self.config.enabled or self.config.model not in {"volume", "combined"}:
            return self.config.base_risk_pct
        if not self.state.activated:
            return self.config.base_risk_pct
        raw = self.config.base_risk_pct * (self.config.volume_step_factor ** (self.state.step - 1))
        return min(raw, self.config.max_risk_pct)

    def order_count(self) -> int:
        if not self.config.enabled or self.config.model not in {"order", "combined"}:
            return self.config.initial_order_count
        if not self.state.activated:
            return self.config.initial_order_count
        return min(self.state.step, self.config.max_order_count)

    def on_batch_result(self, net_profit: float, risk_money: float) -> str:
        if not self.config.enabled or self.config.model == "off" or not self.state.activated:
            return "not_activated"
        if risk_money < 0:
            raise ValueError("risk_money cannot be negative")
        flat = risk_money > 0 and abs(net_profit) < 0.15 * risk_money
        if flat:
            action = "flat"
        elif net_profit > 0:
            self.state.step = min(self.config.max_steps, self.state.step + 1)
            action = "win"
        elif net_profit < 0:
            self.state.step = max(1, self.state.step - 1)
            action = "loss"
        else:
            action = "flat"
        self.state.completed_batches += 1
        return action
