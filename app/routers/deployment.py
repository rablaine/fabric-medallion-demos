"""Deployment package generation endpoints."""
import uuid

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import FileResponse

from app.services.package_builder import PackageBuilder
from app.services.telemetry import telemetry

router = APIRouter(prefix="/deploy", tags=["deployment"])

# Cookie that carries an anonymous, stable per-browser id so adoption telemetry
# can count unique users over time without collecting anything identifying.
_UID_COOKIE = "fdeb_uid"
_UID_MAX_AGE = 60 * 60 * 24 * 365 * 2  # 2 years


@router.post("/{vertical_id}/package")
async def generate_package(
    request: Request,
    vertical_id: str,
    resource_group: str = Form(...),
    location: str = Form("centralus"),
    resource_prefix: str = Form("contoso"),
    auto_run_initial_load: str = Form(None),
    deploy_purview: str = Form(None),
    deploy_mode: str = Form("fhir"),
    run_pipelines_on_deploy: str = Form(None),
):
    """Generate a downloadable deployment package for the selected vertical."""
    registry = request.app.state.registry
    vertical = registry.get(vertical_id)
    if not vertical:
        raise HTTPException(status_code=404, detail=f"Vertical '{vertical_id}' not found")
    if not vertical.deployable:
        raise HTTPException(
            status_code=409,
            detail=f"Vertical '{vertical_id}' is a preview and not deployable yet.",
        )

    deploy_purview_flag = deploy_purview is not None
    # Purview's Fabric scan needs populated lakehouses, so a Purview deploy
    # implies the medallion load must run. Mirror the UI's forcing here so a
    # form posted without JS still produces a coherent package.
    auto_run_flag = (auto_run_initial_load is not None) or deploy_purview_flag

    # Deployment flow selector. Only the healthcare vertical offers an assisted
    # sample-data flow; everything else (and any unknown value) is the default.
    deploy_mode_val = "sampledata" if deploy_mode == "sampledata" else "fhir"

    # "Run pipelines once deployed" checkbox (healthcare, both flows). It is
    # checked by default, so a posted form omits it only when the user unchecked
    # it. Absent -> False (stop after staging/wiring); present -> True.
    run_pipelines_flag = run_pipelines_on_deploy is not None

    builder = PackageBuilder(vertical=vertical)
    package_path = builder.build(
        config={
            "resource_group": resource_group,
            "location": location,
            "resource_prefix": resource_prefix,
            "auto_run_initial_load": auto_run_flag,
            "deploy_purview": deploy_purview_flag,
            "deploy_mode": deploy_mode_val,
            "run_pipelines_on_deploy": run_pipelines_flag,
        }
    )

    # Stable anonymous user id (set on first download if missing).
    user_id = request.cookies.get(_UID_COOKIE)
    new_user = user_id is None
    if new_user:
        user_id = uuid.uuid4().hex

    telemetry.record_download(
        vertical_id=vertical_id,
        user_id=user_id,
        properties={
            "location": location,
            "resource_prefix": resource_prefix,
            "auto_run_initial_load": auto_run_flag,
            "deploy_purview": deploy_purview_flag,
            "deploy_mode": deploy_mode_val,
        },
    )

    response = FileResponse(
        path=package_path,
        filename=f"contoso-{vertical_id}-deployment.zip",
        media_type="application/zip",
    )
    if new_user:
        response.set_cookie(
            _UID_COOKIE,
            user_id,
            max_age=_UID_MAX_AGE,
            httponly=True,
            samesite="lax",
        )
    return response
