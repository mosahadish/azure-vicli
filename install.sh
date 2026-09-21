#!/usr/bin/env bash
#
# install.sh - one-shot setup for azure-cli:
#   1. Installs/checks the required dependencies: Neovim, git (Git for
#      Windows on Windows) and python 3 - azure-cli.py's runtime; every PR
#      and work-item call goes through it. Nothing at runtime needs bash.
#   2. Creates the azure-cli.yml config file (if it doesn't already exist) at
#      the location azure-cli.py reads it from (%APPDATA% on Windows, the
#      XDG config dir elsewhere), with a guessed clones_dir on Windows and
#      placeholders for everything else (org_url/pat/project_name and the
#      optional work_items block).
#   3. Opens the config file in an editor so the user can fill in the rest.
#
# Safe to re-run: it skips anything already installed/present, and never
# overwrites an existing config file. There is no build step - azure-cli.py
# is the data provider, run directly by python (via the "azure-cli"/
# "azure-cli.cmd" launcher scripts), no compilation needed.
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
# 3. Config file
# ---------------------------------------------------------------------------
if $IS_WINDOWS; then
  APPDATA_WIN="${APPDATA:-}"
  if [[ -z "$APPDATA_WIN" ]]; then
    APPDATA_WIN="$(cmd.exe /c "echo %APPDATA%" 2>/dev/null | tr -d '\r')"
  fi
  CONFIG_DIR="$(printf '%s' "$APPDATA_WIN" | sed 's#\\#/#g; s#^\([A-Za-z]\):#/\L\1#')"
else
  # Same place azure-cli.py looks (Config.path() in azure-cli.py):
  # $XDG_CONFIG_HOME, else ~/.config.
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
fi
mkdir -p "$CONFIG_DIR"

CONFIG_FILE="$CONFIG_DIR/azure-cli.yml"

if [[ -f "$CONFIG_FILE" ]]; then
  log "Config file already exists at $CONFIG_FILE, leaving it untouched."
else
  log "Creating config file at $CONFIG_FILE"


  CLONES_DIR_GUESS=""
  if $IS_WINDOWS; then
    USERPROFILE_WIN="${USERPROFILE:-}"
    [[ -z "$USERPROFILE_WIN" ]] && USERPROFILE_WIN="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')"
    CLONES_DIR_GUESS="${USERPROFILE_WIN}\\source\\repos"
  fi

  {
    echo "# azure-cli configuration file."
    echo "# See README.md for full documentation of every field."
    echo "#"
    echo "# Fill in org_url / pat / project_name for each account below, then"
    echo "# remove any accounts you don't need. Add more accounts by copying"
    echo "# the block under 'accounts:'."
    echo "#"
    echo "# pat: a personal access token, created at"
    echo "#   https://dev.azure.com/<your-org>/_usersSettings/tokens"
    echo "#   (on-prem: <collection-url>/_usersSettings/tokens)"
    echo "# with the scopes  Code: Read & write  and  Work Items: Read & write."
    echo "# It is required - there is no Azure AD fallback."
    echo "#"
    echo "# When done, './azure-cli --doctor' checks the file and signs in to"
    echo "# every organization listed here."
    echo ""
    echo "accounts:"
    echo "  - project_name: # TODO: e.g. sample-project"
    echo "    org_url: # TODO: e.g. https://dev.azure.com/example"
    echo "    pat: # TODO: your personal access token (required - no Azure AD fallback)"
    echo "    hide_ancient: true"
    if [[ -n "$CLONES_DIR_GUESS" ]]; then
      echo "    clones_dir: ${CLONES_DIR_GUESS//\\/\\\\}"
    else
      echo "    # clones_dir: /path/to/where/repos/are/cloned"
    fi
    echo "    # Optional - uncomment to enable the work-item screens (W key)."
    echo "    # work_items:"
    echo "    #   team: # TODO: e.g. My Team (required)"
    echo "    #   assignee: # optional; default = your signed-in display name"
    echo "    #   types: [User Story, Bug]  # optional; default shown"
    echo "    #   states: [New, Active, Resolved, Closed, Removed]  # optional; order = rank"
    echo "    #   sprint_scope: parent  # optional; parent (tabs under the current sprint's parent) or all"
    echo ""
    echo "# Plugin users: timing, hide_ancient_days, python and config path are"
    echo "# setup() options in Neovim, not fields here - see README 'setup() options'."
  } > "$CONFIG_FILE"

  log "Config file created. Placeholders marked TODO still need to be filled in."
fi

# ---------------------------------------------------------------------------
# 4. Options file (keys, timing, ...) for the standalone launcher
# ---------------------------------------------------------------------------
# azure-cli.lua next to azure-cli.yml holds setup() options with every value
# at its default, generated by the plugin itself so it matches the code. Never
# overwritten: an existing file (the user's edits) is left exactly as it is.
OPTIONS_FILE="$CONFIG_DIR/azure-cli.lua"
if [[ -f "$OPTIONS_FILE" ]]; then
  log "Options file already exists at $OPTIONS_FILE, leaving it untouched."
elif command -v nvim >/dev/null 2>&1; then
  if nvim --headless --cmd "set rtp+=$REPO_ROOT" \
       -c "lua local p, ok = require('azure-cli.config').write_options(); if not ok then vim.cmd('cquit') end" \
       -c 'qa!' >/dev/null 2>&1; then
    log "Wrote $OPTIONS_FILE with every option at its default (edit it to remap keys etc.)."
  else
    warn "Could not write $OPTIONS_FILE; run ':AzureCli options' from Neovim later."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Open the config file for editing
# ---------------------------------------------------------------------------
log "Opening $CONFIG_FILE for editing..."
if $IS_WINDOWS; then
  CONFIG_FILE_WIN="$(printf '%s' "$CONFIG_FILE" | sed 's#^/\([a-zA-Z]\)/#\U\1:/#; s#/#\\#g')"
  if command -v nvim >/dev/null 2>&1; then
    nvim "$CONFIG_FILE"
  elif command -v code >/dev/null 2>&1; then
    code "$CONFIG_FILE_WIN"
  else
    cmd.exe /c start notepad "$CONFIG_FILE_WIN"
  fi
else
  "${EDITOR:-${VISUAL:-nvim}}" "$CONFIG_FILE" 2>/dev/null \
    || nano "$CONFIG_FILE" 2>/dev/null \
    || vi "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# 6. Check what was just written: the fields, and a sign-in per organization
# ---------------------------------------------------------------------------
# Catches the two most common first-run mistakes (a TODO line left as it
# was, a PAT that doesn't work) right here, while the file is still open in
# the user's mind - instead of as a failed request inside the dashboard.
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  log "Checking the config..."
  if "$REPO_ROOT/azure-cli" --doctor; then
    log "Done. Run './azure-cli' (or 'azure-cli.cmd' on Windows) to open the dashboard."
  else
    warn "Fix the FAIL line(s) above in $CONFIG_FILE, then run './azure-cli --doctor' again."
  fi
else
  log "Done. Once python is installed, run './azure-cli --doctor' to check the config, then './azure-cli' to open the dashboard."
fi
log "Tip: add $REPO_ROOT to your PATH to run 'azure-cli' from anywhere."
