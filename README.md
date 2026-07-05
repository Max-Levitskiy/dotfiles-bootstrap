# dotfiles-bootstrap

Public, one-command bootstrap for a fresh Mac. Installs the foundation, sets up
1Password auth, then hands off to my **private** [`dotfiles`](https://github.com/Max-Levitskiy/dotfiles)
repo (managed with [chezmoi](https://chezmoi.io)) for the actual sync.

## Usage

Run **at the machine**, or over `ssh -t` (so Homebrew's `sudo` can prompt):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Max-Levitskiy/dotfiles-bootstrap/main/install.sh)"
```

> Use `bash -c "$(curl …)"`, **not** `curl … | bash` — the pipe form steals stdin,
> so the password and 1Password prompts can't read your input. The script refuses
> to run non-interactively for this reason.

## What it does

1. **Xcode Command Line Tools** — installs if missing.
2. **Homebrew** — installed in a plain shell, so `sudo` works reliably.
3. **Foundation** — `brew install chezmoi 1password-cli` + the 1Password app.
4. **Authorization** — points `SSH_AUTH_SOCK` at 1Password's agent and loops until
   `ssh -T git@github.com` authenticates, guiding you through the 1Password sign-in
   and **SSH agent** / **CLI integration** toggles (Settings → Developer). This is
   the credential a private repo needs before it can clone.
5. **Secrets (optional)** — if `op` is authenticated, offers to sync your 1Password
   secrets onto this machine.
6. **Sync** — `chezmoi init --apply` on the private repo; chezmoi then applies all
   dotfiles and installs the toolchain.

Idempotent and safe to re-run: every step checks before acting.

## Why two repos

- **This repo (public):** *how to prepare any Mac* — foundation + auth. No secrets,
  so it's safe to be public (and it must be, because a bare machine can't fetch a
  private script before it has credentials).
- **[`dotfiles`](https://github.com/Max-Levitskiy/dotfiles) (private):** *my config*
  — dotfiles, Brewfile/toolchain, and 1Password secret references.

When `install.sh` changes here, that's the single source — nothing to mirror.
