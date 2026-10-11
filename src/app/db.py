import os

import psycopg
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} manquant")
    return value


# Pas de valeur par défaut : l'hôte de la base vient de compose (nom du service "db")
DB_HOST = _required("DB_HOST")
DB_PORT = os.environ.get("DB_PORT", "5432")

_conninfo = make_conninfo(
    host=DB_HOST,
    port=DB_PORT,
    dbname=_required("DB_NAME"),
    user=_required("DB_USER"),
    password=_required("DB_PASSWORD"),
)

pool = ConnectionPool(
    _conninfo,
    min_size=1,
    max_size=4,
    open=False,
    check=ConnectionPool.check_connection,
    kwargs={"row_factory": dict_row},
)

_STATUS_FILTER = {"all": None, "todo": False, "done": True}


def list_tasks(status: str) -> list[dict]:
    done = _STATUS_FILTER[status]
    with pool.connection() as conn:
        return conn.execute(
            "SELECT * FROM tasks WHERE %s::boolean IS NULL OR done = %s "
            "ORDER BY done ASC, created_at DESC",
            (done, done),
        ).fetchall()


def create_task(title: str) -> dict:
    with pool.connection() as conn:
        return conn.execute(
            "INSERT INTO tasks (title) VALUES (%s) RETURNING *", (title,)
        ).fetchone()


def mark_done(task_id: int) -> dict | None:
    with pool.connection() as conn:
        return conn.execute(
            "UPDATE tasks SET done = TRUE, done_at = COALESCE(done_at, now()) "
            "WHERE id = %s RETURNING *",
            (task_id,),
        ).fetchone()


def delete_task(task_id: int) -> bool:
    with pool.connection() as conn:
        return conn.execute("DELETE FROM tasks WHERE id = %s", (task_id,)).rowcount == 1


def db_ping() -> bool:
    try:
        with pool.connection(timeout=2) as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error:
        return False


def db_server_version() -> str:
    with pool.connection() as conn:
        return conn.execute("SHOW server_version").fetchone()["server_version"]
