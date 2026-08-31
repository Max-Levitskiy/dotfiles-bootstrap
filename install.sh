#!/usr/bin/env bash
# dotfiles-bootstrap — prepare a fresh Mac or Linux (incl. Raspberry Pi 64-bit)
# box, then hand off to the private chezmoi dotfiles repo for the actual sync.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Max-Levitskiy/dotfiles-bootstrap/main/install.sh)"
#
# Use `bash -c "$(curl …)"`, NOT `curl … | bash` — the pipe form steals stdin, so
# neither Homebrew's sudo prompt nor the 1Password steps below can read input.
#
# What it does: installs the foundation (Xcode CLT on macOS, Homebrew, chezmoi,
# 1Password CLI + app), verifies authorization (1Password SSH agent on macOS, a
# plain SSH key on Linux, so the private repo can clone), then runs
# `chezmoi init --apply` on the private dotfiles repo, which owns all config +
# the toolchain. On Linux this always renders the "worker" profile (see
# .chezmoi.toml.tmpl) with a Linux-only Brewfile subset — no GUI casks, no
# launchd-only scripts.
set -euo pipefail

DOTFILES_REPO="git@github.com:Max-Levitskiy/dotfiles.git"
OP_ACCOUNT="my.1password.com"
OP_AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

UNAME_S="$(uname -s)"
IS_DARWIN=""; IS_LINUX=""
case "$UNAME_S" in
  Darwin) IS_DARWIN=1 ;;
  Linux)  IS_LINUX=1 ;;
  *) : ;;
esac
LINUXBREW="/home/linuxbrew/.linuxbrew/bin/brew"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
info() { printf '  \033[34m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
pause(){ printf '\n\033[1m%s\033[0m ' "$1"; read -r _; }

# --- 0. Preconditions --------------------------------------------------------
[ -n "$IS_DARWIN" ] || [ -n "$IS_LINUX" ] || die "This bootstrap targets macOS or Linux (got: $UNAME_S)."
if [ -n "$IS_LINUX" ] && [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "x86_64" ]; then
  die "Homebrew on Linux needs 64-bit (aarch64/x86_64) — got $(uname -m). A 32-bit Raspberry Pi OS image isn't supported; reflash with the 64-bit image."
fi
[ -t 0 ] || die "Run in an interactive terminal — needed for the password and 1Password prompts.
Use:  bash -c \"\$(curl -fsSL <url>/install.sh)\"   (not  curl … | bash)"
bold "Bootstrapping $(scutil --get LocalHostName 2>/dev/null || hostname -s)…"

# --- 1. Xcode Command Line Tools (git) — macOS only --------------------------
if [ -n "$IS_DARWIN" ]; then
  step "Xcode Command Line Tools"
  if xcode-select -p >/dev/null 2>&1; then
    ok "already installed"
  else
    info "launching the installer (a GUI dialog will appear)…"
    xcode-select --install || true
    die "Finish the Xcode CLT install in the dialog, then re-run this script."
  fi
fi

# --- 1b. Homebrew build prerequisites — Linux only ---------------------------
if [ -n "$IS_LINUX" ]; then
  step "Homebrew prerequisites"
  if command -v apt-get >/dev/null 2>&1; then
    info "apt-get install build-essential procps curl file git zsh (will prompt for your password)…"
    sudo apt-get update -y && sudo apt-get install -y build-essential procps curl file git zsh
  else
    warn "no apt-get found — install build-essential/procps/curl/file/git/zsh for your distro manually if the Homebrew install below fails."
  fi
fi

# --- 1c. Default shell: zsh — Linux only -------------------------------------
# macOS ships zsh as the default login shell already; Raspberry Pi OS (and most
# Debian-based distros) default to bash, so the chezmoi-managed .zshrc/.zshenv
# would silently never load without this.
if [ -n "$IS_LINUX" ] && command -v zsh >/dev/null 2>&1; then
  step "Default shell"
  ZSH_PATH="$(command -v zsh)"
  CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
  if [ "$CURRENT_SHELL" = "$ZSH_PATH" ]; then
    ok "already zsh"
  else
    grep -qxF "$ZSH_PATH" /etc/shells 2>/dev/null || echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
    if sudo chsh -s "$ZSH_PATH" "$USER"; then
      ok "set to $ZSH_PATH (takes effect on your next login)"
    else
      warn "couldn't chsh automatically — run: sudo chsh -s $ZSH_PATH $USER"
    fi
  fi
fi

# --- 2. Homebrew (plain shell → sudo prompts work) --------------------------
step "Homebrew"
if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ] || [ -x "$LINUXBREW" ]; then
  ok "already installed"
else
  info "installing (will prompt for your password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x "$LINUXBREW" ] && eval "$("$LINUXBREW" shellenv)"
command -v brew >/dev/null 2>&1 || die "Homebrew is not on PATH after install."
ok "$(brew --version | head -1)"

# --- 3. Foundation packages: chezmoi, 1Password CLI (+ app on macOS) --------
step "chezmoi + 1Password"
command -v chezmoi >/dev/null 2>&1 || { info "brew install chezmoi";       brew install chezmoi; }
command -v op      >/dev/null 2>&1 || { info "brew install 1password-cli";  brew install 1password-cli; }
if [ -n "$IS_DARWIN" ]; then
  [ -d "/Applications/1Password.app" ] || { info "brew install --cask 1password"; brew install --cask 1password || warn "install the 1Password app manually if this failed"; }
fi
ok "chezmoi + op installed"

# --- 4. Unlock 1Password — macOS only ----------------------------------------
# The SSH agent only serves keys while the app session is unlocked, and secrets
# need the CLI authenticated. Touch the CLI to trigger an unlock (Touch ID).
# On Linux there's no automated 1Password GUI flow here: auth for the clone
# below is a plain SSH key, and secrets stay opt-in via OP_SERVICE_ACCOUNT_TOKEN
# (the worker profile already renders without secrets otherwise).
if [ -n "$IS_DARWIN" ]; then
  step "Unlock 1Password"
  [ -S "$OP_AGENT_SOCK" ] && export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
  # Best-effort: a single `op` call triggers the app's Touch ID unlock (when CLI
  # integration is on), activating the SSH agent + enabling secrets. Never blocks —
  # the clone below is the real gate.
  if command -v op >/dev/null 2>&1; then
    if op whoami >/dev/null 2>&1; then
      ok "1Password unlocked ($(op whoami 2>/dev/null | head -1))"
    else
      warn "1Password CLI not authenticated — enable Settings → Developer → \"Integrate with 1Password CLI\" for secrets; the clone will still test SSH auth."
    fi
  fi
else
  step "GitHub SSH auth"
  if ! ssh -T git@github.com -o BatchMode=yes -o ConnectTimeout=5 2>&1 | grep -qi "successfully authenticated"; then
    warn "no working SSH key for git@github.com yet — the clone below will retry until one is added:"
    cat <<EOF
    1. If needed: ssh-keygen -t ed25519 -C "$(hostname -s)" (accept the default path, empty passphrase is fine for a home box)
    2. cat ~/.ssh/id_ed25519.pub and add it as a deploy key (read access) on github.com/Max-Levitskiy/dotfiles, or as a personal SSH key
EOF
  else
    ok "SSH auth to github.com already works"
  fi
fi

# --- 5. Clone the private repo — the clone itself IS the auth test ----------
step "Cloning dotfiles"
until chezmoi init "$DOTFILES_REPO"; do
  warn "Clone failed — GitHub SSH auth isn't ready yet."
  if [ -n "$IS_DARWIN" ]; then
    cat <<EOF
    1. Open the 1Password app and sign in to your personal account: $OP_ACCOUNT
    2. Settings → Developer → turn ON "Use the SSH agent" and "Integrate with 1Password CLI".
    3. Accept 1Password's offer to add its agent to ~/.ssh/config.
EOF
  else
    cat <<EOF
    1. ssh-keygen -t ed25519 -C "$(hostname -s)" if you don't have a key yet
    2. Add ~/.ssh/id_ed25519.pub as a deploy key on github.com/Max-Levitskiy/dotfiles (or your GitHub account's SSH keys)
    3. Test with: ssh -T git@github.com
EOF
  fi
  pause "Press Enter to retry (Ctrl-C to abort)…"
  [ -n "$IS_DARWIN" ] && [ -S "$OP_AGENT_SOCK" ] && export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
done
ok "cloned"

# --- 6. Optional: enable 1Password secrets on this machine ------------------
WANT_OP=""
if [ -n "$IS_DARWIN" ] && op whoami >/dev/null 2>&1; then
  printf '\n  \033[1mSync your 1Password secrets (API keys) onto this machine? [y/N]\033[0m '
  read -r reply
  case "$reply" in [yY]*) WANT_OP=1; ok "secrets will be applied" ;; *) info "skipping secrets (run 'USE_OP=1 chezmoi apply' later to add them)" ;; esac
elif [ -n "$IS_LINUX" ]; then
  info "worker profile — applying without secrets by default (set OP_SERVICE_ACCOUNT_TOKEN or USE_OP=1, then 'chezmoi apply', to add them later)"
else
  info "1Password CLI not authenticated — applying without secrets (enable CLI integration, then 'USE_OP=1 chezmoi apply')"
fi

# --- 7. Apply: dotfiles + toolchain ----------------------------------------
step "Applying (dotfiles + toolchain)"
if [ -n "$WANT_OP" ]; then USE_OP=1 chezmoi apply; else chezmoi apply; fi

step "Done"
ok "Machine bootstrapped and synced."
bold "Open a new terminal to load your shell. From now on it's just: chezmoi apply"
