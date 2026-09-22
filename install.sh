#!/usr/bin/env bash
#
# install.sh - dependency check for the standalone azure-cli launcher:
# installs/checks Neovim, git (Git for Windows on Windows) and python 3 -
# azure-cli.py's runtime; every PR and work-item call goes through it.
# Nothing at runtime needs bash, and nothing here touches the config file:
# the first `./azure-cli` (or `:AzureCli` as a plugin) writes the
# azure-cli.yml template at its platform location and opens it for you -
# see lua/azure-cli/firstrun.lua and `azure-cli --init-config`.
#
# Safe to re-run: it skips anything already installed. There is no build
# step - azure-cli.py is the data provider, run directly by python (via the
# "azure-cli"/"azure-cli.cmd" launcher scripts), no compilation needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# Asks before anything that changes the system (a package install). "-y"
# on the command line, or no terminal to ask on, answers yes.
ASSUME_YES=false
for a in "$@"; do [[ "$a" == "-y" || "$a" == "--yes" ]] && ASSUME_YES=true; done
confirm() {
  if $ASSUME_YES || [[ ! -t 0 ]]; then return 0; fi
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == [yY]* ]]
}

# ---------------------------------------------------------------------------
# 1. OS detection
# ---------------------------------------------------------------------------
IS_WINDOWS=false
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

# ---------------------------------------------------------------------------
# 2. Dependencies
# ---------------------------------------------------------------------------
log "Checking dependencies..."

install_neovim() {
  if command -v nvim >/dev/null 2>&1; then
    log "Neovim already installed ($(nvim --version 2>/dev/null | head -n1))."
    return
  fi

  log "Neovim not found."
  confirm "Install Neovim now (uses winget/apt/dnf/brew, may ask for sudo)?" || { warn "Skipping Neovim - install it from https://neovim.io before running azure-cli."; return; }
  if $IS_WINDOWS; then
    if command -v winget >/dev/null 2>&1; then
      winget install --id Neovim.Neovim -e --source winget
    else
      warn "winget not found. Install Neovim manually from https://github.com/neovim/neovim/releases"
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y neovim
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y neovim
  elif command -v brew >/dev/null 2>&1; then
    brew install neovim
  else
    warn "No supported package manager found. Install Neovim manually from https://neovim.io"
  fi
}

install_git() {
  if command -v git >/dev/null 2>&1; then
    log "git already installed ($(git --version 2>/dev/null))."
    return
  fi

  log "git not found."
  confirm "Install git now (uses winget/apt/dnf/brew, may ask for sudo)?" || { warn "Skipping git - install it from https://git-scm.com before running azure-cli."; return; }
  if $IS_WINDOWS; then
    if command -v winget >/dev/null 2>&1; then
      winget install --id Git.Git -e --source winget
    else
      warn "winget not found. Install Git for Windows manually from https://git-scm.com/download/win"
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git
  elif command -v brew >/dev/null 2>&1; then
    brew install git
  else
    warn "No supported package manager found. Install git manually from https://git-scm.com"
  fi
}

install_python() {
  # Runs azure-cli.py, the data provider itself - every REST call this
  # tool makes, for PRs and work items alike, goes through it.
  if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    log "python already installed."
    return
  fi

  log "python not found."
  confirm "Install Python 3 now (uses winget/apt/dnf/brew, may ask for sudo)?" || { warn "Skipping python - install it from https://www.python.org/downloads/ before running azure-cli."; return; }
  if $IS_WINDOWS; then
    if command -v winget >/dev/null 2>&1; then
      winget install --id Python.Python.3.12 -e --source winget
    else
      warn "winget not found. Install Python manually from https://www.python.org/downloads/"
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y python3
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y python3
  elif command -v brew >/dev/null 2>&1; then
    brew install python3
  else
    warn "No supported package manager found. Install Python manually from https://www.python.org/downloads/"
  fi
}

install_neovim
install_git
install_python

chmod +x "$REPO_ROOT/azure-cli" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Done
# ---------------------------------------------------------------------------
log "Done. Run './azure-cli' (or 'azure-cli.cmd' on Windows): the first launch"
log "creates the config file (%APPDATA%\\azure-cli.yml on Windows, \$XDG_CONFIG_HOME/"
log "azure-cli.yml elsewhere) with TODO placeholders and opens it for you to fill in."
log "Tip: add $REPO_ROOT to your PATH to run 'azure-cli' from anywhere."
