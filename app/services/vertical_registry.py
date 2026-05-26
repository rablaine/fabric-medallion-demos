"""Loads available verticals from the /verticals directory.

Each vertical has a `vertical.yaml` manifest describing its metadata,
required Azure resources, scale options, and what's included in the
deployment package.
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
    azure_services: list[str] = field(default_factory=list)
    executive_kpis: list[str] = field(default_factory=list)
    scale_options: list[str] = field(default_factory=lambda: ["small", "medium", "large"])
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
                azure_services=data.get("azure_services", []),
                executive_kpis=data.get("executive_kpis", []),
                scale_options=data.get("scale_options", ["small", "medium", "large"]),
                root_path=child,
            )
            self._verticals[vertical.id] = vertical

    def list_verticals(self) -> list[Vertical]:
        return list(self._verticals.values())

    def get(self, vertical_id: str) -> Optional[Vertical]:
        return self._verticals.get(vertical_id)
