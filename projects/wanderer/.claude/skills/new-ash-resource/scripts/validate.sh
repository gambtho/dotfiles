#!/bin/bash
# Validates that a new Ash resource is properly set up
# Usage: bash .claude/skills/new-ash-resource/scripts/validate.sh <ResourceModuleName>
#   e.g.: bash .claude/skills/new-ash-resource/scripts/validate.sh MyNewResource

set -e

RESOURCE_NAME="${1:?Usage: validate.sh <ResourceModuleName>}"
RESOURCE_SNAKE=$(echo "$RESOURCE_NAME" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//')

echo "=== Validating Ash Resource: $RESOURCE_NAME ==="

# 1. Check resource file exists
echo ""
echo "1. Checking resource file..."
RESOURCE_FILE=$(find lib/wanderer_app/api -name "${RESOURCE_SNAKE}.ex" 2>/dev/null | head -1)
if [ -n "$RESOURCE_FILE" ]; then
    echo "   PASS: Found $RESOURCE_FILE"
else
    echo "   FAIL: No resource file found matching ${RESOURCE_SNAKE}.ex in lib/wanderer_app/api/"
fi

# 2. Check domain registration
echo ""
echo "2. Checking domain registration in lib/wanderer_app/api.ex..."
if grep -q "$RESOURCE_NAME" lib/wanderer_app/api.ex 2>/dev/null; then
    echo "   PASS: $RESOURCE_NAME is registered in the domain"
else
    echo "   FAIL: $RESOURCE_NAME not found in lib/wanderer_app/api.ex"
fi

# 3. Check code_interface block exists
echo ""
echo "3. Checking code_interface..."
if [ -n "$RESOURCE_FILE" ] && grep -q "code_interface" "$RESOURCE_FILE" 2>/dev/null; then
    echo "   PASS: code_interface block found"
    DEFINE_COUNT=$(grep -c "define(" "$RESOURCE_FILE" 2>/dev/null || echo "0")
    echo "   INFO: $DEFINE_COUNT define() entries found"
else
    echo "   WARN: No code_interface block found — functions won't be generated"
fi

# 4. Check migration exists
echo ""
echo "4. Checking for migration..."
MIGRATION=$(find priv/repo/migrations -name "*${RESOURCE_SNAKE}*" 2>/dev/null | head -1)
if [ -n "$MIGRATION" ]; then
    echo "   PASS: Found migration $MIGRATION"
else
    echo "   WARN: No migration found. Run: mix ash.codegen add_${RESOURCE_SNAKE}"
fi

# 5. Check compilation
echo ""
echo "5. Checking compilation..."
if mix compile --no-deps-check 2>&1 | grep -q "error"; then
    echo "   FAIL: Compilation errors detected"
else
    echo "   PASS: Project compiles"
fi

echo ""
echo "=== Validation complete ==="
