-- Schéma de la base "tâches".
-- Ce fichier est monté dans /docker-entrypoint-initdb.d/ du conteneur db.
-- L'entrypoint de l'image officielle PostgreSQL ne l'exécute QUE si le répertoire
-- de données ($PGDATA) est vide, c'est-à-dire au tout premier démarrage avec un volume neuf.
-- Ensuite, le schéma et les données vivent dans le volume nommé pgdata :
--   docker compose down puis up : volume conservé, ce script n'est PAS rejoué ;
--   docker compose down -v puis up : volume supprimé, cluster recréé, ce script est rejoué.
-- C'est la seule source de vérité du schéma : l'application ne crée aucune table.

CREATE TABLE IF NOT EXISTS tasks (
    -- Identifiant généré par la base (norme SQL, préférée à SERIAL)
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Titre obligatoire, refusé s'il ne contient que des espaces (double garde avec l'API)
    title       VARCHAR(200) NOT NULL CHECK (char_length(btrim(title)) > 0),
    -- Statut de la tâche
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    -- Horodatages avec fuseau : date de création et date de réalisation (NULL tant que non faite)
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    done_at     TIMESTAMPTZ
);

-- Accélère le listing filtré par statut et trié par date
CREATE INDEX IF NOT EXISTS idx_tasks_done_created ON tasks (done, created_at DESC);
