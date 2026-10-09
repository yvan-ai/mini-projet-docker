# Pas de directive "# syntax=" : on utilise le parseur Dockerfile intégré au moteur (BuildKit).
# Le frontend externe docker/dockerfile tournait dans un conteneur à part qui plantait par
# intermittence sur ma machine (docs/JOURNAL.md) ; aucune instruction utilisée ici ne l'exige.

# Image officielle, tag figé : version Python complète + variante slim + Debian nommée (trixie = 13).
# slim : glibc (compatible avec les wheels binaires de PyPI) sans compilateurs ni en-têtes
# de l'image complète. Pas d'alpine : musl obligerait parfois à compiler les dépendances.
FROM python:3.13.16-slim-trixie

# PYTHONDONTWRITEBYTECODE : pas de fichiers .pyc écrits dans le conteneur.
# PYTHONUNBUFFERED : logs non bufferisés, visibles immédiatement dans docker compose logs.
# PIP_NO_CACHE_DIR : pip ne garde pas les archives téléchargées dans l'image.
# PIP_DISABLE_PIP_VERSION_CHECK : pas d'appel réseau inutile pour vérifier la version de pip.
# PIP_ROOT_USER_ACTION=ignore : installer en root est normal dans une image (pas de paquets
# système à abîmer) ; on coupe l'avertissement pip correspondant.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

# Répertoire de travail : les COPY et le CMD sont relatifs à /app.
WORKDIR /app

# Utilisateur système non root, créé tôt car cette couche ne change jamais.
# Si l'application est compromise, l'attaquant n'est pas root dans le conteneur.
RUN groupadd --system app && useradd --system --gid app --no-create-home app

# 1) Dépendances : copiées et installées AVANT le code.
#    Tant que requirements.txt ne change pas, ces deux couches restent en cache.
#    Aucun apt-get : psycopg[binary] fournit libpq précompilée.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 2) Code applicatif : la couche la plus volatile, en dernier.
#    src/app/ devient /app/app/, d'où le module "app.main:app" du CMD.
COPY src/ .

# Les instructions suivantes s'exécutent et le conteneur tourne sous cet utilisateur.
USER app

# Documentation du port interne écouté par uvicorn (n'ouvre rien sur l'hôte).
EXPOSE 8000

# Forme exec (tableau JSON) : uvicorn est le PID 1 et reçoit directement SIGTERM (arrêt propre).
# --host 0.0.0.0 : écoute sur toutes les interfaces du conteneur, sinon le proxy ne peut pas le joindre.
# Un seul worker pour limiter la mémoire.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
