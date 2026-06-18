#!/usr/bin/env python3
"""Maintainer tool — one-time normalisation of the FHIR seed NDJSON.

Synthea writes some references as **conditional references**, e.g.
``"reference": "Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|9999963991"``.
Bulk ``$import`` stores those verbatim, but a per-resource REST ``PUT`` (what
``seed_fhir.py`` uses) tries to *resolve* the conditional reference at write
time and rejects it with HTTP 400 whenever it resolves to zero or many matches.

This script rewrites every conditional reference into a literal ``Type/id``
reference so the seed loads cleanly via plain PUT:

* If the referenced resource exists in the seed (matched by identifier), the
  reference becomes its real ``Type/id``.
* If it does not (a handful of Practitioner NPIs that Synthea references but
  never emits — dangling even in the source data), the reference becomes a
  deterministic ``Type/<uuid5>``. Azure FHIR allows literal references to
  resources that do not exist, so the PUT succeeds and analytics are unaffected.

Run it from the repo root after (re)generating the seed:
    python verticals/healthcare/data/_normalize_seed.py
It rewrites the NDJSON files in place and prints a summary. Idempotent.
"""
from __future__ import annotations

import glob
import json
import re
import uuid
from pathlib import Path

SEED_DIR = Path(__file__).parent / "fhir-seed"
_COND_RE = re.compile(r"^([A-Za-z]+)\?(.+)$")
_NS = uuid.uuid5(uuid.NAMESPACE_URL, "fabric-demo-generator/healthcare/fhir-seed")


def _build_identifier_index(resources: list[dict]) -> dict[tuple[str, str], str]:
    """(resourceType, 'system|value') -> 'resourceType/id' for every identifier."""
    index: dict[tuple[str, str], str] = {}
    for res in resources:
        rtype = res.get("resourceType")
        rid = res.get("id")
        if not rtype or not rid:
            continue
        literal = f"{rtype}/{rid}"
        for ident in res.get("identifier", []) or []:
            system = ident.get("system")
            value = ident.get("value")
            if value is None:
                continue
            index[(rtype, f"{system}|{value}")] = literal
            index.setdefault((rtype, value), literal)  # value-only fallback
    return index


def _resolve(cond: str, index: dict[tuple[str, str], str], stats: dict[str, int]) -> str | None:
    """Turn 'Type?identifier=system|value' into 'Type/id'. Returns None if not
    a conditional reference."""
    m = _COND_RE.match(cond)
    if not m:
        return None
    rtype, query = m.group(1), m.group(2)
    token = None
    for part in query.split("&"):
        if part.startswith("identifier="):
            token = part[len("identifier="):]
            break
    if token is None:
        # Conditional reference on something other than identifier — synthesize.
        stats["synthesized"] += 1
        return f"{rtype}/{uuid.uuid5(_NS, cond)}"
    hit = index.get((rtype, token)) or index.get((rtype, token.split("|")[-1]))
    if hit:
        stats["resolved"] += 1
        return hit
    stats["synthesized"] += 1
    return f"{rtype}/{uuid.uuid5(_NS, f'{rtype}|{token}')}"


def _rewrite(node, index, stats) -> None:
    """Recursively rewrite conditional 'reference' strings in place."""
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "reference" and isinstance(val, str):
                new = _resolve(val, index, stats)
                if new is not None:
                    node[key] = new
            else:
                _rewrite(val, index, stats)
    elif isinstance(node, list):
        for item in node:
            _rewrite(item, index, stats)


def main() -> int:
    files = sorted(glob.glob(str(SEED_DIR / "*.ndjson")))
    if not files:
        print(f"no NDJSON found in {SEED_DIR}")
        return 1

    # Pass 1: load everything and index identifiers.
    per_file: dict[str, list[dict]] = {}
    all_resources: list[dict] = []
    for f in files:
        rows = [json.loads(line) for line in Path(f).read_text(encoding="utf-8").splitlines() if line.strip()]
        per_file[f] = rows
        all_resources.extend(rows)
    index = _build_identifier_index(all_resources)

    # Pass 2: rewrite conditional references and write back.
    stats = {"resolved": 0, "synthesized": 0}
    for f, rows in per_file.items():
        for res in rows:
            _rewrite(res, index, stats)
        Path(f).write_text(
            "\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows) + "\n",
            encoding="utf-8",
        )

    print(f"resources indexed     : {len(all_resources)}")
    print(f"conditional refs fixed: {stats['resolved'] + stats['synthesized']}")
    print(f"  -> resolved to seed : {stats['resolved']}")
    print(f"  -> synthesized id   : {stats['synthesized']} (referenced resource not in seed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
