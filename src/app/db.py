"""Accès à PostgreSQL : configuration lue dans l'environnement, pool de connexions, requêtes SQL."""
import os

import psycopg
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


def _required(name: str) -> str:
    # Variable obligatoire : on échoue au démarrage avec un message clair plutôt que de deviner.
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} manquant")
    return value


# Nom d'hôte de la base, fourni par compose.yaml (nom du service "db").
# Volontairement SANS valeur par défaut : jamais d'adresse IP ni d'hôte local codé en dur.
DB_HOST = _required("DB_HOST")
DB_PORT = os.environ.get("DB_PORT", "5432")

# make_conninfo construit la chaîne "host=... password=..." en échappant les valeurs
# (un mot de passe contenant des espaces ou des quotes ne casse pas la connexion).
_conninfo = make_conninfo(
    host=DB_HOST,
    port=DB_PORT,
    dbname=_required("DB_NAME"),
    user=_required("DB_USER"),
    password=_required("DB_PASSWORD"),
)

# Pool réduit (1 à 4 connexions) : peu de mémoire côté app et côté PostgreSQL (max_connections=20).
# open=False : le pool est ouvert au démarrage de l'app (lifespan), pas à l'import du module.
# check : vérifie chaque connexion avant de la prêter (survit à un redémarrage de la base).
# dict_row : chaque ligne devient un dict, directement sérialisable en JSON.
pool = ConnectionPool(
    _conninfo,
    min_size=1,
    max_size=4,
    open=False,
    check=ConnectionPool.check_connection,
    kwargs={"row_factory": dict_row},
)

# Filtre de statut -> valeur de la colonne done (None = pas de filtre)
_STATUS_FILTER = {"all": None, "todo": False, "done": True}

# Toutes les requêtes sont paramétrées (%s) : les valeurs sont envoyées séparément du SQL,
# aucune injection SQL possible. "with pool.connection()" valide la transaction en sortie.


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
    # Idempotent : COALESCE conserve la date de la première réalisation.
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
    # Utilisé par /health : la base répond-elle à SELECT 1 en moins de 2 s ?
    try:
        with pool.connection(timeout=2) as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error:
        return False


def db_server_version() -> str:
    with pool.connection() as conn:
        return conn.execute("SHOW server_version").fetchone()["server_version"]
