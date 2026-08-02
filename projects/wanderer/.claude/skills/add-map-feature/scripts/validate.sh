#!/bin/bash
# Validates that a new map feature has all required components
# Usage: bash .claude/skills/add-map-feature/scripts/validate.sh

set -e

echo "=== Validating Map Feature ==="

# 1. Check compilation
echo ""
echo "1. Checking compilation..."
if mix compile --no-deps-check 2>&1 | grep -q "error"; then
    echo "   FAIL: Compilation errors detected"
    mix compile --no-deps-check 2>&1 | grep "error" | head -5
else
    echo "   PASS: Project compiles"
fi

# 2. Check formatting
echo ""
echo "2. Checking code formatting..."
if mix format --check-formatted 2>/dev/null; then
    echo "   PASS: Code is formatted"
else
    echo "   WARN: Code needs formatting. Run: mix format"
fi

# 3. Run tests
echo ""
echo "3. Running tests..."
if mix test 2>&1 | tail -1 | grep -q "0 failures"; then
    echo "   PASS: All tests pass"
else
    echo "   WARN: Some tests may be failing. Run: mix test"
fi

# 4. Check frontend build
echo ""
echo "4. Checking frontend build..."
if cd assets && npx vite build --emptyOutDir false 2>&1 | grep -q "error"; then
    echo "   FAIL: Frontend build errors"
    cd ..
else
    echo "   PASS: Frontend builds"
    cd ..
fi

echo ""
echo "=== Validation complete ==="
