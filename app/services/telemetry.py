"""Adoption telemetry for the Fabric Data Estate Builder.

Records every deployment-package download so we can answer:
  * How many times was each vertical (environment) downloaded?
  * With what options (region, prefix, auto-run, Purview, ...)?
  * How many unique users over time?

This is **opt-in**. Nothing is emitted unless `TELEMETRY_ENABLED=true`, so a dev
environment stays silent by default — no Application Insights, no local file.
Production sets `TELEMETRY_ENABLED=true` (plus the connection string) as an app
setting.

When enabled, two sinks, both best-effort and non-blocking for the request:
  1. Local JSONL file — a durable backstop, also handy for inspecting events.
  2. Application Insights custom events (when a connection string is set) — the
     centralized adoption store. Lands in the `customEvents` table so
     unique-user and time-series queries are trivial in KQL. Every event is
     tagged with a cloud role name so this app is distinguishable from other
     apps that share the same Application Insights resource.

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

# Master switch. Telemetry is OFF unless this is explicitly truthy, so dev
# environments never emit anything by default.
_ENABLED_ENV = "TELEMETRY_ENABLED"
_TRUTHY = {"1", "true", "yes", "on"}

# Env var Azure Monitor uses by convention.
_CONN_STR_ENV = "APPLICATIONINSIGHTS_CONNECTION_STRING"

# Cloud role name so events are attributable to THIS app in a shared App
# Insights resource (the centralized "adoption across my apps" store).
_ROLE_NAME_ENV = "TELEMETRY_ROLE_NAME"
_DEFAULT_ROLE_NAME = "fabric-data-estate-builder"

# Where the local JSONL backstop lives. Overridable for tests / container FS.
_LOCAL_LOG_ENV = "TELEMETRY_LOCAL_LOG"
_DEFAULT_LOCAL_LOG = Path(__file__).resolve().parent.parent.parent / "data" / "telemetry.jsonl"


class Telemetry:
    """Process-wide telemetry recorder. Construct once at startup."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._enabled = os.environ.get(_ENABLED_ENV, "").strip().lower() in _TRUTHY
        self._role_name = os.environ.get(_ROLE_NAME_ENV, _DEFAULT_ROLE_NAME).strip() or _DEFAULT_ROLE_NAME
        self._local_log = Path(os.environ.get(_LOCAL_LOG_ENV, str(_DEFAULT_LOCAL_LOG)))
        self._track_event = None  # callable(name, properties) when AI is wired
        self._ai_enabled = False
        if self._enabled:
            self._init_app_insights()

    def _init_app_insights(self) -> None:
        conn = os.environ.get(_CONN_STR_ENV, "").strip()
        if not conn:
            return
        try:
            # Set the cloud role name (App Insights `cloud_RoleName`) so this
            # app's events stand apart in a shared resource. OpenTelemetry maps
            # service.name -> cloud_RoleName; don't clobber an explicit value.
            os.environ.setdefault("OTEL_SERVICE_NAME", self._role_name)

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
    def enabled(self) -> bool:
        return self._enabled

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
        """Record a single package download. Best-effort, never raises.

        No-op unless telemetry is enabled (`TELEMETRY_ENABLED`), so dev never
        emits anything — neither to App Insights nor to the local file.
        """
        if not self._enabled:
            return
        props = {k: ("" if v is None else str(v)) for k, v in (properties or {}).items()}
        props["vertical"] = vertical_id
        props["user_id"] = user_id
        props["app"] = self._role_name
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
