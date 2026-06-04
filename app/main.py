"""Fabric Data Estate Builder.

FastAPI entry point. Serves the web UI and exposes endpoints for
generating deployment packages for each industry vertical.
"""
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.routers import verticals, deployment
from app.services.vertical_registry import VerticalRegistry

BASE_DIR = Path(__file__).resolve().parent

app = FastAPI(
    title="Fabric Data Estate Builder",
    description="Deploy an end-to-end Microsoft Fabric data estate for an industry vertical.",
    version="0.1.0",
)

app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")

# Load vertical registry at startup
registry = VerticalRegistry(verticals_dir=BASE_DIR.parent / "verticals")
app.state.registry = registry

app.include_router(verticals.router)
app.include_router(deployment.router)


@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Landing page.

    When only one deployable vertical exists, render it directly (no picker).
    Otherwise render the vertical grid.
    """
    verticals_list = registry.list_verticals()
    deployable = [v for v in verticals_list if v.status in ("available", "in-progress")]
    if len(deployable) == 1:
        return templates.TemplateResponse(
            request,
            "vertical_detail.html",
            {"vertical": deployable[0], "single_vertical": True},
        )
    return templates.TemplateResponse(
        request,
        "index.html",
        {"verticals": verticals_list},
    )


@app.get("/health")
async def health():
    return {"status": "ok", "verticals_loaded": len(registry.list_verticals())}
