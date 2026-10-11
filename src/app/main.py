import socket
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import FileResponse, JSONResponse

from . import db
from .schemas import TaskIn, TaskOut

INDEX_HTML = Path(__file__).parent / "static" / "index.html"


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.pool.open(wait=True, timeout=30)
    yield
    db.pool.close()


app = FastAPI(title="Gestion de tâches", version="1.0.0", lifespan=lifespan)


@app.get("/", include_in_schema=False)
def index():
    return FileResponse(INDEX_HTML)


@app.get("/health")
def health():
    if db.db_ping():
        return {"status": "ok", "db": "ok"}
    return JSONResponse({"status": "degraded", "db": "ko"}, status_code=503)


@app.get("/api/info")
def info():
    return {
        "app_hostname": socket.gethostname(),
        "db_host": db.DB_HOST,
        "postgres_version": db.db_server_version(),
    }


@app.get("/api/tasks", response_model=list[TaskOut])
def list_tasks(status: Literal["all", "todo", "done"] = "all"):
    return db.list_tasks(status)


@app.post("/api/tasks", response_model=TaskOut, status_code=201)
def create_task(task: TaskIn):
    return db.create_task(task.title)


@app.patch("/api/tasks/{task_id}/done", response_model=TaskOut)
def mark_done(task_id: int):
    task = db.mark_done(task_id)
    if task is None:
        raise HTTPException(status_code=404, detail="Tâche introuvable")
    return task


@app.delete("/api/tasks/{task_id}", status_code=204)
def delete_task(task_id: int):
    if not db.delete_task(task_id):
        raise HTTPException(status_code=404, detail="Tâche introuvable")
    return Response(status_code=204)
