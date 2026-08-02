#!/bin/bash
# Validates that a new broadcast event has all required touchpoints
# Usage: bash .claude/skills/add-broadcast-event/scripts/validate.sh <event_name>
#   e.g.: bash .claude/skills/add-broadcast-event/scripts/validate.sh add_foo

set -e

EVENT_NAME="${1:?Usage: validate.sh <event_name>}"

echo "=== Validating Broadcast Event: $EVENT_NAME ==="

# 1. Check UpdateCoordinator
echo ""
echo "1. Checking UpdateCoordinator..."
COORDINATOR=$(find lib -name "update_coordinator*" -path "*/map/*" 2>/dev/null | head -1)
if [ -n "$COORDINATOR" ]; then
    if grep -q "$EVENT_NAME" "$COORDINATOR" 2>/dev/null; then
        echo "   PASS: Event found in $COORDINATOR"
    else
        echo "   FAIL: Event '$EVENT_NAME' not found in $COORDINATOR"
    fi
else
    echo "   WARN: UpdateCoordinator file not found"
fi

# 2. Check BroadcastMapUpdate
echo ""
echo "2. Checking BroadcastMapUpdate..."
BROADCAST_FILES=$(grep -rl "BroadcastMapUpdate\|broadcast_map_update" lib/ 2>/dev/null | head -5)
if [ -n "$BROADCAST_FILES" ]; then
    FOUND=0
    for f in $BROADCAST_FILES; do
        if grep -q "$EVENT_NAME" "$f" 2>/dev/null; then
            echo "   PASS: Event found in $f"
            FOUND=1
            break
        fi
    done
    if [ $FOUND -eq 0 ]; then
        echo "   WARN: Event not found in BroadcastMapUpdate files"
    fi
else
    echo "   WARN: No BroadcastMapUpdate files found"
fi

# 3. Check telemetry
echo ""
echo "3. Checking telemetry..."
if grep -r "$EVENT_NAME" lib/ 2>/dev/null | grep -q "telemetry\|Telemetry"; then
    echo "   PASS: Telemetry event found"
else
    echo "   WARN: No telemetry event found for '$EVENT_NAME'"
fi

# 4. Check compilation
echo ""
echo "4. Checking compilation..."
if mix compile --no-deps-check 2>&1 | grep -q "error"; then
    echo "   FAIL: Compilation errors detected"
else
    echo "   PASS: Project compiles"
fi

echo ""
echo "=== Validation complete ==="
