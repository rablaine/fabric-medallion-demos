#!/usr/bin/env python3
"""Seed an Azure Health Data Services FHIR R4 service with the pre-generated
demo dataset (Synthea synthetic patients, clinical resources only).

The data ships *with* this script as NDJSON files in ``fhir-seed/`` — one file
per FHIR resource type, one JSON resource per line. End users do NOT need
Synthea, Java, a storage account, or the ``$import`` operation: this script
reads the bundled NDJSON and PUTs each resource straight to the FHIR REST API.

Auth uses your existing Azure CLI login. You must have the **FHIR Data
Contributor** role on the target FHIR service.

Usage:
    az login
    python seed_fhir.py --fhir-url https://<workspace>-<fhir>.fhir.azurehealthcareapis.com

Common options:
    --workers N         parallel PUTs (default 8)
    --only TYPE[,TYPE]  seed only these resource types (e.g. Patient,Observation)
    --seed-dir PATH     override the NDJSON folder (default: ./fhir-seed)
    --dry-run           parse + count only; no writes
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# References between Synthea resources (Encounter -> Patient, Observation ->
# Encounter, ...) are PUT by id, and Azure FHIR does not enforce referential
# integrity by default, so load order does not matter. We still load the
# "anchor" types first so a partial/interrupted run is still browsable.
_PREFERRED_ORDER = [
    "Organization",
    "Location",
    "Practitioner",
    "Patient",
    "Encounter",
    "Condition",
    "Observation",
    "Procedure",
    "Immunization",
    "MedicationRequest",
    "MedicationAdministration",
    "DiagnosticReport",
    "CarePlan",
    "CareTeam",
    "AllergyIntolerance",
    "Device",
    "ImagingStudy",
    "SupplyDelivery",
]

_MAX_RETRIES = 6
_TOKEN_REFRESH_SKEW = 300  # refresh when < 5 min of token life remains


class TokenProvider:
    """Fetches and caches an AAD bearer token for the FHIR audience via the
    Azure CLI, refreshing it before expiry. Thread-safe."""

    def __init__(self, resource: str) -> None:
        self._resource = resource
        self._lock = threading.Lock()
        self._token = ""
        self._expires_at = 0.0

    def _fetch(self) -> None:
        cmd = [
            "az", "account", "get-access-token",
            "--resource", self._resource, "-o", "json",
        ]
        try:
            out = subprocess.run(
                cmd, capture_output=True, text=True, check=True,
                shell=(os.name == "nt"),  # az is a .cmd shim on Windows
            ).stdout
        except subprocess.CalledProcessError as exc:
            sys.exit(
                "Failed to get an access token via 'az'. Run 'az login' first.\n"
                f"  {exc.stderr.strip()}"
            )
        data = json.loads(out)
        self._token = data["accessToken"]
        # expires_on is epoch seconds; expiresOn is a local datetime string.
        self._expires_at = float(data.get("expires_on") or (time.time() + 3000))

    def get(self, force: bool = False) -> str:
        with self._lock:
            if force or not self._token or time.time() > self._expires_at - _TOKEN_REFRESH_SKEW:
                self._fetch()
            return self._token


class Counters:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.ok = 0
        self.failed = 0
        self.errors: dict[str, str] = {}  # resourceType/id -> message (first few)

    def record_ok(self) -> None:
        with self._lock:
            self.ok += 1

    def record_fail(self, ref: str, msg: str) -> None:
        with self._lock:
            self.failed += 1
            if len(self.errors) < 20:
                self.errors[ref] = msg


def _iter_resources(seed_dir: Path, only: set[str] | None):
    for path in sorted(seed_dir.glob("*.ndjson")):
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                res = json.loads(line)
                rtype = res.get("resourceType")
                rid = res.get("id")
                if not rtype or not rid:
                    continue
                if only and rtype not in only:
                    continue
                yield rtype, rid, line


def _put_one(base: str, tokens: TokenProvider, rtype: str, rid: str, body: str) -> tuple[bool, str]:
    url = f"{base}/{rtype}/{rid}"
    data = body.encode("utf-8")
    backoff = 1.0
    for attempt in range(1, _MAX_RETRIES + 1):
        req = urllib.request.Request(url, data=data, method="PUT")
        req.add_header("Authorization", f"Bearer {tokens.get()}")
        req.add_header("Content-Type", "application/fhir+json")
        req.add_header("Accept", "application/fhir+json")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                if resp.status in (200, 201):
                    return True, ""
                return False, f"HTTP {resp.status}"
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                tokens.get(force=True)
                continue
            if exc.code == 429 or 500 <= exc.code < 600:
                retry_after = exc.headers.get("Retry-After")
                delay = float(retry_after) if retry_after and retry_after.isdigit() else backoff
                time.sleep(delay)
                backoff = min(backoff * 2, 30)
                continue
            detail = exc.read().decode("utf-8", "replace")[:300]
            return False, f"HTTP {exc.code}: {detail}"
        except urllib.error.URLError as exc:
            time.sleep(backoff)
            backoff = min(backoff * 2, 30)
            last = str(exc.reason)
    return False, f"gave up after {_MAX_RETRIES} retries ({last if 'last' in dir() else 'rate limited'})"


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed an AHDS FHIR R4 service with the demo dataset.")
    ap.add_argument("--fhir-url", default=os.environ.get("FHIR_URL", ""),
                    help="FHIR service base URL (or set FHIR_URL).")
    ap.add_argument("--seed-dir", default=str(Path(__file__).parent / "fhir-seed"),
                    help="Folder of *.ndjson seed files.")
    ap.add_argument("--workers", type=int, default=8, help="Parallel PUT workers.")
    ap.add_argument("--only", default="", help="Comma-separated resource types to seed.")
    ap.add_argument("--dry-run", action="store_true", help="Parse and count only; no writes.")
    args = ap.parse_args()

    base = args.fhir_url.strip().rstrip("/")
    if not base:
        ap.error("--fhir-url (or FHIR_URL env var) is required.")
    seed_dir = Path(args.seed_dir)
    if not seed_dir.is_dir():
        ap.error(f"seed dir not found: {seed_dir}")
    only = {t.strip() for t in args.only.split(",") if t.strip()} or None

    resources = list(_iter_resources(seed_dir, only))
    by_type: dict[str, int] = {}
    for rtype, _rid, _b in resources:
        by_type[rtype] = by_type.get(rtype, 0) + 1
    ordered = sorted(by_type, key=lambda t: (_PREFERRED_ORDER.index(t) if t in _PREFERRED_ORDER else 999, t))
    print(f"Seed dir : {seed_dir}")
    print(f"Target   : {base}")
    print(f"Resources: {len(resources)} across {len(by_type)} types")
    for t in ordered:
        print(f"   {t:<26} {by_type[t]:>6}")
    if args.dry_run:
        print("\n[dry-run] no resources written.")
        return 0

    tokens = TokenProvider(base)
    tokens.get()  # fail fast if not logged in
    counters = Counters()
    started = time.time()
    print(f"\nWriting with {args.workers} workers ...")

    def work(item):
        rtype, rid, body = item
        ok, msg = _put_one(base, tokens, rtype, rid, body)
        if ok:
            counters.record_ok()
        else:
            counters.record_fail(f"{rtype}/{rid}", msg)
        done = counters.ok + counters.failed
        if done % 250 == 0:
            print(f"   {done}/{len(resources)}  ok={counters.ok} failed={counters.failed}", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(work, item) for item in resources]
        for _ in as_completed(futures):
            pass

    elapsed = time.time() - started
    print(f"\nDone in {elapsed:.0f}s — ok={counters.ok} failed={counters.failed}")
    if counters.errors:
        print("First errors:")
        for ref, msg in counters.errors.items():
            print(f"   {ref}: {msg}")
    return 1 if counters.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
