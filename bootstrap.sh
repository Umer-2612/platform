#!/usr/bin/env bash
# Sets up everything needed to run this project: installs age/direnv if
# missing, decrypts the shared secrets vault, clones every service repo
# listed in repos.manifest into services/, and trusts each one's .envrc.
# Safe to re-run: already-cloned repos are skipped, not re-cloned.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Checking for git..."
command -v git >/dev/null || { echo "git is required, install it first."; exit 1; }

echo "==> Checking for age and direnv..."
for tool in age direnv; do
  if ! command -v "$tool" >/dev/null; then
    if command -v brew >/dev/null; then
      echo "    Installing $tool via Homebrew..."
      brew install "$tool"
    else
      echo "    Homebrew not found. Install $tool yourself, then re-run this script:"
      echo "    https://github.com/FiloSottile/age  /  https://direnv.net"
      exit 1
    fi
  fi
done

if ! grep -q "direnv hook" "$HOME/.zshrc" 2>/dev/null; then
  echo "==> Hooking direnv into zsh..."
  printf '\neval "$(direnv hook zsh)"\n' >> "$HOME/.zshrc"
  echo "    Open a new terminal (or run: source ~/.zshrc) for this to take effect."
fi

VAULT_DIR="$HOME/.secrets-vault"
if [ -d "$VAULT_DIR" ]; then
  echo "==> secrets-vault already cloned, pulling the latest..."
  (cd "$VAULT_DIR" && git pull -q)
else
  echo "==> Cloning secrets-vault..."
  git clone https://github.com/Umer-2612/secrets-vault.git "$VAULT_DIR"
fi

echo "==> Decrypting secrets (enter the shared passphrase when asked)..."
(cd "$VAULT_DIR" && ./setup.sh)

mkdir -p services

# Read the manifest from file descriptor 3, not stdin (fd 0), so a while-read
# loop over the file doesn't collide with any interactive prompt run inside it.
while IFS='=' read -r name url <&3; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac

  target="services/$name"
  if [ -d "$target" ]; then
    echo "==> $name already exists at $target, skipping clone."
  else
    echo "==> Cloning $name..."
    git clone "$url" "$target"
  fi

  echo "==> Trusting $name's .envrc..."
  (cd "$target" && direnv allow)
done 3< repos.manifest

echo "==> Trusting this folder's .envrc..."
direnv allow

cat <<'EOF'

Done. Every service is cloned into services/<name>, and secrets are cached
at ~/.config/interview-platform/env/.

Next:
  docker compose up
EOF
