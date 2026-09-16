#!/usr/bin/env bash
# Clones every service repo listed in repos.manifest into services/, and
# gets each one linked to Infisical so nobody hand-manages a .env file.
# Safe to re-run: already-cloned repos are skipped, not re-cloned.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Checking for git..."
command -v git >/dev/null || { echo "git is required, install it first."; exit 1; }

echo "==> Checking for the Infisical CLI..."
if ! command -v infisical >/dev/null; then
  if command -v brew >/dev/null; then
    echo "    Not found, installing via Homebrew..."
    brew install infisical/get-cli/infisical
  else
    echo "    Homebrew not found. Install the Infisical CLI yourself:"
    echo "    https://infisical.com/docs/cli/overview"
    exit 1
  fi
fi

echo "==> Logging in to Infisical (opens a browser)..."
infisical login

mkdir -p services

while IFS='=' read -r name url; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac

  target="services/$name"
  if [ -d "$target" ]; then
    echo "==> $name already exists at $target, skipping clone."
    continue
  fi

  echo "==> Cloning $name..."
  git clone "$url" "$target"

  echo "==> Linking $name to the Infisical project (pick the same org/project every time)..."
  (cd "$target" && infisical init)
done < repos.manifest

cat <<'EOF'

Done. Each service is cloned into services/<name> and linked to Infisical.

Next, per service you want to run (see each one's own README for exact
commands, they differ by stack):
  cd services/<name>
  npm install
  npm run dev
EOF
