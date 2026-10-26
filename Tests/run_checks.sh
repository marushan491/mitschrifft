#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py'
if [[ "$(uname -s)" == "Darwin" ]]; then
    swift test
else
    git push -q zotac-mirror HEAD:main
    ssh -o BatchMode=yes macbook 'cd ~/projects/mitschrift && git fetch -q zotac-mirror && git checkout -q --detach zotac-mirror/main && swift test 2>&1 | tail -25'
fi
