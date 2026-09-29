#!/usr/bin/env bash
# One command to catch up with everything pushed since you last ran it:
# pulls this repo and every service in repos.manifest, refreshes the env files
# when the secrets vault changed, and rebuilds/migrates only if it has to.
# Safe to re-run. A service with local changes, or checked out on another
# branch, is skipped with a warning instead of being touched.
#
#   ./update.sh              pull everything, then update running containers
#   ./update.sh --no-docker  pull only, leave Docker alone
set -euo pipefail
cd "$(dirname "$0")"

USE_DOCKER=1
[ "${1:-}" = "--no-docker" ] && USE_DOCKER=0

# If pulling this repo changed update.sh itself, restart on the new version.
if [ -z "${UPDATE_REEXEC:-}" ]; then
  before="$(git rev-parse HEAD)"
  echo "==> Updating platform..."
  git pull -q --ff-only || { echo "    Could not fast-forward platform (local changes or another branch?), continuing."; }
  if [ "$before" != "$(git rev-parse HEAD)" ]; then
    export UPDATE_REEXEC=1
    # Remember the compose file changed, the restarted run can't see the old commit.
    git diff --quiet "$before" HEAD -- docker-compose.yml || export PLATFORM_REBUILD=1
    exec "$0" "$@"
  fi
fi

NEEDS_REBUILD="${PLATFORM_REBUILD:-0}"
NEEDS_MIGRATE=0
PLATFORM_ENV="$HOME/.config/interview-platform"
mkdir -p "$PLATFORM_ENV"

# Secrets vault: only prompts for the passphrase when the vault actually changed.
VAULT_DIR="$HOME/.secrets-vault"
if [ -d "$VAULT_DIR" ]; then
  echo "==> Checking secrets vault..."
  (cd "$VAULT_DIR" && git pull -q --ff-only) || echo "    Could not update the vault, keeping the env files you have."
  vault_rev="$(cd "$VAULT_DIR" && git rev-parse HEAD)"
  if [ "$vault_rev" != "$(cat "$PLATFORM_ENV/.vault-rev" 2>/dev/null || true)" ]; then
    echo "    Vault changed, refreshing env files."
    (cd "$VAULT_DIR" && ./setup.sh)
    echo "$vault_rev" > "$PLATFORM_ENV/.vault-rev"
    NEEDS_REBUILD=1 # containers only read env at start
  else
    echo "    Env files already current."
  fi
else
  echo "==> No secrets vault found. Run ./bootstrap.sh first."
  exit 1
fi

# Services: clone anything new, fast-forward everything clean on its default branch.
while IFS='=' read -r name url <&3; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  target="services/$name"

  if [ ! -d "$target" ]; then
    echo "==> $name is new, cloning..."
    git clone -q "$url" "$target"
    (cd "$target" && direnv allow)
    NEEDS_REBUILD=1
    continue
  fi

  cd "$target"
  default="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  default="${default:-main}"
  current="$(git branch --show-current)"

  if [ "$current" != "$default" ]; then
    echo "==> $name: on '$current', not '$default', skipping."
  elif [ -n "$(git status --porcelain)" ]; then
    echo "==> $name: has local changes, skipping."
  else
    before="$(git rev-parse HEAD)"
    git pull -q --ff-only
    after="$(git rev-parse HEAD)"
    if [ "$before" = "$after" ]; then
      echo "==> $name: already up to date."
    else
      echo "==> $name: updated ($(git rev-list --count "$before..$after") new commits)."
      changed="$(git diff --name-only "$before" "$after")"
      # Source is bind-mounted and hot-reloads. These need a fresh image.
      if echo "$changed" | grep -Eq '(^|/)(package(-lock)?\.json|Dockerfile|\.dockerignore)$|^prisma/schema\.prisma$'; then
        NEEDS_REBUILD=1
      fi
      if [ "$name" = "core-api" ] && echo "$changed" | grep -q '^prisma/migrations/'; then
        NEEDS_MIGRATE=1
      fi
    fi
  fi
  cd - >/dev/null
done 3< repos.manifest

if [ "$USE_DOCKER" -eq 0 ]; then
  echo "==> Skipping Docker (--no-docker)."
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  echo "==> Docker isn't running. Start it, then run: docker compose up"
  exit 0
fi

# Env comes from direnv, so run compose through it. Works even if the shell hook isn't loaded.
if [ "$NEEDS_REBUILD" -eq 1 ]; then
  echo "==> Rebuilding containers (dependencies, Dockerfile, schema or env changed)..."
  direnv exec . docker compose up -d --build
else
  echo "==> No rebuild needed, code changes are picked up live."
  direnv exec . docker compose up -d
fi

if [ "$NEEDS_MIGRATE" -eq 1 ]; then
  echo "==> Applying database migrations..."
  direnv exec . docker compose exec -T core-api npx prisma migrate deploy
fi

echo
echo "Up to date. Web: http://localhost:3000  API: http://localhost:4000"
