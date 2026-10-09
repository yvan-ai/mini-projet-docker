# Rapport : conteneurisation de l'application de gestion de tâches

Mesures prises le 2026-10-09 sur Windows 11 (Docker Desktop 4.67.0, moteur 29.3.1, 4 CPU, 9,7 Gio alloués à la VM Docker), depuis Git Bash ; sorties brutes dans `docs/mesures/`.

Contexte : la machine était saturée ce jour-là. À chaque relevé de la journée, l'hôte n'avait que 0,5 à 0,6 Go de RAM libre sur 15,7 Go, et un cluster kind d'un autre projet tournait en parallèle (`docs/JOURNAL.md`). Les durées sont réelles mais gonflées par cette saturation : on y voit par exemple 91,8 s pour un simple `useradd`.

## 1. Image de base

J'ai retenu `python:3.13.16-slim-trixie` : image officielle, maintenue, avec un tag figé complet (version de Python, variante, Debian 13 nommée) pour que le build soit reproductible.

- **Contre l'image complète** (`python:3.13.16-trixie`) : elle embarque compilateurs et en-têtes (gcc, etc.), inutiles ici car `psycopg[binary]` fournit une wheel précompilée qui contient libpq. Mesure 07 : la base complète pèse **1,62 Go** sur disque (431 Mo compressés), contre **178 Mo** (45,3 Mo compressés) pour la slim. C'est aussi une surface d'attaque bien plus grande.
- **Contre alpine** : alpine utilise musl au lieu de glibc. Une wheel binaire peut manquer, pip compile alors depuis les sources (il faut ajouter gcc, le build est plus long et l'image parfois plus grosse au final), et les comportements DNS et locale diffèrent. Je n'ai pas mesuré de variante alpine de l'app : pour ce projet, un éventuel gain de taille face à slim ne justifiait pas ce risque de compatibilité.
- **Pour Nginx et PostgreSQL**, j'ai pris les variantes alpine officielles (`nginx:1.30.5-alpine3.24`, 93,6 Mo ; `postgres:17.11-alpine3.24`, 424 Mo) : ce sont des binaires fournis et testés par l'image, sans pip ni wheel, donc un gain de taille sans risque de compatibilité. Je reste en PostgreSQL 17, car la 18 change le chemin du volume de données.

## 2. Cache

Ordre des instructions du `Dockerfile`, du plus stable au plus volatil :

```dockerfile
FROM python:3.13.16-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 ...
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --no-create-home app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/ .
USER app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

Chaque instruction produit une couche. Une couche est réutilisée si l'instruction et ses entrées (pour un `COPY`, le contenu des fichiers copiés) sont identiques **et** si toutes les couches précédentes ont été réutilisées. Dès qu'une couche est invalidée, toutes les suivantes sont reconstruites. Quand je modifie une ligne de code, seul `COPY src/ .` et ce qui suit sont rejoués ; `pip install` reste en cache car `requirements.txt` n'a pas changé.

Build à froid (`01-build-froid.txt`, `--no-cache`) :

```
#8 [3/6] RUN groupadd --system app && useradd --system --gid app --no-create-home app
#8 DONE 91.8s
#9 [4/6] COPY requirements.txt .
#9 DONE 1.2s
#10 [5/6] RUN pip install --no-cache-dir -r requirements.txt
#10 DONE 120.3s
#11 [6/6] COPY src/ .
#11 DONE 0.5s
durée réelle : 264.109 s
```

Rebuild après ajout d'une ligne à la fin de `src/app/main.py` (`03-build-code-modifie.txt`) :

```
#8 [3/6] RUN groupadd --system app && useradd --system --gid app --no-create-home app
#8 CACHED
#9 [4/6] COPY requirements.txt .
#9 CACHED
#10 [5/6] RUN pip install --no-cache-dir -r requirements.txt
#10 CACHED
#11 [6/6] COPY src/ .
#11 DONE 0.2s
durée réelle : 9.227 s
```

On passe de **264,1 s à 9,2 s**. Le rebuild sans aucune modification (02) prend 9,0 s, tout en `CACHED` : le reste du temps est le coût fixe de Compose et de l'export. À l'inverse, une simple ligne de commentaire ajoutée à `requirements.txt` (04) invalide `COPY requirements.txt` puis, en cascade, `pip install` (109,6 s) et `COPY src/` : **129,3 s**.

## 3. Taille

Image finale `todo-app:1.0.0` (mesure 05) : **229 Mo** sur disque selon `docker image ls`, **54,5 Mo** de contenu compressé, c'est-à-dire ce qui est téléchargé lors d'un pull (54 544 928 octets). Avec le magasin d'images containerd de Docker Desktop, la colonne « DISK USAGE » additionne couches décompressées et couches compressées : selon `docker history`, les couches décompressées font environ 174 Mo, plus 54,5 Mo de contenu, soit 229 Mo. La couche `pip install` pèse 41,2 Mo, le code 41 ko.

Avant / après (mesure 06, `docs/Dockerfile.naive` : image complète, code copié avant les dépendances, cache pip conservé, root) :

| Image | Disque (`docker image ls`) | Contenu compressé |
|---|---|---|
| `todo-app:naive` | 1,7 Go | 440 Mo (439 937 607 octets) |
| `todo-app:1.0.0` | 229 Mo | 54,5 Mo (54 544 928 octets) |
| Gain | environ 1,47 Go, environ 87 % | 385,4 Mo, 87,6 % |

Origine du gain, par ordre d'impact :
1. la base slim au lieu de la complète (178 Mo contre 1,62 Go, mesure 07) : l'essentiel ;
2. `--no-cache-dir` : pip ne laisse pas ses archives dans la couche ;
3. `.dockerignore` : le contexte envoyé au moteur fait 3,10 ko au build à froid (mesure 11 ; `requirements.txt` et `src/` totalisent 14 617 octets), contre 199 Kio pour le dépôt sans `.git` et 410 Kio avec (`du -sh`) ;
4. aucun paquet système installé.

Mémoire au repos des trois conteneurs (mesure 08) : app 62,5 Mio, db 13,7 Mio, proxy **2,2 Mio**. Pour le choix du 3e service, j'ai lancé les candidats côte à côte (mesure 12, au repos) : Nginx 3,2 Mio, Redis 5,2 Mio, Adminer 8,5 Mio. Nginx est le plus sobre, mais l'écart n'est que de quelques Mio. Ce qui a surtout décidé, c'est l'architecture : un seul port publié, l'app et la base non exposées, aucun code de cache à écrire (contrairement à Redis).

## 4. Persistance

Les données de PostgreSQL sont dans le volume nommé `todo-docker_pgdata`, monté sur `/var/lib/postgresql/data` (le `PGDATA` de l'image 17).

- **`docker compose restart`** (09, 88,1 s) : les mêmes conteneurs sont arrêtés puis relancés, rien n'est recréé. Les ID restent identiques (`8b804787434c` pour db) et la tâche est toujours là.
- **`docker compose down`** (09, 12,2 s) : conteneurs et réseaux sont supprimés, le volume est **conservé** (`docker volume ls` le liste toujours). Au `up` (135,0 s), Compose crée de nouveaux conteneurs (db devient `290bd1bd1429`) ; le nouveau conteneur `db` monte le même volume, l'entrypoint trouve un répertoire de données déjà initialisé et l'écrit : `PostgreSQL Database directory appears to contain a database; Skipping initialization`. `01-schema.sql` n'est pas rejoué et la tâche `mesure-persistance-1791563898` est toujours listée. Le volume garde sa date de création (`2026-10-09T14:21:03Z`).
- **`docker compose down -v`** (10, 15,8 s) : le volume est supprimé lui aussi (`docker volume ls` vide). Au `up` suivant (111,4 s), un volume neuf est créé (`2026-10-09T16:43:03Z`). L'entrypoint, trouvant un répertoire vide, initialise un nouveau cluster (`initdb`), crée l'utilisateur et la base depuis les variables d'environnement (`CREATE DATABASE`), puis joue le script : `running /docker-entrypoint-initdb.d/01-schema.sql`, `CREATE TABLE`, `CREATE INDEX`. L'API renvoie `[]`.

J'ai choisi un **volume nommé** plutôt qu'un bind mount : il est géré par Docker et indépendant de l'arborescence de l'hôte, ce qui compte sous Windows, où un dossier hôte pose des problèmes de droits et de propriétaire pour PostgreSQL. Il survit à `down` et ne disparaît qu'avec `down -v`. Sans volume, les données vivraient dans la couche du conteneur et disparaîtraient dès le `down`.

## 5. Difficulté

<!-- Problème réellement rencontré pendant la réalisation, sur cette machine (docs/JOURNAL.md, entrée de 17:44).
     À relire et à savoir raconter avec ses propres mots, ou à remplacer par un autre problème vécu. -->

Le problème qui m'a le plus bloqué : mes tests d'acceptation échouaient au moment du `docker compose restart`, avec ce message :

```
Error response from daemon: Cannot restart container d1f3efd3f5dfb2ace073a504ff83a05b53361241be786790ee736f135be7bffc: tried to kill container, but did not receive an exit event
```

Diagnostic :
- `docker ps -a` montrait `todo-docker-db-1   Exited (0)` : la base était arrêtée et non relancée ;
- `docker compose logs db` montrait `received fast shutdown request` puis `database system is shut down` 0,6 s plus tard : PostgreSQL s'était arrêté proprement ;
- `docker inspect -f '{{.Config.StopTimeout}}'` affichait `1` sur mes trois conteneurs, alors que je n'avais rien configuré ; un `docker create alpine:3.22 true` donnait aussi `1`. C'était donc le défaut du moteur de ma machine, et non les 10 s habituelles ;
- un conteneur de test qui ignore SIGTERM était tué en `6.067 s` au total, avec le code `137` (SIGKILL), alors que les seuls appels à l'API prenaient déjà environ 5 s ;
- au démarrage précédent, les logs montraient déjà `database system was not properly shut down; automatic recovery in progress`.

Cause : le moteur n'accordait qu'1 s entre le signal d'arrêt et le SIGKILL. Sur ma machine saturée, cette marge était trop courte, et le `restart` échouait (au pire, PostgreSQL pouvait être tué avant son checkpoint d'arrêt). Correction : `stop_grace_period: 10s` sur `db` et `app` dans `compose.yaml`, pour ne plus dépendre du défaut du moteur. Le test complet (`scripts/smoke.sh`, 19 étapes) est ensuite passé.

L'autre blocage notable, `failed to solve: frontend grpc server closed unexpectedly` au build, venait du frontend externe `# syntax=docker/dockerfile:1`. Je l'ai contourné en utilisant le parseur intégré au moteur (détail dans `docs/JOURNAL.md`).
