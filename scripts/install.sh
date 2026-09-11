#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/WMRecorder.app
DEST=/Applications/WMRecorder.app
codesign --verify --deep --strict "$APP"
if [[ -d "$DEST" ]]; then
 PREVIOUS=$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => //p')
 [[ -n "$PREVIOUS" ]]
 codesign --verify --strict -R "= $PREVIOUS" "$APP"
fi
swift scripts/quit-idle.swift
# Only a quiescent app may be replaced. Never interrupt recording/export/test data.
python3 - <<'PY'
import json, os, pathlib, subprocess, sys, time
exe = '/Applications/WMRecorder.app/Contents/MacOS/WMRecorder'
rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
pids = [int(r.strip().split(None, 1)[0]) for r in rows if len(r.strip().split(None, 1)) == 2 and r.strip().split(None, 1)[1] == exe]
status = pathlib.Path.home() / 'Library/Application Support/WMRecorder/runtime.json'
if pids and status.exists():
    state = json.loads(status.read_text())
    if state.get('pid') in pids and any(state.get(k) for k in ('recording', 'busy', 'testRunning')):
        sys.exit('App is recording, exporting or testing; refusing to interrupt.')
if pids:
    sys.exit('App is still running; quit the verified idle app before installation.')
PY
STAGE="/Applications/.WMRecorder-stage-$$.app"
ditto "$APP" "$STAGE"
codesign --verify --deep --strict "$STAGE"
if [[ -d "$DEST" ]]; then
 BACKUP=".local/installed-backup-$(date +%Y%m%d-%H%M%S).app"
 mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGE" "$DEST"; then
 if [[ -n "${BACKUP:-}" ]]; then mv "$BACKUP" "$DEST"; fi
 exit 1
fi
codesign --verify --deep --strict "$DEST"
open "$DEST" "$@"
