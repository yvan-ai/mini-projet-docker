#!/usr/bin/env bash
# Collecte des mesures brutes du RAPPORT dans docs/mesures/, sur la machine qui exécute le script.
# Usage : ./scripts/mesures.sh [--destructive] [--compare-third-service]
#   --destructive           : ajoute la mesure "docker compose down -v" (SUPPRIME les données de la base)
#   --compare-third-service : lance temporairement adminer et redis pour comparer leur mémoire à Nginx
set -euo pipefail

cd "$(dirname "$0")/.."

export MSYS_NO_PATHCONV=1

DESTRUCTIVE=0
COMPARE=0
for arg in "$@"; do
  case "$arg" in
    --destructive) DESTRUCTIVE=1 ;;
    --compare-third-service) COMPARE=1 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done

OUT=docs/mesures
mkdir -p "$OUT"
[[ -f .env ]] || cp .env.example .env
HTTP_PORT=$(grep -E '^HTTP_PORT=' .env | cut -d= -f2 | tr -d '\r' || true)
BASE="http://localhost:${HTTP_PORT:-8080}"
MACHINE="$(uname -srm), Docker Engine $(docker version --format '{{.Server.Version}}')"

NAIVE_BASE=python:3.13.16-trixie
ADMINER=adminer:6.1.1-standalone
REDIS=redis:8.10.2-alpine3.23

BACKUP=$(mktemp -d)
cp src/app/main.py requirements.txt "$BACKUP/"
restore() {
  cp "$BACKUP/main.py" src/app/main.py
  cp "$BACKUP/requirements.txt" requirements.txt
  rm -rf "$BACKUP"
  docker rm -f mesure-adminer mesure-redis >/dev/null 2>&1 || true
}
trap restore EXIT

TIMEFORMAT='durée réelle : %R s'

header() { echo "# $1"; echo "# Mesuré le $(date '+%Y-%m-%d %H:%M:%S %z') ; $MACHINE"; echo; }
timed() {
  local file=$1 title=$2; shift 2
  header "$title" >"$file"
  echo "\$ time $*" >>"$file"
  { time "$@" >>"$file" 2>&1; } 2>>"$file"
}
duration() { grep -o 'durée réelle : [0-9.,]* s' "$1" | tail -n 1 | sed 's/durée réelle : //'; }
list_tasks() { echo "\$ curl -s $BASE/api/tasks"; curl -s "$BASE/api/tasks"; echo; }
containers() {
  echo "\$ docker compose ps --format '{{.Name}} {{.ID}} {{.RunningFor}}'"
  docker compose ps --format '{{.Name}} {{.ID}} {{.RunningFor}}'
}
to_mb() { awk -v s="$1" 'BEGIN { n = s + 0; if (s ~ /GB$/) n *= 1000; else if (s ~ /kB$/) n /= 1000; printf "%.1f", n }'; }

echo "Mesures en cours, sorties dans $OUT/ (plusieurs minutes)."

echo "[01] build à froid (--no-cache)"
timed "$OUT/01-build-froid.txt" \
  "Build à froid de l'image app : aucune couche réutilisée (image de base python déjà présente localement)" \
  docker compose --progress=plain build --no-cache app

echo "[02] rebuild immédiat, rien n'a changé"
timed "$OUT/02-build-cache.txt" "Rebuild immédiat sans aucune modification : couches attendues CACHED" \
  docker compose --progress=plain build app

echo "[03] rebuild après modification d'une ligne de src/app/main.py"
LINE="# mesure cache $(date +%s)"
echo "$LINE" >>src/app/main.py
timed "$OUT/03-build-code-modifie.txt" \
  "Rebuild après ajout de la ligne '$LINE' à la fin de src/app/main.py (fichier restauré ensuite)" \
  docker compose --progress=plain build app
cp "$BACKUP/main.py" src/app/main.py

echo "[04] rebuild après modification de requirements.txt"
LINE="# mesure cache $(date +%s)"
echo "$LINE" >>requirements.txt
timed "$OUT/04-build-requirements-modifie.txt" \
  "Rebuild après ajout de la ligne '$LINE' à requirements.txt (fichier restauré ensuite) : invalidation en cascade" \
  docker compose --progress=plain build app
cp "$BACKUP/requirements.txt" requirements.txt

docker compose build app >/dev/null 2>&1

echo "[05] taille de l'image finale"
{
  header "Taille de l'image finale todo-app:1.0.0"
  echo '$ docker image ls todo-app:1.0.0'
  docker image ls todo-app:1.0.0
  echo
  echo "\$ docker image inspect -f '{{.Size}}' todo-app:1.0.0   (octets, contenu compressé)"
  docker image inspect -f '{{.Size}}' todo-app:1.0.0
  echo
  echo "\$ docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' todo-app:1.0.0"
  docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' todo-app:1.0.0
} >"$OUT/05-taille-image.txt" 2>&1

echo "[06] variante naïve (docs/Dockerfile.naive)"
HAD_NAIVE_BASE=0
if docker image inspect "$NAIVE_BASE" >/dev/null 2>&1; then HAD_NAIVE_BASE=1; fi
docker pull -q "$NAIVE_BASE" >/dev/null
timed "$OUT/06-taille-naive.txt" "Build de la variante naïve docs/Dockerfile.naive, tag todo-app:naive" \
  docker build --progress=plain -f docs/Dockerfile.naive -t todo-app:naive .
{
  echo
  echo '$ docker image ls todo-app'
  docker image ls todo-app
  echo
  echo "\$ docker image inspect -f '{{.Size}}' todo-app:naive   (octets, contenu compressé)"
  docker image inspect -f '{{.Size}}' todo-app:naive
} >>"$OUT/06-taille-naive.txt" 2>&1
FINAL_SIZE=$(docker image ls --format '{{.Size}}' todo-app:1.0.0)
NAIVE_SIZE=$(docker image ls --format '{{.Size}}' todo-app:naive)

echo "[07] tailles des autres images"
{
  header "Tailles des images officielles utilisées (proxy, db) et des bases Python slim / complète"
  for image in nginx:1.30.5-alpine3.24 postgres:17.11-alpine3.24 python:3.13.16-slim-trixie "$NAIVE_BASE"; do
    echo "\$ docker image ls $image"
    docker image ls "$image"
    echo
  done
} >"$OUT/07-tailles-autres-images.txt" 2>&1

{
  echo
  echo '$ docker rmi todo-app:naive'
  docker rmi todo-app:naive
  if [[ $HAD_NAIVE_BASE -eq 0 ]]; then
    echo "\$ docker rmi $NAIVE_BASE   (téléchargée uniquement pour cette mesure)"
    docker rmi "$NAIVE_BASE"
  fi
} >>"$OUT/06-taille-naive.txt" 2>&1

echo "[08] mémoire des conteneurs (30 s après démarrage)"
docker compose up -d --wait >/dev/null 2>&1
sleep 30
{
  header "Mémoire des 3 conteneurs au repos, 30 s après docker compose up -d --wait"
  echo '$ docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}"'
  docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}" $(docker compose ps -q)
} >"$OUT/08-memoire.txt" 2>&1

echo "[09] persistance (restart, down puis up)"
PTITLE="mesure-persistance-$(date +%s)"
{
  header "Persistance : une tâche créée survit à restart, puis à down suivi de up"
  echo "## 1. Création de la tâche $PTITLE"
  echo "\$ curl -s -X POST $BASE/api/tasks -d '{\"title\":\"$PTITLE\"}'"
  curl -s -X POST -H 'Content-Type: application/json' -d "{\"title\":\"$PTITLE\"}" "$BASE/api/tasks"
  echo
  containers
  list_tasks
  echo
  echo "## 2. docker compose restart : mêmes conteneurs (mêmes ID) redémarrés"
  echo '$ time docker compose restart'
  time docker compose restart
  docker compose up -d --wait
  containers
  list_tasks
  echo
  echo "## 3. docker compose down puis up : conteneurs et réseaux supprimés puis recréés (nouveaux ID)"
  echo '$ time docker compose down'
  time docker compose down
  echo '$ docker volume ls --filter name=todo-docker'
  docker volume ls --filter name=todo-docker
  echo '$ time docker compose up -d --wait'
  time docker compose up -d --wait
  containers
  list_tasks
  echo
  echo "## 4. Logs du nouveau conteneur db : le script d'init n'est pas rejoué"
  echo '$ docker compose logs db | grep -E "Skipping initialization|docker-entrypoint-initdb.d|ready to accept"'
  docker compose logs db | grep -E "Skipping initialization|docker-entrypoint-initdb.d|ready to accept" || true
  echo
  echo '$ docker volume inspect todo-docker_pgdata'
  docker volume inspect todo-docker_pgdata
} >"$OUT/09-persistance.txt" 2>&1

if [[ $DESTRUCTIVE -eq 1 ]]; then
  echo "[10] down -v (DESTRUCTIF : les données de la base sont supprimées)"
  {
    header "down -v : le volume est supprimé, la base repart vide au up suivant"
    echo "## Avant"
    list_tasks
    echo '$ docker volume inspect -f "{{.Name}} créé le {{.CreatedAt}}" todo-docker_pgdata'
    docker volume inspect -f '{{.Name}} créé le {{.CreatedAt}}' todo-docker_pgdata
    echo
    echo '$ time docker compose down -v'
    time docker compose down -v
    echo '$ docker volume ls --filter name=todo-docker'
    docker volume ls --filter name=todo-docker
    echo
    echo '$ time docker compose up -d --wait'
    time docker compose up -d --wait
    echo '$ docker volume inspect -f "{{.Name}} créé le {{.CreatedAt}}" todo-docker_pgdata'
    docker volume inspect -f '{{.Name}} créé le {{.CreatedAt}}' todo-docker_pgdata
    echo
    echo "## Logs du nouveau conteneur db : cluster initialisé, 01-schema.sql rejoué"
    echo '$ docker compose logs db | grep -E "initdb|docker-entrypoint-initdb.d|CREATE|ready to accept"'
    docker compose logs db | grep -E "initdb|docker-entrypoint-initdb.d|CREATE|ready to accept" || true
    echo
    echo "## Après : liste vide"
    list_tasks
  } >"$OUT/10-down-v.txt" 2>&1
else
  PID=$(curl -s "$BASE/api/tasks?status=all" | grep -o "\"id\":[0-9]*,\"title\":\"$PTITLE\"" | sed 's/"id":\([0-9]*\).*/\1/' || true)
  if [[ -n "$PID" ]]; then curl -s -o /dev/null -X DELETE "$BASE/api/tasks/$PID"; fi
fi

echo "[11] contexte de build"
{
  header "Contexte de build envoyé au moteur, filtré par .dockerignore"
  echo "## Lignes 'transferring context' des builds 01 à 04"
  echo "## (BuildKit ne retransfère que les fichiers modifiés depuis le build précédent)"
  grep -H 'transferring context' "$OUT"/0[1-4]-*.txt || true
  echo
  echo "## Fichiers réellement inclus dans le contexte (requirements.txt et src/, le reste est exclu)"
  echo "\$ find requirements.txt src -type f ! -path '*__pycache__*' -exec wc -c {} +"
  find requirements.txt src -type f ! -path '*__pycache__*' -exec wc -c {} +
  echo
  echo "## Pour comparaison, taille du dépôt sans .dockerignore (avec puis sans .git)"
  echo '$ du -sh .'
  du -sh .
  echo '$ du -sh --exclude=.git .'
  du -sh --exclude=.git .
} >"$OUT/11-contexte-build.txt" 2>&1

if [[ $COMPARE -eq 1 ]]; then
  echo "[12] comparaison mémoire Nginx / Adminer / Redis"
  PULLED=()
  for image in "$ADMINER" "$REDIS"; do
    docker image inspect "$image" >/dev/null 2>&1 || { docker pull -q "$image" >/dev/null; PULLED+=("$image"); }
  done
  docker run --rm -d --name mesure-adminer "$ADMINER" >/dev/null
  docker run --rm -d --name mesure-redis "$REDIS" >/dev/null
  sleep 30
  {
    header "Mémoire au repos des candidats au 3e service (conteneurs lancés 30 s plus tôt, puis arrêtés)"
    echo '$ docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}"'
    docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}" \
      "$(docker compose ps -q proxy)" mesure-adminer mesure-redis
    echo
    for image in nginx:1.30.5-alpine3.24 "$ADMINER" "$REDIS"; do
      echo "\$ docker image ls $image"
      docker image ls "$image"
    done
  } >"$OUT/12-comparaison-3e-service.txt" 2>&1
  docker stop mesure-adminer mesure-redis >/dev/null
  if [[ ${#PULLED[@]} -gt 0 ]]; then docker rmi "${PULLED[@]}" >/dev/null; fi
fi

FINAL_MB=$(to_mb "$FINAL_SIZE")
NAIVE_MB=$(to_mb "$NAIVE_SIZE")
GAIN=$(awk -v f="$FINAL_MB" -v n="$NAIVE_MB" 'BEGIN { printf "%.1f Mo, soit %.0f %%", n - f, (n - f) * 100 / n }')
{
  header "Résumé des mesures"
  echo "Image finale todo-app:1.0.0   : $FINAL_SIZE"
  echo "Image naïve todo-app:naive    : $NAIVE_SIZE"
  echo "Gain                          : $GAIN"
  echo "Build à froid (01)            : $(duration "$OUT/01-build-froid.txt")"
  echo "Build sans changement (02)    : $(duration "$OUT/02-build-cache.txt")"
  echo "Build code modifié (03)       : $(duration "$OUT/03-build-code-modifie.txt")"
  echo "Build requirements modifié (04): $(duration "$OUT/04-build-requirements-modifie.txt")"
  echo "Mémoire des services (08) :"
  tail -n +5 "$OUT/08-memoire.txt"
} | tee "$OUT/99-resume.txt"
