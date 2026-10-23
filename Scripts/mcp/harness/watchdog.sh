#!/bin/bash
# Usage: watchdog.sh <seconds> <log> <command...>
# Runs the command, and on timeout terminates exactly its own process subtree (the command
# plus all descendants, e.g. swift-test -> swiftpm-xctest-helper/xctest). Never touches
# unrelated processes. Exit status: the command's, or 124 on timeout.
set -u
limit="$1"; log="$2"; shift 2
"$@" > "$log" 2>&1 &
root=$!
descendants() {
    local pid="$1" child
    for child in $(/usr/bin/pgrep -P "$pid" 2>/dev/null); do
        descendants "$child"
        echo "$child"
    done
}
elapsed=0
while kill -0 "$root" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ]; then
        tree="$(descendants "$root") $root"
        echo "watchdog: timeout after ${limit}s; terminating subtree: ${tree}" >> "$log"
        for pid in $tree; do /usr/bin/sample "$pid" 1 -file "${log}.sample.${pid}.txt" >/dev/null 2>&1 || true; done
        kill -TERM $tree 2>/dev/null
        sleep 3
        kill -KILL $tree 2>/dev/null
        wait "$root" 2>/dev/null
        exit 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
wait "$root"
