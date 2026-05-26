"""Deployment package generation endpoints."""
from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import FileResponse

from app.services.package_builder import PackageBuilder

router = APIRouter(prefix="/deploy", tags=["deployment"])


@router.post("/{vertical_id}/package")
async def generate_package(
    request: Request,
    vertical_id: str,
    resource_group: str = Form(...),
    location: str = Form("centralus"),
    scale: str = Form("small"),
    resource_prefix: str = Form("contoso"),
):
    """Generate a downloadable deployment package for the selected vertical."""
    registry = request.app.state.registry
    vertical = registry.get(vertical_id)
    if not vertical:
        raise HTTPException(status_code=404, detail=f"Vertical '{vertical_id}' not found")

    builder = PackageBuilder(vertical=vertical)
    package_path = builder.build(
        config={
            "resource_group": resource_group,
            "location": location,
            "scale": scale,
            "resource_prefix": resource_prefix,
        }
    )
    return FileResponse(
        path=package_path,
        filename=f"contoso-{vertical_id}-deployment.zip",
        media_type="application/zip",
    )
