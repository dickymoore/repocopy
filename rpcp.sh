#!/usr/bin/env bash
#
# rpcp.sh — Copy filtered parts of a repo to the clipboard according to config.json
#
# Dependencies:
#   - jq (for JSON parsing)
#   - pbcopy (macOS), xclip (Linux), clip.exe or powershell.exe (WSL) for clipboard
#
# Usage:
#   rpcp.sh [--repo-path path] [--config-file file]
#               [--max-file-size bytes] [--ignore-folders pat1,pat2]
#               [--ignore-files f1,f2] [--replacements '{"T":"v",...}']
#               [--include-hidden-folders] [--show-copied-files] [--verbose]
#
# Example:
#   rpcp.sh --verbose
#

set -euo pipefail

# ——————— Helpers for JSON-less lookup ———————

# Detect whether to auto-install jq based on config.json
detect_auto_install() {
  local cfg="$1"
  if grep -Eq '"autoInstallDeps"\s*:\s*true' "$cfg"; then
    echo "true"
  else
    echo "false"
  fi
}

# Install jq using the appropriate package manager
install_jq() {
  echo "🔄 Installing jq…"
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y jq || {
      echo "❌ Failed to install jq via apt-get." >&2
      echo "   Try: sudo apt-get update && sudo apt-get install -y jq" >&2
      exit 1
    }
  elif command -v yum &>/dev/null; then
    sudo yum install -y jq
  elif command -v apk &>/dev/null; then
    sudo apk add jq
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y jq
  elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm jq
  elif command -v zypper &>/dev/null; then
    sudo zypper install -y jq
  elif command -v brew &>/dev/null; then
    brew install jq
  else
    echo "⚠️  No supported package manager found; please install jq manually." >&2
    exit 1
  fi

  # verify installation
  if ! command -v jq &>/dev/null || ! jq --version &>/dev/null; then
    echo "❌ jq installation failed or jq is not working." >&2
    exit 1
  fi
}

# Print an error with installation hints
jq_missing_error() {
  cat <<EOF >&2
Error: 'jq' is required but not installed (or broken).

On Ubuntu/WSL run:
  sudo apt update && sudo apt install -y jq

On other systems you might use:
  brew install jq       # macOS
  sudo yum install -y jq # RHEL/CentOS
  sudo apk add jq       # Alpine
  sudo dnf install -y jq # Fedora
  sudo pacman -S jq      # Arch
  sudo zypper install -y jq # openSUSE

EOF
  exit 2
}

# ——————— Utility Functions ———————

# Print usage and exit
usage() {
  grep '^#' "$0" | sed -e 's/^#//' -e 's/^[ \t]*//'
  exit 1
}

# Parse CLI arguments
parse_args() {
  local opts
  opts=$(getopt -o h --long help,repo-path:,config-file:,max-file-size:,ignore-folders:,ignore-files:,replacements:,include-hidden-folders,show-copied-files,verbose -- "$@")
  eval set -- "$opts"
  while true; do
    case "$1" in
      --repo-path)           CLI_REPO_PATH="$2"; shift 2;;
      --config-file)         CLI_CONFIG_FILE="$2"; shift 2;;
      --max-file-size)       CLI_MAX_FILE_SIZE="$2"; shift 2;;
      --ignore-folders)      CLI_IGNORE_FOLDERS="$2"; shift 2;;
      --ignore-files)        CLI_IGNORE_FILES="$2"; shift 2;;
      --replacements)        CLI_REPLACEMENTS_JSON="$2"; shift 2;;
      --include-hidden-folders) CLI_INCLUDE_HIDDEN_FOLDERS="true"; shift;;
      --show-copied-files)   CLI_SHOW_COPIED_FILES="true"; shift;;
      --verbose)             VERBOSE=1; shift;;
      -h|--help)             usage;;
      --)                    shift; break;;
      *)                     usage;;
    esac
  done
}

# Split comma-separated list into an array
csv_to_array() {
  local IFS=','; read -r -a arr <<< "$1"; echo "${arr[@]}"
}

is_truthy() {
  local value="${1:-}"
  [[ "${value,,}" == "true" || "$value" == "1" ]]
}

# Decide whether to include a file; log if verbose
should_include() {
  local file="$1"
  local base="${file##*/}"
  local dir="${file%/*}"
  local reason=

  # Folder patterns
  IFS=$'\n'
  for pat in "${IGNORE_FOLDERS[@]}"; do
    [[ $dir == *"/$pat"* ]] && reason="matched ignore-folder '$pat'" && break
  done

  # File patterns
  if [[ -z "$reason" ]]; then
    for pat in "${IGNORE_FILES[@]}"; do
      [[ $base == $pat ]] && reason="filename '$base' matches ignore pattern '$pat'" && break
    done
  fi

  # Size check
  if [[ -z "$reason" && $MAX_FILE_SIZE -gt 0 ]]; then
    local sz
    sz=$(stat -c%s "$file")
    (( sz > MAX_FILE_SIZE )) && reason="exceeds max-file-size ($MAX_FILE_SIZE bytes)"
  fi

  if [[ -n "$reason" ]]; then
    (( VERBOSE )) && echo "EXCLUDING: $file → $reason"
    return 1
  else
    (( VERBOSE )) && echo "INCLUDING: $file"
    return 0
  fi
}

# Collect files to include
collect_files() {
  if is_truthy "$INCLUDE_HIDDEN_FOLDERS"; then
    mapfile -t ALL_FILES < <(find "$REPO_PATH" -type f)
  else
    mapfile -t ALL_FILES < <(find "$REPO_PATH" \( -type d -name '.*' ! -path "$REPO_PATH" \) -prune -o -type f -print)
  fi
  INCLUDED_FILES=()
  for f in "${ALL_FILES[@]}"; do
    if should_include "$f"; then
      INCLUDED_FILES+=("$f")
    fi
  done
  if (( ${#INCLUDED_FILES[@]} == 0 )); then
    echo "Warning: no files to copy." >&2
    exit 0
  fi
}

# Build the aggregated content
build_content() {
  for f in "${INCLUDED_FILES[@]}"; do
    printf 'File: %s\n' "$f"
    printf '%.0s-' {1..60}; printf "\n"
    local text
    text=$(< "$f")
    for key in "${!REPLACEMENTS[@]}"; do
      text=${text//"$key"/"${REPLACEMENTS[$key]}"}
    done
    printf '%s\n\n' "$text"
  done
}

# Best-effort terminal clipboard fallback for environments without a native
# clipboard command installed.
copy_to_osc52() {
  local content="$1"
  local encoded

  command -v base64 &>/dev/null || return 1
  [[ -w /dev/tty ]] || return 1

  encoded=$(printf '%s' "$content" | base64 | tr -d '\r\n')

  if [[ -n "${TMUX:-}" ]]; then
    printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$encoded" > /dev/tty
  else
    printf '\033]52;c;%s\a' "$encoded" > /dev/tty
  fi
}

# Copy STDIN to clipboard on macOS, Linux, WSL
copy_to_clipboard() {
  local content
  content=$(cat)
  if command -v pbcopy &>/dev/null; then
    printf '%s' "$content" | pbcopy
  elif command -v xclip &>/dev/null; then
    printf '%s' "$content" | xclip -selection clipboard
  elif command -v wl-copy &>/dev/null; then
    printf '%s' "$content" | wl-copy
  elif command -v xsel &>/dev/null; then
    printf '%s' "$content" | xsel --clipboard --input
  elif command -v clip.exe &>/dev/null; then
    printf '%s' "$content" | clip.exe
  elif command -v powershell.exe &>/dev/null; then
    printf '%s' "$content" | powershell.exe -NoProfile -Command "Set-Clipboard"
  elif copy_to_osc52 "$content"; then
    :
  else
    echo "Error: no clipboard utility found (pbcopy, xclip, wl-copy, xsel, clip.exe, powershell.exe, or OSC52 terminal clipboard)" >&2
    exit 3
  fi
}

# ——————— Main ———————

# Defaults
VERBOSE=0

# Parse arguments
parse_args "$@"

# Locate config.json
CONFIG_FILE=${CLI_CONFIG_FILE:-"$PWD/config.json"}
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config file not found at $CONFIG_FILE" >&2
  exit 3
fi

# Auto-install jq?
AUTO_INSTALL_DEPS=$(detect_auto_install "$CONFIG_FILE")

# Ensure jq is available
if ! command -v jq &>/dev/null || ! jq --version &>/dev/null; then
  if [[ "$AUTO_INSTALL_DEPS" == "true" ]]; then
    install_jq
  else
    jq_missing_error
  fi
fi

# Load config via jq
load_config() {
  local cfg="$1"
  REPO_PATH=$(jq -r '.repoPath // "."' "$cfg")
  MAX_FILE_SIZE=$(jq -r '.maxFileSize // 0' "$cfg")
  INCLUDE_HIDDEN_FOLDERS=$(jq -r '.includeHiddenFolders // false' "$cfg")
  SHOW_COPIED_FILES=$(jq -r '.showCopiedFiles // false' "$cfg")
  mapfile -t CFG_IGNORE_FOLDERS < <(jq -r '.ignoreFolders[]?' "$cfg")
  mapfile -t CFG_IGNORE_FILES   < <(jq -r '.ignoreFiles[]?' "$cfg")
  declare -gA CFG_REPLACEMENTS=()
  while IFS="=" read -r k v; do
    CFG_REPLACEMENTS["$k"]="$v"
  done < <(jq -r '.replacements | to_entries[] | "\(.key)=\(.value)"' "$cfg")
}

load_config "$CONFIG_FILE"

# Merge CLI overrides
REPO_PATH=${CLI_REPO_PATH:-$REPO_PATH}
MAX_FILE_SIZE=${CLI_MAX_FILE_SIZE:-$MAX_FILE_SIZE}
INCLUDE_HIDDEN_FOLDERS=${CLI_INCLUDE_HIDDEN_FOLDERS:-$INCLUDE_HIDDEN_FOLDERS}
SHOW_COPIED_FILES=${CLI_SHOW_COPIED_FILES:-$SHOW_COPIED_FILES}

if [[ -n "${CLI_IGNORE_FOLDERS:-}" ]]; then
  IFS=',' read -r -a IGNORE_FOLDERS <<< "$CLI_IGNORE_FOLDERS"
else
  IGNORE_FOLDERS=("${CFG_IGNORE_FOLDERS[@]}")
fi

if [[ -n "${CLI_IGNORE_FILES:-}" ]]; then
  IFS=',' read -r -a IGNORE_FILES <<< "$CLI_IGNORE_FILES"
else
  IGNORE_FILES=("${CFG_IGNORE_FILES[@]}")
fi

if [[ -n "${CLI_REPLACEMENTS_JSON:-}" ]]; then
  declare -A REPLACEMENTS=()
  while IFS="=" read -r k v; do
    k=${k//\"/}; v=${v//\"/}
    REPLACEMENTS["$k"]="$v"
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$CLI_REPLACEMENTS_JSON")
else
  declare -A REPLACEMENTS=()
  for k in "${!CFG_REPLACEMENTS[@]}"; do
    REPLACEMENTS["$k"]="${CFG_REPLACEMENTS[$k]}"
  done
fi

# Collect, build, and copy
collect_files
build_content | copy_to_clipboard

# Show summary
echo "✅ Copied ${#INCLUDED_FILES[@]} file(s) to clipboard."
if is_truthy "$SHOW_COPIED_FILES"; then
  echo
  echo "Files included:"
  for f in "${INCLUDED_FILES[@]}"; do
    echo " - $f"
  done
fi
