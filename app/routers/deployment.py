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
    resource_prefix: str = Form("contoso"),
    auto_run_initial_load: str = Form(None),
    deploy_purview: str = Form(None),
):
    """Generate a downloadable deployment package for the selected vertical."""
    registry = request.app.state.registry
    vertical = registry.get(vertical_id)
    if not vertical:
        raise HTTPException(status_code=404, detail=f"Vertical '{vertical_id}' not found")

    deploy_purview_flag = deploy_purview is not None
    # Purview's Fabric scan needs populated lakehouses, so a Purview deploy
    # implies the medallion load must run. Mirror the UI's forcing here so a
    # form posted without JS still produces a coherent package.
    auto_run_flag = (auto_run_initial_load is not None) or deploy_purview_flag

    builder = PackageBuilder(vertical=vertical)
    package_path = builder.build(
        config={
            "resource_group": resource_group,
            "location": location,
            "resource_prefix": resource_prefix,
            "auto_run_initial_load": auto_run_flag,
            "deploy_purview": deploy_purview_flag,
        }
    )
    return FileResponse(
        path=package_path,
        filename=f"contoso-{vertical_id}-deployment.zip",
        media_type="application/zip",
    )
