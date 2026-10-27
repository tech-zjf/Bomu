#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT_KEY=BOMU_ACCEPTANCE_LIBRARY_DIRECTORY
APP="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/Bomu.app"
RECEIPT="${APP%.app}.build-identity.json"

if [[ "${1:-}" == --help ]]; then
  echo "Launch one verified Debug app with a marked, temporary empty library."
  echo "Requires an unlocked desktop and no running Bomu app. No global environment is changed."
  echo "Keep this command running; quit the test app normally to clean up its library."
  echo "After cleanup, reopen the canonical Debug app normally to restore your usual Home."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "No arguments are supported. Use --help for the procedure." >&2
  exit 2
fi

# Refuse any Bomu copy, including test-host copies, to preserve the one-window rule.
# A failed process query is not proof that the desktop is free.
require_no_app() {
  local status=0
  pgrep -x Bomu >/dev/null || status=$?
  case "$status" in
    1) return 0 ;;
    0) echo "Bomu is still running; leave its window and library untouched." >&2 ;;
    *) echo "Cannot determine whether Bomu is running; refusing cleanup or launch." >&2 ;;
  esac
  return 1
}

python3 "$PROJECT_ROOT/scripts/build_identity.py" verify --receipt "$RECEIPT" --app "$APP"
require_no_app
if [[ -n "${BOMU_ACCEPTANCE_LIBRARY_DIRECTORY+x}" ]] ||
   [[ -n "$(launchctl getenv "$ENVIRONMENT_KEY" 2>/dev/null || true)" ]]; then
  echo "$ENVIRONMENT_KEY is already set; clear the previous session explicitly first." >&2
  exit 1
fi
# Fail closed if the lock state cannot be read. Never launch invisibly while locked.
CONSOLE_STATE="$(ioreg -r -k IOConsoleLocked -d 1)"
if ! grep -Eq '"IOConsoleLocked" = No' <<< "$CONSOLE_STATE"; then
  echo "Desktop is locked or its lock state is unknown; no app was launched." >&2
  exit 1
fi

TEMPORARY_ROOT="$(getconf DARWIN_USER_TEMP_DIR)"
SESSION_DIRECTORY="$(mktemp -d "$TEMPORARY_ROOT/bomu-welcome.XXXXXX")"
MARKER="$SESSION_DIRECTORY/.bomu-acceptance-library"
printf 'Bomu isolated acceptance library\n' > "$MARKER"

cleanup() {
  # open -W normally returns after app exit. On interruption or launch failure the
  # app may still own SQLite, so preserve the directory instead of deleting live data.
  if ! require_no_app; then
    echo "Temporary library retained: $SESSION_DIRECTORY" >&2
    echo "Quit the test app before checking its marker and removing this directory." >&2
    return
  fi
  if [[ -d "$SESSION_DIRECTORY" && ! -L "$SESSION_DIRECTORY" &&
        -f "$MARKER" && ! -L "$MARKER" ]] &&
     [[ "$(cat "$MARKER")" == 'Bomu isolated acceptance library' ]] &&
     [[ "$(basename "$SESSION_DIRECTORY")" == bomu-welcome.* ]]; then
    rm -rf -- "$SESSION_DIRECTORY"
    echo "Temporary library removed. Reopen the canonical Debug app normally for your usual Home."
  else
    echo "Temporary library marker changed; retained for inspection: $SESSION_DIRECTORY" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "Isolated library: $SESSION_DIRECTORY"
echo "Home will show Welcome for this test only. Quit the app when finished."
# Per-launch environment prevents a later normal launch inheriting the empty library.
# Do not use launchctl setenv or a launcher that can reuse an existing process.
open -n -W --env "$ENVIRONMENT_KEY=$SESSION_DIRECTORY" "$APP"
