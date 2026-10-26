#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT_KEY=BOMU_ACCEPTANCE_LIBRARY_DIRECTORY
RECEIPT="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/Bomu.build-identity.json"

if [[ "${1:-}" == --help ]]; then
  echo "Prepare a marked temporary library for one visible Welcome acceptance session."
  echo "Keep this command running, launch the verified Debug app with desktop automation,"
  echo "close that app after testing, then press Return here to clear the environment and library."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "No arguments are supported. Use --help for the procedure." >&2
  exit 2
fi

python3 "$PROJECT_ROOT/scripts/build_identity.py" verify --receipt "$RECEIPT"
if [[ -n "$(launchctl getenv "$ENVIRONMENT_KEY" 2>/dev/null || true)" ]]; then
  echo "$ENVIRONMENT_KEY is already set; refusing to replace an existing session." >&2
  exit 1
fi

TEMPORARY_ROOT="$(getconf DARWIN_USER_TEMP_DIR)"
SESSION_DIRECTORY="$(mktemp -d "$TEMPORARY_ROOT/bomu-welcome.XXXXXX")"
MARKER="$SESSION_DIRECTORY/.bomu-acceptance-library"
printf 'Bomu isolated acceptance library\n' > "$MARKER"
ENVIRONMENT_ARMED=false

cleanup() {
  if [[ "$ENVIRONMENT_ARMED" == true ]]; then
    launchctl unsetenv "$ENVIRONMENT_KEY" || true
  fi
  if [[ -d "$SESSION_DIRECTORY" && -f "$MARKER" ]] &&
     [[ "$(cat "$MARKER")" == 'Bomu isolated acceptance library' ]] &&
     [[ "$(basename "$SESSION_DIRECTORY")" == bomu-welcome.* ]]; then
    rm -rf -- "$SESSION_DIRECTORY"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Arm cleanup first, including the narrow interval after launchctl succeeds.
ENVIRONMENT_ARMED=true
launchctl setenv "$ENVIRONMENT_KEY" "$SESSION_DIRECTORY"
echo "Isolated library ready: $SESSION_DIRECTORY"
echo "Launch the verified Debug Bomu.app through desktop automation and confirm Welcome is empty."
echo "Close only that session's app, then press Return here to remove the temporary library."
IFS= read -r _
