# Gestion de tâches conteneurisée

Application web qui gère une liste de tâches (créer, lister, marquer comme faite, supprimer) via une page web et une API REST FastAPI, servie derrière un reverse proxy Nginx, avec les données stockées dans PostgreSQL.

## Architecture

```
Navigateur ──> proxy (Nginx, publié sur :8080) ──> app (FastAPI, :8000 interne) ──> db (PostgreSQL, :5432 interne)
               └──────────── réseau front ─────────────┘└──────────── réseau back (internal) ───────┘
                                                                         données : volume nommé pgdata
```

Seul `proxy` publie un port sur l'hôte. `app` et `db` ne sont joignables que par leur nom de service, sur les réseaux internes de Compose ; le proxy n'a pas accès au réseau de la base.

## Prérequis

- Docker Engine 24 ou plus récent (ou Docker Desktop récent) ;
- Docker Compose v2.20 ou plus récent (commande `docker compose`, pas l'ancien `docker-compose`) ;
- le port 8080 libre sur l'hôte (sinon, changer `HTTP_PORT` dans `.env`) ;
- un accès Internet au premier démarrage (téléchargement des images et des dépendances Python).

Vérification :

```bash
docker version
docker compose version
```

Sous Windows, lancer les commandes depuis un terminal WSL2 (dépôt cloné dans le système de fichiers Linux, par exemple `~/projets`) ou depuis Git Bash.

## Démarrage

```bash
git clone https://github.com/yvan-ai/mini-projet-docker.git mini-projet-docker
cd mini-projet-docker
cp .env.example .env
docker compose up -d --build --wait
```

`--wait` rend la main quand les trois services sont `healthy`. Le premier démarrage télécharge les images et construit celle de l'application (quelques minutes).

## Accès

| URL | Contenu |
|---|---|
| http://localhost:8080 | page web de gestion des tâches |
| http://localhost:8080/docs | documentation interactive de l'API (Swagger) |
| http://localhost:8080/health | état de l'application et de sa connexion à la base |
| http://localhost:8080/api/info | nom d'hôte de l'app, hôte de base utilisé (`db`), version de PostgreSQL |

Le port suit la variable `HTTP_PORT` du fichier `.env` (8080 par défaut).

## Variables d'environnement

Définies dans `.env`, créé à partir de `.env.example`. Le fichier `.env` n'est **pas** versionné (il est dans `.gitignore`).

| Variable | Rôle | Exemple |
|---|---|---|
| `POSTGRES_DB` | nom de la base créée au premier démarrage | `todo` |
| `POSTGRES_USER` | utilisateur PostgreSQL propriétaire de la base, utilisé aussi par l'app | `todo` |
| `POSTGRES_PASSWORD` | mot de passe de cet utilisateur | `change_me` |
| `HTTP_PORT` | port de l'hôte sur lequel le proxy Nginx est publié | `8080` |

Si une variable obligatoire manque (ou si `.env` est absent), `docker compose up` refuse de démarrer avec un message explicite, par exemple :
`required variable POSTGRES_DB is missing a value: POSTGRES_DB manquant dans .env`.

L'hôte de la base (`DB_HOST=db`, le nom du service) est fixé dans `compose.yaml` et non dans `.env`.

Les identifiants de la base ne sont lus qu'à la **création** du volume : après un changement de `POSTGRES_*`, repartir d'une base vide avec `docker compose down -v` (les données sont perdues).

## Commandes utiles

```bash
docker compose logs -f app        # logs de l'application (sans nom de service : tous les logs)
docker compose exec app sh        # shell dans le conteneur de l'application
docker compose exec db psql -U todo -d todo   # console SQL (la base n'est pas publiée sur l'hôte)
docker compose ps                 # état et santé des services
docker compose down               # tout arrêter, les données sont conservées dans le volume
docker compose down -v            # tout arrêter ET supprimer les données
```

## Tests

```bash
./scripts/smoke.sh
```

Le script démarre la stack, vérifie les routes, la création et la validation des tâches, la persistance après `restart` puis après `down` / `up`, que la base et l'app ne sont pas publiées, la résolution de `db` par son nom et l'isolation du réseau de la base. Il affiche `OK` ou `ECHEC` à chaque étape et supprime sa tâche de test. L'option `--destructive` ajoute un test `down -v` qui efface les données.

`./scripts/mesures.sh` régénère les mesures de `docs/mesures/` utilisées dans `RAPPORT.md`.

## Dépannage

- **Port 8080 déjà utilisé** : mettre par exemple `HTTP_PORT=8081` dans `.env`, puis relancer `docker compose up -d --wait`.
- **Table absente après un ancien essai** : le script `db/init/01-schema.sql` n'est joué que sur un volume vide ; `docker compose down -v` puis `up` le rejoue (données perdues).

## Choix du 3e service

Reverse proxy Nginx : c'est le plus sobre en mémoire des candidats mesurés au repos (Nginx 3,2 Mio, Redis 5,2 Mio, Adminer 8,5 Mio, voir `docs/mesures/12`), et il offre un point d'entrée unique (un seul port publié, app et base non exposées).
