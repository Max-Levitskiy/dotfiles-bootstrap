#!/usr/bin/env bash
# dotfiles-bootstrap — prepare a fresh Mac, then hand off to the private chezmoi
# dotfiles repo for the actual sync.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Max-Levitskiy/dotfiles-bootstrap/main/install.sh)"
#
# Use `bash -c "$(curl …)"`, NOT `curl … | bash` — the pipe form steals stdin, so
# neither Homebrew's sudo prompt nor the 1Password steps below can read input.
#
# What it does: installs the foundation (Xcode CLT, Homebrew, chezmoi, 1Password
# CLI + app), verifies authorization (1Password SSH agent so the private repo can
# clone), then runs `chezmoi init --apply` on the private dotfiles repo, which owns
# all config + the toolchain.
set -euo pipefail

DOTFILES_REPO="git@github.com:Max-Levitskiy/dotfiles.git"
OP_ACCOUNT="my.1password.com"
OP_AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
info() { printf '  \033[34m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
pause(){ printf '\n\033[1m%s\033[0m ' "$1"; read -r _; }

# --- 0. Preconditions --------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "This bootstrap targets macOS."
[ -t 0 ] || die "Run in an interactive terminal — needed for the password and 1Password prompts.
Use:  bash -c \"\$(curl -fsSL <url>/install.sh)\"   (not  curl … | bash)"
bold "Bootstrapping $(scutil --get LocalHostName 2>/dev/null || hostname -s)…"

# --- 1. Xcode Command Line Tools (git) --------------------------------------
step "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "already installed"
else
  info "launching the installer (a GUI dialog will appear)…"
  xcode-select --install || true
  die "Finish the Xcode CLT install in the dialog, then re-run this script."
fi

# --- 2. Homebrew (plain shell → sudo prompts work) --------------------------
step "Homebrew"
if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
  ok "already installed"
else
  info "installing (will prompt for your password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
command -v brew >/dev/null 2>&1 || die "Homebrew is not on PATH after install."
ok "$(brew --version | head -1)"

# --- 3. Foundation packages: chezmoi, 1Password CLI + app -------------------
step "chezmoi + 1Password"
command -v chezmoi >/dev/null 2>&1 || { info "brew install chezmoi";       brew install chezmoi; }
command -v op      >/dev/null 2>&1 || { info "brew install 1password-cli";  brew install 1password-cli; }
[ -d "/Applications/1Password.app" ] || { info "brew install --cask 1password"; brew install --cask 1password || warn "install the 1Password app manually if this failed"; }
ok "chezmoi + op installed"

# --- 4. Authorization: 1Password SSH agent (required to clone the private repo)
step "1Password authorization"
[ -S "$OP_AGENT_SOCK" ] && export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
github_ok() { ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -qiE "successfully authenticated|^Hi "; }
if github_ok; then
  ok "GitHub SSH auth works (1Password agent)"
else
  cat <<EOF
  $(bold "Set up 1Password so this machine can clone the private dotfiles repo:")
    1. Open the 1Password app and sign in to your personal account: $OP_ACCOUNT
    2. Settings → Developer → turn ON:
         • "Use the SSH agent"            (provides your GitHub key)
         • "Integrate with 1Password CLI" (needed later for secrets)
    3. Accept 1Password's offer to configure the SSH agent.
EOF
  while ! github_ok; do
    pause "Press Enter once 1Password is signed in and the SSH agent is on (Ctrl-C to abort)…"
    [ -S "$OP_AGENT_SOCK" ] && export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
  done
  ok "GitHub SSH auth works"
fi

# --- 5. Optional: enable 1Password secrets on this machine ------------------
WANT_OP=""
if op whoami >/dev/null 2>&1; then
  printf '\n  \033[1mAlso sync your 1Password secrets (API keys) onto this machine? [y/N]\033[0m '
  read -r reply
  case "$reply" in [yY]*) WANT_OP=1; ok "secrets will be applied" ;; *) info "skipping secrets (run 'USE_OP=1 chezmoi apply' later to add them)" ;; esac
else
  info "1Password CLI not authenticated — skipping secrets (enable CLI integration, then 'USE_OP=1 chezmoi apply')"
fi

# --- 6. Hand off to chezmoi + the private dotfiles repo ---------------------
step "Syncing dotfiles"
info "chezmoi init --apply $DOTFILES_REPO"
if [ -n "$WANT_OP" ]; then USE_OP=1 chezmoi init --apply "$DOTFILES_REPO"; else chezmoi init --apply "$DOTFILES_REPO"; fi

step "Done"
ok "Machine bootstrapped and synced."
bold "Open a new terminal to load your shell. From now on it's just: chezmoi apply"
