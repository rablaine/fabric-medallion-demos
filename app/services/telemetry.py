"""Adoption telemetry for the Fabric Data Estate Builder.

Records every deployment-package download so we can answer:
  * How many times was each vertical (environment) downloaded?
  * With what options (region, prefix, auto-run, Purview, ...)?
  * How many unique users over time?

Two sinks, both best-effort and non-blocking for the request:
  1. Local JSONL file (always on) — survives with zero Azure config, handy for
     local dev and as a durable backstop.
  2. Application Insights custom events (when configured) — the centralized
     adoption store. Lands in the `customEvents` table so unique-user and
     time-series queries are trivial in KQL.

Telemetry must NEVER break a download. Every failure is swallowed.
"""
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# App Insights is optional. Import lazily / defensively so the app runs with no
# Azure packages installed or no connection string configured.
_EVENT_NAME = "PackageDownloaded"

# Env var Azure Monitor uses by convention.
_CONN_STR_ENV = "APPLICATIONINSIGHTS_CONNECTION_STRING"

# Where the local JSONL backstop lives. Overridable for tests / container FS.
_LOCAL_LOG_ENV = "TELEMETRY_LOCAL_LOG"
_DEFAULT_LOCAL_LOG = Path(__file__).resolve().parent.parent.parent / "data" / "telemetry.jsonl"


class Telemetry:
    """Process-wide telemetry recorder. Construct once at startup."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._local_log = Path(os.environ.get(_LOCAL_LOG_ENV, str(_DEFAULT_LOCAL_LOG)))
        self._track_event = None  # callable(name, properties) when AI is wired
        self._ai_enabled = False
        self._init_app_insights()

    def _init_app_insights(self) -> None:
        conn = os.environ.get(_CONN_STR_ENV, "").strip()
        if not conn:
            return
        try:
            from azure.monitor.opentelemetry import configure_azure_monitor
            from azure.monitor.events.extension import track_event

            # Disable the noisy auto-instrumentation; we only want custom events.
            configure_azure_monitor(
                connection_string=conn,
                logging_formatter=None,
                enable_live_metrics=False,
            )
            self._track_event = track_event
            self._ai_enabled = True
        except Exception:
            # Missing packages, bad connection string, etc. — fall back to JSONL.
            self._track_event = None
            self._ai_enabled = False

    @property
    def app_insights_enabled(self) -> bool:
        return self._ai_enabled

    def record_download(
        self,
        *,
        vertical_id: str,
        user_id: str,
        properties: Optional[dict] = None,
    ) -> None:
        """Record a single package download. Best-effort, never raises."""
        props = {k: ("" if v is None else str(v)) for k, v in (properties or {}).items()}
        props["vertical"] = vertical_id
        props["user_id"] = user_id
        event = {
            "event": _EVENT_NAME,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **props,
        }
        self._write_local(event)
        self._emit_app_insights(props)

    def _write_local(self, event: dict) -> None:
        try:
            with self._lock:
                self._local_log.parent.mkdir(parents=True, exist_ok=True)
                with self._local_log.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps(event) + "\n")
        except Exception:
            pass

    def _emit_app_insights(self, props: dict) -> None:
        if not self._track_event:
            return
        try:
            self._track_event(_EVENT_NAME, props)
        except Exception:
            pass


# Module-level singleton, created at import time.
telemetry = Telemetry()
