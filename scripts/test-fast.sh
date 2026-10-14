#!/bin/bash
# Unit tests only: skips the script-driven classes that spawn bash, codesign
# or the built app (minutes instead of half an hour). Run the full suite
# (`swift test`) before a release.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --skip 'RecoveryScriptTests|AgentModeExitInANewBootTests|AppEncodedJournalScriptTests|PackagingTests|LidSimulationGateScriptTests|ResumeFrozenCommandTests' "$@"
