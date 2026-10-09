#!/usr/bin/env bash
# Tests d'acceptation de bout en bout de la stack (proxy -> app -> db).
# Usage : ./scripts/smoke.sh [--destructive]
#   --destructive : ajoute le test "docker compose down -v", qui SUPPRIME les données de la base.
# Sans ce flag, le script ne supprime jamais le volume. Prérequis sur l'hôte : bash, curl, docker.
# Affiche OK / ECHEC par étape et s'arrête au premier échec (code de sortie non nul).
set -euo pipefail

# Toujours travailler depuis la racine du dépôt, quel que soit le répertoire d'appel
cd "$(dirname "$0")/.."

# Git Bash (Windows) réécrit les arguments qui ressemblent à des chemins Unix : on désactive.
# Sans effet sous Linux / WSL.
export MSYS_NO_PATHCONV=1

DESTRUCTIVE=0
if [[ "${1:-}" == "--destructive" ]]; then DESTRUCTIVE=1; fi

# Fichier temporaire : sortie de la dernière commande, affichée en cas d'échec
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

STEP=0
ok()   { printf '[%02d] OK     %s\n' "$STEP" "$1"; }
fail() {
  printf '[%02d] ECHEC  %s\n' "$STEP" "$1" >&2
  if [[ -s "$LOG" ]]; then echo "--- dernière sortie ---" >&2; tail -n 20 "$LOG" >&2; fi
  exit 1
}
# check "description" commande [args...] : OK si la commande réussit, ECHEC (et arrêt) sinon
check() {
  STEP=$((STEP + 1)); : >"$LOG"
  local desc=$1; shift
  if "$@"; then ok "$desc"; else fail "$desc"; fi
}

# http METHODE URL [CORPS_JSON] : remplit CODE (statut HTTP, 000 si injoignable) et BODY
http() {
  local out
  if [[ $# -ge 3 ]]; then
    out=$(curl -s -m 15 -w '\n%{http_code}' -X "$1" -H 'Content-Type: application/json' -d "$3" "$2") || true
  else
    out=$(curl -s -m 15 -w '\n%{http_code}' -X "$1" "$2") || true
  fi
  CODE=${out##*$'\n'}
  BODY=${out%$'\n'*}
}
expect()   { [[ "$CODE" == "$1" ]] || { echo "HTTP $CODE (attendu $1) : $BODY" >"$LOG"; return 1; }; }
body_has() { [[ "$BODY" == *"$1"* ]] || { echo "absent de la réponse : $1 ; reçu : $BODY" >"$LOG"; return 1; }; }
get()      { http GET "$BASE$1" && expect "$2" && { [[ -z "${3:-}" ]] || body_has "$3"; }; }

compose_up()  { docker compose up -d --wait >"$LOG" 2>&1; }
task_listed() { get /api/tasks 200 "\"title\":\"$TITLE\""; }

# 1. Fichier .env (créé depuis l'exemple s'il manque) et URL de base
step_env() {
  [[ -f .env ]] || cp .env.example .env
  HTTP_PORT=$(grep -E '^HTTP_PORT=' .env | cut -d= -f2 | tr -d '\r' || true)
  BASE="http://localhost:${HTTP_PORT:-8080}"
}
check ".env présent (copié depuis .env.example si absent)" step_env
echo "     URL de test : $BASE"

# 2. Démarrage complet : build de l'image app + attente des healthchecks
step_up() { docker compose up -d --build --wait >"$LOG" 2>&1; }
check "docker compose up -d --build --wait" step_up

# 3. Les 3 services tournent et sont healthy
step_ps() {
  docker compose ps --format '{{.Service}} {{.State}} {{.Health}}' >"$LOG"
  [[ $(grep -cE '^(proxy|app|db) running healthy$' "$LOG") -eq 3 ]]
}
check "3 services running (healthy)" step_ps

# 4 à 6. Routes de base, via le proxy (seul port publié)
check "GET /nginx-health -> 200 (le proxy répond)" get /nginx-health 200
check "GET /health -> 200 et \"db\":\"ok\"" get /health 200 '"db":"ok"'
check "GET / -> 200, page HTML avec <title>" get / 200 '<title>'

# 7. Création d'une tâche au titre unique
TITLE="smoke-$(date +%s)"
step_create() {
  http POST "$BASE/api/tasks" "{\"title\":\"$TITLE\"}" && expect 201 || return 1
  ID=$(sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' <<<"$BODY")
  [[ -n "$ID" ]]
}
check "POST /api/tasks -> 201 (titre $TITLE)" step_create
echo "     id de la tâche créée : $ID"

# 8. Validation : titre vide (espaces) refusé
step_empty() { http POST "$BASE/api/tasks" '{"title":"   "}' && expect 422; }
check "POST /api/tasks titre vide -> 422" step_empty

# 9 et 10. Marquer comme faite, puis un id inexistant
step_done() { http PATCH "$BASE/api/tasks/$ID/done" && expect 200 && body_has '"done":true'; }
check "PATCH /api/tasks/$ID/done -> 200 et \"done\":true" step_done
step_404() { http PATCH "$BASE/api/tasks/999999999/done" && expect 404; }
check "PATCH /api/tasks/999999999/done -> 404" step_404

# 11. Filtre par statut
check "GET /api/tasks?status=done contient la tâche" get "/api/tasks?status=done" 200 "\"title\":\"$TITLE\""

# 12. Persistance 1 : les mêmes conteneurs sont redémarrés
step_restart() { docker compose restart >"$LOG" 2>&1 && compose_up && task_listed; }
check "Persistance : tâche présente après docker compose restart" step_restart

# 13. Persistance 2 : conteneurs et réseaux supprimés puis recréés, volume conservé
step_down_up() {
  docker compose down >"$LOG" 2>&1 && compose_up && task_listed \
    && docker volume ls --format '{{.Name}}' | grep -qx todo-docker_pgdata
}
check "Persistance : tâche présente après down puis up (volume todo-docker_pgdata)" step_down_up

# 14. Ni la base ni l'app ne sont publiées sur l'hôte
# (compose port affiche "invalid IP:0" quand rien n'est publié : on refuse tout ":<port>" réel)
not_published() { ! docker compose port "$1" "$2" 2>/dev/null | grep -Eq ':[1-9][0-9]*$'; }
check "db:5432 non publié sur l'hôte" not_published db 5432
check "app:8000 non publié sur l'hôte" not_published app 8000

# 15. L'app résout "db" par le DNS de Docker, vers l'IP du conteneur db sur le réseau back
step_dns() {
  local resolved expected
  resolved=$(docker compose exec -T app python -c "import socket; print(socket.gethostbyname('db'))" | tr -d '\r')
  expected=$(docker inspect -f '{{(index .NetworkSettings.Networks "todo-docker_back").IPAddress}}' "$(docker compose ps -q db)")
  echo "     'db' résolu par app : $resolved ; IP de db sur back : $expected"
  [[ -n "$resolved" && "$resolved" == "$expected" ]]
}
check "app résout 'db' vers l'IP de db sur le réseau back" step_dns
check "GET /api/info -> \"db_host\":\"db\"" get /api/info 200 '"db_host":"db"'

# 16. Isolation : le proxy (réseau front) joint l'app mais pas la base (réseau back)
step_isolation() {
  docker compose exec -T proxy nc -z -w 2 app 8000 >"$LOG" 2>&1 \
    && ! docker compose exec -T proxy nc -z -w 2 db 5432 >>"$LOG" 2>&1
}
check "proxy joint app:8000 mais pas db:5432 (réseau back isolé)" step_isolation

if [[ $DESTRUCTIVE -eq 1 ]]; then
  # 17. (optionnel) down -v : le volume est supprimé, la base repart vide
  step_down_v() {
    docker compose down -v >"$LOG" 2>&1 && compose_up \
      && get /api/tasks 200 && [[ "$BODY" != *"\"title\":\"$TITLE\""* ]]
  }
  check "down -v puis up : la tâche a disparu (volume recréé, schéma rejoué)" step_down_v
  echo "     ATTENTION : les données de la base ont été réinitialisées (volume supprimé puis recréé)."
else
  # 18. Nettoyage de la tâche de test
  step_cleanup() { http DELETE "$BASE/api/tasks/$ID" && expect 204; }
  check "DELETE /api/tasks/$ID -> 204 (nettoyage)" step_cleanup
fi

echo "Tous les tests sont passés ($STEP étapes)."
