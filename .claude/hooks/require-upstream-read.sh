#!/bin/bash
# PreToolUse hook for Edit and Write tools.
# Blocks any edit to /tmp/mork-repo/src/ unless upstream Rust was read first.

input=$(cat)
file_path=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('file_path',''))" 2>/dev/null)

# Only enforce for mork-repo src files
if [[ "$file_path" != /tmp/mork-repo/src/* ]]; then
    exit 0
fi

# Check sentinel exists
if [ ! -f /tmp/mork_upstream_read_ts ]; then
    echo "BLOCKED: Cannot edit Julia MORK source without reading upstream Rust first."
    echo ""
    echo "You must run a grep/cat/sed on ~/JuliaAGI/dev-zone/MORK/ for the corresponding file."
    echo "Example:"
    echo "  grep -n 'fn query_multi' ~/JuliaAGI/dev-zone/MORK/kernel/src/space.rs"
    echo ""
    echo "The edit will be unblocked automatically once you read the upstream file."
    exit 2
fi

# Check sentinel is not stale (older than 30 minutes = 1800 seconds)
ts=$(cat /tmp/mork_upstream_read_ts)
now=$(date +%s)
age=$((now - ts))
if [ "$age" -gt 1800 ]; then
    echo "BLOCKED: Upstream read sentinel is stale (${age}s ago, limit 1800s)."
    echo ""
    echo "Re-read the upstream Rust file before editing:"
    echo "  grep/cat/sed on ~/JuliaAGI/dev-zone/MORK/..."
    rm /tmp/mork_upstream_read_ts
    exit 2
fi

# Allow — but clear the sentinel so next edit requires a fresh read
rm /tmp/mork_upstream_read_ts
exit 0
