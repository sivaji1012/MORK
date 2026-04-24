#!/bin/bash
# PreToolUse hook for Bash — fires on every shell command.
# If the command reads from upstream MORK dev-zone, record the timestamp.

input=$(cat)
command=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('command',''))" 2>/dev/null)

# Must reference the upstream dev-zone MORK path
if echo "$command" | grep -q "dev-zone/MORK"; then
    # Must be a read operation (not a write/git command)
    if echo "$command" | grep -qE "grep|cat|sed|head|tail|wc|less|awk|find"; then
        date +%s > /tmp/mork_upstream_read_ts
        echo "$command" >> /tmp/mork_upstream_read_log
    fi
fi

exit 0
