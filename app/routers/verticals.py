"""Vertical browsing and configuration endpoints."""
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.templating import Jinja2Templates

BASE_DIR = Path(__file__).resolve().parent.parent
DOCS_DIR = BASE_DIR.parent / "docs"
templates = Jinja2Templates(directory=BASE_DIR / "templates")

router = APIRouter(prefix="/verticals", tags=["verticals"])


def _solutions_deck_path(vertical_id: str) -> Path:
    """Path to a vertical's customer solutions deck, if one has been authored."""
    return DOCS_DIR / f"{vertical_id}-solutions-customer-deck.html"


@router.get("/{vertical_id}", response_class=HTMLResponse)
async def vertical_detail(request: Request, vertical_id: str):
    """Show details for a single vertical."""
    registry = request.app.state.registry
    vertical = registry.get(vertical_id)
    if not vertical:
        raise HTTPException(status_code=404, detail=f"Vertical '{vertical_id}' not found")
    return templates.TemplateResponse(
        request,
        "vertical_detail.html",
        {"vertical": vertical, "has_solutions_deck": _solutions_deck_path(vertical_id).exists()},
    )


@router.get("/{vertical_id}/solutions", response_class=HTMLResponse)
async def vertical_solutions(request: Request, vertical_id: str):
    """Serve the customer-facing solutions walkthrough deck for a vertical."""
    registry = request.app.state.registry
    vertical = registry.get(vertical_id)
    if not vertical:
        raise HTTPException(status_code=404, detail=f"Vertical '{vertical_id}' not found")
    deck = _solutions_deck_path(vertical_id)
    if not deck.exists():
        raise HTTPException(status_code=404, detail="No solutions deck for this vertical.")
    return FileResponse(deck, media_type="text/html")


@router.get("/{vertical_id}/configure", response_class=HTMLResponse)
async def configure_vertical(request: Request, vertical_id: str, flow: str = "fhir"):
    """Configuration form for deploying a vertical.

    `flow` carries the deployment flow chosen on the detail page (healthcare:
    'fhir' or 'sampledata') so the form opens with that option pre-selected.
    """
    registry = request.app.state.registry
    vertical = registry.get(vertical_id)
    if not vertical:
        raise HTTPException(status_code=404, detail=f"Vertical '{vertical_id}' not found")
    if not vertical.deployable:
        raise HTTPException(
            status_code=409,
            detail=f"Vertical '{vertical_id}' is a preview and not deployable yet.",
        )
    selected_flow = "sampledata" if flow == "sampledata" else "fhir"
    return templates.TemplateResponse(
        request,
        "configure.html",
        {"vertical": vertical, "selected_flow": selected_flow},
    )
