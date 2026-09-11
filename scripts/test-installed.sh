#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_DIR="$PWD/.local/test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
swift test > "$RUN_DIR/unit-tests.log" 2>&1
./scripts/build.sh > "$RUN_DIR/build.log" 2>&1
./scripts/install.sh --args --self-test "$RUN_DIR" "$@"
python3 - "$RUN_DIR" <<'PY'
import json, pathlib, sys, time
folder = pathlib.Path(sys.argv[1])
end = time.monotonic() + 900
while time.monotonic() < end:
    result = folder / 'test-results.json'
    if result.exists():
        data = json.loads(result.read_text())
        if data.get('finished'):
            print(f"passed={data['passed']} failed={data['failed']} blocked={data['blocked']}")
            print(f"Report: {folder / 'test-report.md'}")
            sys.exit(0 if data['failed'] == 0 and data['blocked'] == 0 else 1)
    time.sleep(1)
sys.exit('Device tests did not finish within 15 minutes; partial logs retained.')
PY
