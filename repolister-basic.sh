#!/bin/bash
# ------------------------------------------------------------
# GitHub / Gitea fájllista generátor
# 1 sor = 1 fájl teljes RAW URL-lel
# A lista létrehozása után törli a klónozott repo mappát.
# Kizárja a megadott fájlokat és mappákat.
# ------------------------------------------------------------

echo "Git server domain name (github.com or gitea.sajatdomain.hu):"
read DOMAIN

echo "Repo owner or username:"
read USER

echo "Repo name:"
read REPO

OUTFILE="${REPO}.txt"

# Klónozás, ha szükséges
if [ ! -d "$REPO/.git" ]; then
    echo "Repo is not cloned yet. Start cloning..."
    git clone --quiet "https://$DOMAIN/$USER/$REPO.git" || { echo "Error: cloning failed."; exit 1; }
else
    echo "Repo is exist. No need to clone."
fi

cd "$REPO" || { echo "Error: repo directory is not found."; exit 1; }

# Branch lekérése, fallback main/master
BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
    if git rev-parse --verify main >/dev/null 2>&1; then
        BRANCH="main"
    else
        BRANCH="master"
    fi
fi

echo "Active branch: $BRANCH"
echo "Creating file list..."

# RAW URL prefix
if [[ "$DOMAIN" == *"github.com"* ]]; then
    PREFIX="https://raw.githubusercontent.com/$USER/$REPO/$BRANCH/"
else
    PREFIX="https://$DOMAIN/$USER/$REPO/raw/branch/$BRANCH/"
fi

# Fájllista generálás szűréssel
git ls-files | grep -Ev '(^vendor/|^vendor$|\.mo$|\.gitignore$|LICENSE\.md$|composer.*|package.*|\.htaccess$|favicon\.ico$|\.jpg$|\.jpeg$|\.png$|\.gif$|\.svg$|\.bmp$|\.webp$|\.mp3$|\.wav$|\.ogg$|\.mp4$|\.mov$|\.avi$|\.mkv$)' \
| while read file; do
    echo "${PREFIX}${file}"
done > "../exports/$OUTFILE"

cd ..

# Repo törlése
echo "Cleaning: cloned repo delete..."
rm -rf "$REPO"

echo "✅ File list prepared: $(realpath "$OUTFILE")"
