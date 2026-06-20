"""Loads available verticals from the /verticals directory.

Each vertical has a `vertical.yaml` manifest describing its metadata,
required Azure resources, and what's included in the deployment package.
"""
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml


@dataclass
class Vertical:
    id: str
    name: str
    description: str
    status: str  # "available", "in-progress", "planned"
    # Whether a downloadable deployment package can be built yet. A vertical can
    # be "in-progress" (visible, actively being built) while its deploy package
    # isn't published — the recipe is still being validated by hand.
    deployable: bool = True
    preview_note: str = ""
    azure_services: list[str] = field(default_factory=list)
    executive_kpis: list[str] = field(default_factory=list)
    # Optional per-vertical deployment flows. When present, the detail page
    # presents each flow as a distinct path with its own accurate
    # "what gets deployed" list instead of a single combined azure_services list.
    flows: list[dict] = field(default_factory=list)
    root_path: Optional[Path] = None


class VerticalRegistry:
    def __init__(self, verticals_dir: Path):
        self.verticals_dir = verticals_dir
        self._verticals: dict[str, Vertical] = {}
        self._load()

    def _load(self):
        if not self.verticals_dir.exists():
            return
        for child in sorted(self.verticals_dir.iterdir()):
            if not child.is_dir():
                continue
            manifest = child / "vertical.yaml"
            if not manifest.exists():
                continue
            data = yaml.safe_load(manifest.read_text(encoding="utf-8"))
            vertical = Vertical(
                id=data["id"],
                name=data["name"],
                description=data["description"],
                status=data.get("status", "planned"),
                deployable=data.get("deployable", True),
                preview_note=data.get("preview_note", ""),
                azure_services=data.get("azure_services", []),
                executive_kpis=data.get("executive_kpis", []),
                flows=data.get("flows", []),
                root_path=child,
            )
            self._verticals[vertical.id] = vertical

    def list_verticals(self) -> list[Vertical]:
        return list(self._verticals.values())

    def get(self, vertical_id: str) -> Optional[Vertical]:
        return self._verticals.get(vertical_id)
