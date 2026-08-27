#!/usr/bin/env python3
"""
circuit_breaker.py - Production-Grade Circuit Breaker & Resilient Retry Engine
=============================================================================
Provides a thread-safe Circuit Breaker state machine (CLOSED, OPEN, HALF_OPEN),
exponential backoff retry algorithm with Full Jitter, graceful fallback
degradation, and Prometheus metrics telemetry.
"""

import enum
import logging
import random
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

logger = logging.getLogger("circuit_breaker")


class CircuitState(str, enum.Enum):
    """Circuit Breaker State Machine States."""
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


class CircuitBreakerOpenException(Exception):
    """Raised when an operation is rejected because the circuit is OPEN."""
    def __init__(self, message: str, retry_after_sec: float):
        super().__init__(message)
        self.retry_after_sec = max(0.0, retry_after_sec)


class NonRetryableException(Exception):
    """Wraps an error that should not be retried (e.g., client 4xx HTTP errors)."""
    pass


class CircuitBreakerConfig:
    """Configuration parameters for Circuit Breaker and Retry Engine."""

    def __init__(
        self,
        failure_threshold: int = 5,
        recovery_timeout: float = 5.0,
        half_open_success_threshold: int = 2,
        half_open_max_trials: int = 2,
        call_timeout: float = 1.0,
        max_retries: int = 3,
        base_backoff: float = 0.1,
        max_backoff: float = 2.0,
        jitter: bool = True,
        retryable_status_codes: Optional[Set[int]] = None,
    ):
        self.failure_threshold = max(1, failure_threshold)
        self.recovery_timeout = max(0.1, recovery_timeout)
        self.half_open_success_threshold = max(1, half_open_success_threshold)
        self.half_open_max_trials = max(1, half_open_max_trials)
        self.call_timeout = max(0.05, call_timeout)
        self.max_retries = max(0, max_retries)
        self.base_backoff = max(0.01, base_backoff)
        self.max_backoff = max(self.base_backoff, max_backoff)
        self.jitter = jitter
        self.retryable_status_codes = retryable_status_codes or {500, 502, 503, 504, 429}

    def to_dict(self) -> Dict[str, Any]:
        return {
            "failure_threshold": self.failure_threshold,
            "recovery_timeout_sec": self.recovery_timeout,
            "half_open_success_threshold": self.half_open_success_threshold,
            "half_open_max_trials": self.half_open_max_trials,
            "call_timeout_sec": self.call_timeout,
            "max_retries": self.max_retries,
            "base_backoff_sec": self.base_backoff,
            "max_backoff_sec": self.max_backoff,
            "jitter_enabled": self.jitter,
            "retryable_status_codes": sorted(list(self.retryable_status_codes)),
        }


class CircuitBreakerResult:
    """Encapsulates the execution outcome, fallback indicators, and latency."""

    def __init__(
        self,
        success: bool,
        data: Any = None,
        error: Optional[str] = None,
        is_fallback: bool = False,
        circuit_state: CircuitState = CircuitState.CLOSED,
        attempts: int = 1,
        latency_ms: float = 0.0,
        short_circuited: bool = False,
    ):
        self.success = success
        self.data = data
        self.error = error
        self.is_fallback = is_fallback
        self.circuit_state = circuit_state
        self.attempts = attempts
        self.latency_ms = round(latency_ms, 2)
        self.short_circuited = short_circuited

    def to_dict(self) -> Dict[str, Any]:
        return {
            "success": self.success,
            "data": self.data,
            "error": self.error,
            "is_fallback": self.is_fallback,
            "circuit_state": self.circuit_state.value,
            "attempts": self.attempts,
            "latency_ms": self.latency_ms,
            "short_circuited": self.short_circuited,
        }


class CircuitBreaker:
    """Thread-safe Circuit Breaker with Exponential Backoff Retry Engine."""

    def __init__(self, name: str = "default-service", config: Optional[CircuitBreakerConfig] = None):
        self.name = name
        self.config = config or CircuitBreakerConfig()
        self._lock = threading.RLock()

        # State tracking
        self.state: CircuitState = CircuitState.CLOSED
        self.last_state_change: float = time.time()
        self.consecutive_failures: int = 0
        self.consecutive_successes: int = 0
        self.half_open_trials_in_flight: int = 0

        # Telemetry metrics
        self.total_requests: int = 0
        self.successful_requests: int = 0
        self.failed_requests: int = 0
        self.fallback_requests: int = 0
        self.short_circuited_requests: int = 0
        self.total_retries: int = 0

        # State transition history (max 50 entries)
        self.state_history: List[Dict[str, Any]] = [
            {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "epoch": time.time(),
                "from_state": None,
                "to_state": CircuitState.CLOSED.value,
                "reason": "Initial startup in CLOSED state",
            }
        ]

    def _record_transition(self, from_state: Optional[CircuitState], to_state: CircuitState, reason: str) -> None:
        """Internal helper to record state machine transitions."""
        self.state = to_state
        self.last_state_change = time.time()
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "epoch": self.last_state_change,
            "from_state": from_state.value if from_state else None,
            "to_state": to_state.value,
            "reason": reason,
        }
        self.state_history.append(entry)
        if len(self.state_history) > 50:
            self.state_history.pop(0)
        logger.warning(
            f"[CircuitBreaker:{self.name}] Transitioned: {from_state.value if from_state else 'NONE'} -> {to_state.value} | Reason: {reason}"
        )

    def calculate_backoff(self, attempt: int) -> float:
        """
        Calculates Exponential Backoff delay with Full Jitter.
        Full Jitter Formula: delay = Uniform(0, min(max_backoff, base_backoff * 2^attempt))
        Reference: AWS Architecture Blog 'Exponential Backoff And Jitter'
        """
        ceiling = min(self.config.max_backoff, self.config.base_backoff * (2 ** attempt))
        if self.config.jitter:
            return random.uniform(0.0, ceiling)
        return ceiling

    def _before_call(self) -> None:
        """Validates if a call is allowed under the current circuit state."""
        with self._lock:
            now = time.time()

            if self.state == CircuitState.OPEN:
                elapsed = now - self.last_state_change
                if elapsed >= self.config.recovery_timeout:
                    # Timeout expired: Transition to HALF_OPEN probe state
                    self._record_transition(
                        from_state=CircuitState.OPEN,
                        to_state=CircuitState.HALF_OPEN,
                        reason=f"Recovery timeout ({self.config.recovery_timeout}s) expired; initiating probe trial.",
                    )
                    self.consecutive_successes = 0
                    self.half_open_trials_in_flight = 1
                    return
                else:
                    remaining = self.config.recovery_timeout - elapsed
                    self.short_circuited_requests += 1
                    raise CircuitBreakerOpenException(
                        f"Circuit breaker is OPEN. Fast-failing downstream call.",
                        retry_after_sec=remaining,
                    )

            elif self.state == CircuitState.HALF_OPEN:
                if self.half_open_trials_in_flight >= self.config.half_open_max_trials:
                    self.short_circuited_requests += 1
                    raise CircuitBreakerOpenException(
                        f"Circuit breaker is HALF_OPEN and trial probe limit ({self.config.half_open_max_trials}) reached.",
                        retry_after_sec=1.0,
                    )
                self.half_open_trials_in_flight += 1

    def _on_success(self) -> None:
        """Handles successful response logic and state updates."""
        with self._lock:
            self.successful_requests += 1

            if self.state == CircuitState.CLOSED:
                self.consecutive_failures = 0

            elif self.state == CircuitState.HALF_OPEN:
                self.consecutive_successes += 1
                self.half_open_trials_in_flight = max(0, self.half_open_trials_in_flight - 1)

                if self.consecutive_successes >= self.config.half_open_success_threshold:
                    self._record_transition(
                        from_state=CircuitState.HALF_OPEN,
                        to_state=CircuitState.CLOSED,
                        reason=f"Successfully verified {self.consecutive_successes} probe requests. Circuit fully healed.",
                    )
                    self.consecutive_failures = 0
                    self.consecutive_successes = 0

    def _on_failure(self, error: Exception) -> None:
        """Handles error response logic and triggers tripping transitions."""
        with self._lock:
            self.failed_requests += 1

            if self.state == CircuitState.CLOSED:
                self.consecutive_failures += 1
                if self.consecutive_failures >= self.config.failure_threshold:
                    self._record_transition(
                        from_state=CircuitState.CLOSED,
                        to_state=CircuitState.OPEN,
                        reason=f"Exceeded failure threshold ({self.consecutive_failures}/{self.config.failure_threshold} consecutive errors): {error}",
                    )

            elif self.state == CircuitState.HALF_OPEN:
                self.half_open_trials_in_flight = max(0, self.half_open_trials_in_flight - 1)
                self._record_transition(
                    from_state=CircuitState.HALF_OPEN,
                    to_state=CircuitState.OPEN,
                    reason=f"Probe trial failed during HALF_OPEN state: {error}. Immediately tripping back to OPEN.",
                )
                self.consecutive_failures = self.config.failure_threshold
                self.consecutive_successes = 0

    def is_retryable(self, error: Exception) -> bool:
        """Determines whether a raised exception should trigger a retry attempt."""
        if isinstance(error, NonRetryableException):
            return False
        if isinstance(error, CircuitBreakerOpenException):
            return False
        return True

    def execute(
        self,
        func: Callable[..., Any],
        fallback: Optional[Callable[..., Any]] = None,
        fallback_data: Any = None,
        *args: Any,
        **kwargs: Any,
    ) -> CircuitBreakerResult:
        """
        Executes the given callable with Circuit Breaker protection,
        exponential backoff retries, and fallback handling.
        """
        start_time = time.time()
        attempts = 0

        with self._lock:
            self.total_requests += 1

        # Check circuit state before attempting execution
        try:
            self._before_call()
        except CircuitBreakerOpenException as cbe:
            latency_ms = (time.time() - start_time) * 1000.0
            return self._handle_fallback(
                fallback_fn=fallback,
                fallback_data=fallback_data,
                error=str(cbe),
                attempts=0,
                latency_ms=latency_ms,
                short_circuited=True,
                args=args,
                kwargs=kwargs,
            )

        # In HALF_OPEN probe state, do not retry; single probe determination
        allowed_retries = 0 if self.state == CircuitState.HALF_OPEN else self.config.max_retries
        last_exception: Optional[Exception] = None

        while True:
            attempts += 1
            try:
                result_data = func(*args, **kwargs)
                self._on_success()
                latency_ms = (time.time() - start_time) * 1000.0
                return CircuitBreakerResult(
                    success=True,
                    data=result_data,
                    is_fallback=False,
                    circuit_state=self.state,
                    attempts=attempts,
                    latency_ms=latency_ms,
                    short_circuited=False,
                )

            except Exception as e:
                last_exception = e
                # Check if retry should be attempted
                if self.is_retryable(e) and attempts <= allowed_retries and self.state != CircuitState.OPEN:
                    with self._lock:
                        self.total_retries += 1
                    backoff_delay = self.calculate_backoff(attempt=attempts - 1)
                    time.sleep(backoff_delay)
                    continue
                else:
                    # All retries exhausted or non-retryable error
                    self._on_failure(last_exception)
                    latency_ms = (time.time() - start_time) * 1000.0
                    return self._handle_fallback(
                        fallback_fn=fallback,
                        fallback_data=fallback_data,
                        error=str(last_exception),
                        attempts=attempts,
                        latency_ms=latency_ms,
                        short_circuited=False,
                        args=args,
                        kwargs=kwargs,
                    )

    def _handle_fallback(
        self,
        fallback_fn: Optional[Callable[..., Any]],
        fallback_data: Any,
        error: str,
        attempts: int,
        latency_ms: float,
        short_circuited: bool,
        args: Tuple[Any, ...],
        kwargs: Dict[str, Any],
    ) -> CircuitBreakerResult:
        """Executes fallback logic or returns degraded default payload."""
        with self._lock:
            self.fallback_requests += 1

        fallback_payload = None
        if fallback_fn is not None:
            try:
                fallback_payload = fallback_fn(*args, **kwargs)
            except Exception as fe:
                fallback_payload = {"fallback_error": str(fe)}
        elif fallback_data is not None:
            fallback_payload = fallback_data
        else:
            fallback_payload = {
                "message": "Service temporarily degraded. Operating in fallback mode.",
                "cached": True,
            }

        return CircuitBreakerResult(
            success=False,
            data=fallback_payload,
            error=error,
            is_fallback=True,
            circuit_state=self.state,
            attempts=attempts,
            latency_ms=latency_ms,
            short_circuited=short_circuited,
        )

    # --------------------------------------------------------------------------
    # Operational & Administrative Controls
    # --------------------------------------------------------------------------
    def trip(self, reason: str = "Manual operator trip") -> None:
        """Manually forces the Circuit Breaker into OPEN state."""
        with self._lock:
            prev = self.state
            self._record_transition(from_state=prev, to_state=CircuitState.OPEN, reason=reason)
            self.consecutive_failures = self.config.failure_threshold

    def reset(self, reason: str = "Manual operator reset") -> None:
        """Manually resets the Circuit Breaker to CLOSED state."""
        with self._lock:
            prev = self.state
            self._record_transition(from_state=prev, to_state=CircuitState.CLOSED, reason=reason)
            self.consecutive_failures = 0
            self.consecutive_successes = 0
            self.half_open_trials_in_flight = 0

    def update_config(self, **kwargs: Any) -> None:
        """Dynamically updates configuration parameters at runtime."""
        with self._lock:
            if "failure_threshold" in kwargs:
                self.config.failure_threshold = max(1, int(kwargs["failure_threshold"]))
            if "recovery_timeout" in kwargs:
                self.config.recovery_timeout = max(0.1, float(kwargs["recovery_timeout"]))
            if "half_open_success_threshold" in kwargs:
                self.config.half_open_success_threshold = max(1, int(kwargs["half_open_success_threshold"]))
            if "max_retries" in kwargs:
                self.config.max_retries = max(0, int(kwargs["max_retries"]))
            if "base_backoff" in kwargs:
                self.config.base_backoff = max(0.01, float(kwargs["base_backoff"]))
            if "max_backoff" in kwargs:
                self.config.max_backoff = max(self.config.base_backoff, float(kwargs["max_backoff"]))
            if "jitter" in kwargs:
                self.config.jitter = bool(kwargs["jitter"])

    def get_stats(self) -> Dict[str, Any]:
        """Returns snapshot of state, metrics, and health."""
        with self._lock:
            state_val = self.state.value
            return {
                "name": self.name,
                "state": state_val,
                "consecutive_failures": self.consecutive_failures,
                "consecutive_successes": self.consecutive_successes,
                "half_open_trials_in_flight": self.half_open_trials_in_flight,
                "last_state_change_seconds_ago": round(time.time() - self.last_state_change, 2),
                "metrics": {
                    "total_requests": self.total_requests,
                    "successful_requests": self.successful_requests,
                    "failed_requests": self.failed_requests,
                    "fallback_requests": self.fallback_requests,
                    "short_circuited_requests": self.short_circuited_requests,
                    "total_retries": self.total_retries,
                    "error_rate_pct": round(
                        (self.failed_requests / self.total_requests * 100.0) if self.total_requests > 0 else 0.0, 2
                    ),
                },
                "config": self.config.to_dict(),
            }

    def to_prometheus_metrics(self) -> str:
        """Exports metrics in standard Prometheus text format."""
        with self._lock:
            state_code = 0 if self.state == CircuitState.CLOSED else (1 if self.state == CircuitState.HALF_OPEN else 2)
            lines = [
                f"# HELP circuit_breaker_state Current state of circuit breaker (0=CLOSED, 1=HALF_OPEN, 2=OPEN)",
                f"# TYPE circuit_breaker_state gauge",
                f'circuit_breaker_state{{name="{self.name}"}} {state_code}',
                f"# HELP circuit_breaker_requests_total Total requests processed by circuit breaker",
                f"# TYPE circuit_breaker_requests_total counter",
                f'circuit_breaker_requests_total{{name="{self.name}"}} {self.total_requests}',
                f"# HELP circuit_breaker_successful_requests_total Successful requests processed",
                f"# TYPE circuit_breaker_successful_requests_total counter",
                f'circuit_breaker_successful_requests_total{{name="{self.name}"}} {self.successful_requests}',
                f"# HELP circuit_breaker_failed_requests_total Failed requests recorded",
                f"# TYPE circuit_breaker_failed_requests_total counter",
                f'circuit_breaker_failed_requests_total{{name="{self.name}"}} {self.failed_requests}',
                f"# HELP circuit_breaker_fallback_requests_total Fallback responses served",
                f"# TYPE circuit_breaker_fallback_requests_total counter",
                f'circuit_breaker_fallback_requests_total{{name="{self.name}"}} {self.fallback_requests}',
                f"# HELP circuit_breaker_short_circuited_total Short-circuited fast-fail requests",
                f"# TYPE circuit_breaker_short_circuited_total counter",
                f'circuit_breaker_short_circuited_total{{name="{self.name}"}} {self.short_circuited_requests}',
                f"# HELP circuit_breaker_retries_total Total retry attempts executed",
                f"# TYPE circuit_breaker_retries_total counter",
                f'circuit_breaker_retries_total{{name="{self.name}"}} {self.total_retries}',
                f"# HELP circuit_breaker_consecutive_failures Consecutive failure count",
                f"# TYPE circuit_breaker_consecutive_failures gauge",
                f'circuit_breaker_consecutive_failures{{name="{self.name}"}} {self.consecutive_failures}',
            ]
            return "\n".join(lines) + "\n"
