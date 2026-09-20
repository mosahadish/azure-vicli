#!/usr/bin/env bash
#
# install.sh - one-shot setup for azure-cli:
#   1. Installs/checks the required dependencies (.NET 6 SDK, Neovim, git-bash
#      on Windows, python for the wi-*.sh helper scripts).
#   2. Builds src\azure-cli.csproj.
#   3. Creates the azure-cli.yml config file (if it doesn't already exist) at
#      the location the exe reads it from (%APPDATA% on Windows, the XDG
#      config dir elsewhere), pre-filled with whatever this script can
#      figure out for the current machine (bash_path on Windows, a guessed
#      clones_dir, ...). Everything else (org_url/pat/project_name) is left
#      as a placeholder for the user to fill in.
#   4. Opens the config file in an editor so the user can fill in the rest.
#
# Safe to re-run: it skips anything already installed/present, and never
# overwrites an existing config file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

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

install_dotnet_sdk() {
  if command -v dotnet >/dev/null 2>&1; then
    log "dotnet SDK already installed ($(dotnet --version 2>/dev/null))."
    return
  fi

  log ".NET SDK not found, attempting to install .NET 6 SDK..."
  if $IS_WINDOWS; then
    if command -v winget >/dev/null 2>&1; then
      winget install --id Microsoft.DotNet.SDK.6 -e --source winget
    else
      warn "winget not found. Install the .NET 6 SDK manually from https://dotnet.microsoft.com/download/dotnet/6.0"
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y dotnet-sdk-6.0
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y dotnet-sdk-6.0
  elif command -v brew >/dev/null 2>&1; then
    brew install --cask dotnet-sdk
  else
    warn "No supported package manager found. Install the .NET 6 SDK manually from https://dotnet.microsoft.com/download/dotnet/6.0"
  fi
}

install_neovim() {
  if command -v nvim >/dev/null 2>&1; then
    log "Neovim already installed ($(nvim --version 2>/dev/null | head -n1))."
    return
  fi

  log "Neovim not found, attempting to install..."
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

find_git_bash() {
  # Well-known Git-for-Windows locations, same order azure-cli.exe probes.
  local candidates=(
    "/c/Program Files/Git/bin/bash.exe"
    "/c/Program Files/Git/usr/bin/bash.exe"
    "${LOCALAPPDATA:-}/Programs/Git/bin/bash.exe"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] && { printf '%s\n' "$c" | sed 's#^/c/#C:\\#; s#/#\\#g'; return; }
  done
  printf ''
}

install_git_bash() {
  $IS_WINDOWS || return 0

  if [[ -n "$(find_git_bash)" ]]; then
    log "git-bash already installed."
    return
  fi

  log "git-bash not found, attempting to install Git for Windows..."
  if command -v winget >/dev/null 2>&1; then
    winget install --id Git.Git -e --source winget
  else
    warn "winget not found. Install Git for Windows manually from https://git-scm.com/download/win"
  fi
}

install_python() {
  # Used by wi-list.sh / wi-detail.sh to talk to the Azure DevOps REST API.
  if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    log "python already installed."
    return
  fi

  log "python not found, attempting to install..."
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

install_dotnet_sdk
install_neovim
install_git_bash
install_python

# ---------------------------------------------------------------------------
# 3. Build
# ---------------------------------------------------------------------------
if command -v dotnet >/dev/null 2>&1; then
  log "Building azure-cli (dotnet build)..."
  dotnet build "$REPO_ROOT/src/azure-cli.csproj"
else
  warn "Skipping build - dotnet is not on PATH. Re-run this script after installing the .NET 6 SDK."
fi

# ---------------------------------------------------------------------------
# 4. Config file
# ---------------------------------------------------------------------------
if $IS_WINDOWS; then
  APPDATA_WIN="${APPDATA:-}"
  if [[ -z "$APPDATA_WIN" ]]; then
    APPDATA_WIN="$(cmd.exe /c "echo %APPDATA%" 2>/dev/null | tr -d '\r')"
  fi
  CONFIG_DIR="$(printf '%s' "$APPDATA_WIN" | sed 's#\\#/#g; s#^\([A-Za-z]\):#/\L\1#')"
else
  # Same place .NET's ApplicationData folder resolves to on Unix, which is
  # where azure-cli.exe looks: $XDG_CONFIG_HOME, else ~/.config.
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
fi
mkdir -p "$CONFIG_DIR"

CONFIG_FILE="$CONFIG_DIR/azure-cli.yml"

if [[ -f "$CONFIG_FILE" ]]; then
  log "Config file already exists at $CONFIG_FILE, leaving it untouched."
else
  log "Creating config file at $CONFIG_FILE"

  BASH_PATH_LINE=""
  if $IS_WINDOWS; then
    GIT_BASH="$(find_git_bash)"
    if [[ -n "$GIT_BASH" ]]; then
      BASH_PATH_LINE="bash_path: ${GIT_BASH//\\/\\\\}"
    else
      BASH_PATH_LINE="# bash_path: C:\\Program Files\\Git\\bin\\bash.exe"
    fi
  fi

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
    echo ""
    if [[ -n "$BASH_PATH_LINE" ]]; then
      echo "$BASH_PATH_LINE"
      echo ""
    fi
    echo "accounts:"
    echo "  - project_name: # TODO: e.g. sample-project"
    echo "    org_url: # TODO: e.g. https://dev.azure.com/example"
    echo "    pat: # TODO: your personal access token (optional on Windows w/ AAD)"
    echo "    hide_ancient: true"
    if [[ -n "$CLONES_DIR_GUESS" ]]; then
      echo "    clones_dir: ${CLONES_DIR_GUESS//\\/\\\\}"
    else
      echo "    # clones_dir: /path/to/where/repos/are/cloned"
    fi
  } > "$CONFIG_FILE"

  log "Config file created. Placeholders marked TODO still need to be filled in."
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

log "Done. Re-run 'src/bin/Debug/net6.0/azure-cli.exe' (or 'azure-cli' on PATH) once the config is filled in."
