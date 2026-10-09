# Journal des erreurs rencontrées

Incidents réellement rencontrés pendant la réalisation, le 2026-10-09, sur la machine de développement (Windows 11, Docker Desktop 4.67.0, moteur 29.3.1, WSL2 Ubuntu 24.04). Messages copiés tels quels.

Contexte commun : pendant toute la session, l'hôte n'avait que 0,5 à 0,6 Go de RAM libre sur 15,7 Go (la VM WSL/Docker en occupait environ 7 Go, dont un cluster kind d'un autre projet, `greentaxi-control-plane`, à environ 2 Gio).

### 2026-10-09 15:47 : Git Bash réécrit un chemin Unix
- Commande : `wsl.exe -d Ubuntu --exec bash /mnt/c/Users/Kenne/AppData/Local/Temp/.../env.sh` depuis Git Bash
- Message exact (chemin temporaire abrégé en `[...]`) :
  ```
  bash: C:/Program Files/Git/mnt/c/Users/Kenne/AppData/Local/Temp/[...]/env.sh: No such file or directory
  ```
- Diagnostic : le chemin reçu commence par `C:/Program Files/Git` : MSYS (Git Bash) a converti l'argument `/mnt/c/...` en chemin Windows avant de lancer le programme Windows.
- Cause : conversion automatique des chemins de MSYS pour les exécutables Windows. Le même mécanisme touche `docker compose exec ... /chemin` lancé depuis Git Bash.
- Correction : `MSYS_NO_PATHCONV=1` devant la commande ; `export MSYS_NO_PATHCONV=1` en tête de `scripts/smoke.sh` et `scripts/mesures.sh` (sans effet sous Linux/WSL).

### 2026-10-09 15:51 : le build échoue sur la directive `# syntax=`
- Commande : `docker build --progress=plain -t todo-app:test .` (depuis WSL, puis depuis Git Bash)
- Message exact :
  ```
  Dockerfile:1
  --------------------
     1 | >>> # syntax=docker/dockerfile:1
     2 |     # Ligne ci-dessus : fixe la syntaxe du Dockerfile (frontend BuildKit v1).
     3 |
  --------------------
  ERROR: failed to build: failed to solve: frontend grpc server closed unexpectedly
  ```
- Diagnostic :
  - relance : même erreur, donc pas un incident isolé ;
  - Dockerfile minimal (`# syntax=docker/dockerfile:1`, `FROM alpine:3.22`, `RUN echo ok`) : même erreur, donc le contenu du projet n'est pas en cause ;
  - `docker buildx inspect default` : `BuildKit version: v0.28.1` ;
  - `docker buildx imagetools inspect docker/dockerfile:1` : digest `sha256:4edf897a...`, identique à `docker/dockerfile:1.27.1` (tag flottant republié le 2026-09-30) ;
  - builds de test avec les versions 1.28.0, 1.27.1, 1.27.0, 1.26.0, 1.25.0 : tous réussis, puis `:1` a de nouveau fonctionné ;
  - à 16:18, `docker compose up -d --build --wait` avec `# syntax=docker/dockerfile:1.27.1` : de nouveau `failed to solve: frontend grpc server closed unexpectedly` ;
  - `docker --context=default buildx history inspect --debug yrvdzy2e1gef7skq2tsw947so` : `Error: Unknown frontend grpc server closed unexpectedly`, pile d'appels dans `github.com/moby/buildkit/frontend/gateway.(*gatewayFrontend).Solve` (`gateway.go:299`).
- Cause : le frontend externe `docker/dockerfile` s'exécute dans un conteneur à part, lancé par BuildKit ; c'est ce processus qui meurt, de façon intermittente, quelle que soit la version. Cause exacte non élucidée ; la forte pression mémoire de l'hôte est l'hypothèse la plus probable.
- Correction : suppression de la directive `# syntax=` en tête du `Dockerfile` (commit `fix(build): parseur Dockerfile intégré au moteur`). Le parseur intégré à BuildKit v0.28.1 gère toutes les instructions utilisées. Aucun échec de build depuis.

### 2026-10-09 16:10 : `wsl.exe` ne répond plus
- Commande : `wsl.exe -d Ubuntu --exec bash .../w.sh 'docker build ...'` (lancement des commandes Docker dans WSL depuis Git Bash)
- Message exact :
  ```
  #2 resolve image config for docker-image://docker.io/docker/dockerfile:1.27.1
  <3>WSL (58825) ERROR: UtilAcceptVsock:251: accept4 failed 110
  ...
  #2 DONE 213.0s
  ```
  puis, à l'appel suivant :
  ```
  Une tentative de connexion a échoué car le parti connecté n'a pas répondu convenablement au-delà d'une certaine durée ou une connexion établie a échoué car l'hôte de connexion n'a pas répondu.
  Code d'erreur : Wsl/Service/0x8007274c
  ```
- Diagnostic : PowerShell `Get-CimInstance Win32_OperatingSystem` : `RAM libre : 0,5 Go / 15,7 Go` ; `Get-Process` : `vmmemWSL 7553` Mo ; `docker ps` : `greentaxi-control-plane` (autre projet) ; `docker stats` : `1.986GiB`.
- Cause : service WSL saturé (délais dépassés, erreur 110 = ETIMEDOUT) sur un hôte presque sans mémoire libre.
- Correction : aucune dans le projet. Les commandes ont été lancées depuis Git Bash avec le client Docker Windows, ce qui a imposé `export MSYS_NO_PATHCONV=1` dans les scripts (voir l'entrée de 15:47).

### 2026-10-09 16:24 : deux tâches fusionnées dans l'interface
- Commande : test de la page dans le navigateur : saisie d'un titre, Entrée, saisie immédiate d'un deuxième titre, Entrée
- Message exact (pas d'erreur, titre enregistré) :
  ```
  <img src=x onerror=alert(1)> test XSSDeuxieme tache
  ```
- Diagnostic : le champ n'était vidé qu'après la réponse du `POST` ; la deuxième saisie s'est ajoutée au premier texte encore présent. (Au passage, le titre piège s'affiche bien comme texte : la protection XSS par `textContent` fonctionne.)
- Cause : formulaire actif pendant la requête.
- Correction : `src/app/static/index.html`, gestionnaire `submit` : le champ est désactivé pendant l'envoi puis réactivé (commit `fix(app): champ désactivé pendant l'envoi d'une tâche`).

### 2026-10-09 16:27 : l'app passe `unhealthy` alors qu'elle répond
- Commande : `docker compose up -d --build --wait`, puis `docker compose ps`
- Message exact :
  ```
  app       Up About a minute (unhealthy)
  ```
  alors que `curl http://localhost:8080/health` renvoyait `{"status":"ok","db":"ok"} [200]`.
- Diagnostic :
  - `docker inspect --format '{{json .State.Health}}' todo-docker-app-1` : quatre fois `'Health check exceeded timeout (3s)'`, puis `exit 0` ;
  - `time docker exec todo-docker-app-1 python -c "...urlopen('http://127.0.0.1:8000/health'...)"` : `9.772 s`, `5.939 s`, `3.264 s` ;
  - `time docker exec todo-docker-app-1 true` : `5.501 s`, donc c'est le lancement même d'un `exec` qui est lent, pas l'application ;
  - `docker stats` : app `58.39MiB / 128MiB`, la limite mémoire du conteneur n'est pas en cause ; hôte : `RAM libre : 0,6 Go / 15,7 Go`.
- Cause : sur l'hôte saturé, l'exécution d'une commande dans un conteneur dépasse le `timeout: 3s` du healthcheck.
- Correction : `compose.yaml`, `timeout: 10s` sur les healthchecks de `proxy`, `app` et `db` (au-dessus de la pire mesure, 9,8 s).

### 2026-10-09 16:44 : `docker compose down` échoue en 502
- Commande : `./scripts/smoke.sh`, étape 13 (`docker compose down`)
- Message exact :
  ```
  [13] ECHEC  Persistance : tâche présente après down puis up (volume todo-docker_pgdata)
  --- dernière sortie ---
   Container todo-docker-proxy-1 Stopping
   Container todo-docker-proxy-1 Stopped
   Container todo-docker-proxy-1 Removing
   Container todo-docker-proxy-1 Removed
   Container todo-docker-app-1 Stopping
   Container todo-docker-app-1 Error Error while Stopping
  request returned 502 Bad Gateway for API route and version http://%2F%2F.%2Fpipe%2FdockerDesktopLinuxEngine/v1.54/containers/772ec7c7e3f24a23d2634a3c8e95a3b2078610b195f83099025aee7e2be38b1d/stop, check if the server supports the requested API version
  ```
- Diagnostic :
  - `docker ps -a` : `todo-docker-app-1 Exited (255)`, `todo-docker-db-1 Up 28 seconds (healthy)` ;
  - `docker logs todo-docker-app-1` : `Shutting down`, `Application shutdown complete.`, `Finished server process [1]` : uvicorn a bien reçu SIGTERM et s'est arrêté proprement (CMD en forme exec) ;
  - `docker inspect` de l'app : `ExitCode=255 OOM=false` ;
  - `docker run --rm alpine:3.22 cat /proc/uptime` : `69.86`, la VM Docker Desktop venait de redémarrer (le conteneur kind aussi : `Up 43 seconds`).
- Cause : le backend Docker Desktop (tube nommé `dockerDesktopLinuxEngine`) a répondu 502 puis la VM a redémarré ; ni le projet ni le test ne sont en cause.
- Correction : aucune dans le projet ; `scripts/smoke.sh` relancé.

### 2026-10-09 17:44 : `docker compose restart` échoue sur la base
- Commande : `./scripts/smoke.sh`, étape 12 (`docker compose restart`)
- Message exact :
  ```
  [12] ECHEC  Persistance : tâche présente après docker compose restart
  --- dernière sortie ---
   Container todo-docker-app-1 Restarting
   Container todo-docker-db-1 Restarting
   Container todo-docker-proxy-1 Restarting
   Container todo-docker-proxy-1 Started
   Container todo-docker-app-1 Started
  Error response from daemon: Cannot restart container d1f3efd3f5dfb2ace073a504ff83a05b53361241be786790ee736f135be7bffc: tried to kill container, but did not receive an exit event
  ```
- Diagnostic :
  - `docker ps -a` : `d1f3efd3f5df   todo-docker-db-1   Exited (0) 51 seconds ago` ;
  - `docker compose logs db` : `received fast shutdown request` puis `database system is shut down` 0,6 s plus tard : PostgreSQL s'est arrêté proprement ;
  - `docker inspect -f '{{.Config.StopTimeout}}'` sur les 3 conteneurs : `StopTimeout=1` ; `docker compose config | grep -i stop` : rien ; `docker create alpine:3.22 true` puis inspect : `StopTimeout=1` aussi. C'est donc la valeur par défaut de ce moteur, pas celle du projet ;
  - conteneur de test qui ignore SIGTERM (`trap "" TERM`) : `docker stop` en `6.067 s`, `ExitCode=137` (SIGKILL), alors que les seuls appels API prenaient déjà environ 5 s. Le délai avant SIGKILL est bien d'environ 1 s, pas des 10 s habituels ;
  - au démarrage précédent (après le redémarrage de la VM), les logs montraient déjà `database system was not properly shut down; automatic recovery in progress`.
- Cause : avec 1 s seulement avant SIGKILL, le moteur tue la base s'il juge l'arrêt trop lent ; sur l'hôte saturé, l'événement de fin du processus n'est pas remonté à temps et le `restart` échoue.
- Correction : `compose.yaml`, `stop_grace_period: 10s` sur `db` et `app`, pour ne plus dépendre du défaut du moteur (PostgreSQL a le temps d'écrire son checkpoint d'arrêt).

### 2026-10-09 17:52 : le proxy reste `unhealthy` alors qu'il répond
- Commande : `./scripts/smoke.sh`, étape 2 (`docker compose up -d --build --wait`), juste après l'incident précédent
- Message exact :
  ```
  [02] ECHEC  docker compose up -d --build --wait
  --- dernière sortie ---
  ...
   Container todo-docker-proxy-1 Running
  ...
  container todo-docker-proxy-1 is unhealthy
  ```
- Diagnostic :
  - `docker inspect --format '{{json .State.Health}}' todo-docker-proxy-1` : `unhealthy FailingStreak= 28`, chaque essai en échec avec `OCI runtime exec failed: exec failed: unable to start container process: error starting setns process: fork/exec /proc/self/fd/6: no such file or directory` ;
  - `docker ps` : `todo-docker-proxy-1   Up 6 minutes (unhealthy)`, alors que `curl http://localhost:8080/nginx-health` renvoie `ok [200]` : Nginx fonctionne, c'est le lancement du healthcheck (un `exec` dans le conteneur) qui échoue au niveau du runtime.
- Cause : le conteneur proxy a été laissé dans un état incohérent par l'échec du `restart` (entrée précédente) ; `up` ne recrée pas un conteneur dont la configuration n'a pas changé, il restait donc dans cet état.
- Correction : aucune dans le projet ; `docker compose down` (117 s sur la machine saturée, volume conservé) puis nouveau passage de `scripts/smoke.sh`.

### 2026-10-09 18:27 : `mesures.sh` s'arrête au nettoyage de l'image naïve
- Commande : `bash scripts/mesures.sh --destructive --compare-third-service`
- Message exact (fin de `docs/mesures/06-taille-naive.txt`) :
  ```
  $ docker rmi python:3.13.16-trixie   (téléchargée uniquement pour cette mesure)
  Error response from daemon: No such image: python:3.13.16-trixie
  ```
- Diagnostic : `docker image ls python` ne liste que `python:3.13.16-slim-trixie` (et une image d'un autre projet) ; `docs/mesures/07-tailles-autres-images.txt` affiche un tableau vide pour `python:3.13.16-trixie`, alors que le build naïf venait d'utiliser cette base.
- Cause : avec le magasin d'images containerd de Docker Desktop, `docker build` récupère la base pour le build sans créer d'image nommée dans `docker image ls`. Mon script supposait le contraire ; avec `set -e`, l'échec du `docker rmi` a arrêté le script (les fichiers modifiés ont bien été restaurés par le `trap`, `git diff` vide).
- Correction : `scripts/mesures.sh`, `docker pull -q python:3.13.16-trixie` explicite avant le build naïf (taille mesurable en 07, suppression possible ensuite), puis nouveau passage complet du script.
