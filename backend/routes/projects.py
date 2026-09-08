"""Project endpoints — CRUD and thread assignment."""

import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["projects"])


class ProjectCreateRequest(BaseModel):
    name: str


class ProjectRenameRequest(BaseModel):
    name: str


class ProjectAssignRequest(BaseModel):
    project_id: str


def register_project_routes(app_router, get_tenant_id, verify_infrastructure_access, limiter, config):
    """Register all project routes with injected auth dependencies."""

    @app_router.get("/api/projects")
    async def list_projects(request: Request, tenant_id: str = Depends(get_tenant_id)):
        projects_dict = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:projects")
        return {"projects": [{"id": pid.decode("utf-8"), "name": pname.decode("utf-8")} for pid, pname in projects_dict.items()]}

    @app_router.post("/api/projects")
    async def create_project(payload: ProjectCreateRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
        project_id = str(uuid.uuid4())
        await request.app.state.redis.hset(f"tenant:{tenant_id}:projects", project_id, payload.name)
        return {"id": project_id, "name": payload.name}

    @app_router.put("/api/projects/{project_id}")
    async def rename_project(project_id: str, payload: ProjectRenameRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
        if not await request.app.state.redis.hexists(f"tenant:{tenant_id}:projects", project_id):
            raise HTTPException(status_code=404, detail="Project not found")
        await request.app.state.redis.hset(f"tenant:{tenant_id}:projects", project_id, payload.name)
        return {"status": "ok"}

    @app_router.delete("/api/projects/{project_id}")
    async def delete_project(project_id: str, request: Request, tenant_id: str = Depends(get_tenant_id)):
        if not await request.app.state.redis.hexists(f"tenant:{tenant_id}:projects", project_id):
            raise HTTPException(status_code=404, detail="Project not found")
        await request.app.state.redis.hdel(f"tenant:{tenant_id}:projects", project_id)
        thread_projects = await request.app.state.redis.hgetall(f"tenant:{tenant_id}:thread_projects")
        for tid, pid in thread_projects.items():
            if pid.decode("utf-8") == project_id:
                await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", tid.decode("utf-8"))
        return {"status": "ok"}

    @app_router.post("/api/chat/threads/{thread_id}/project")
    async def assign_project(thread_id: str, payload: ProjectAssignRequest, request: Request, tenant_id: str = Depends(get_tenant_id)):
        if not payload.project_id:
            await request.app.state.redis.hdel(f"tenant:{tenant_id}:thread_projects", thread_id)
        else:
            if not await request.app.state.redis.hexists(f"tenant:{tenant_id}:projects", payload.project_id):
                raise HTTPException(status_code=404, detail="Project not found")
            await request.app.state.redis.hset(f"tenant:{tenant_id}:thread_projects", thread_id, payload.project_id)
        return {"status": "ok"}
