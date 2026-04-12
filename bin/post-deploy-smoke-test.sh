#!/bin/bash
# ABOUTME: Post-deploy smoke test that verifies the production site is rendering correctly.
# ABOUTME: Checks landing page content, UTF-8 encoding, CSS loading, and CTA presence.

set -e

# Test the local server, not the live URL -- we're verifying this deploy, not the previous one
BASE_URL="http://localhost:${PORT:-10000}"
FAILURES=0

check() {
    local description="$1"
    local url="$2"
    local pattern="$3"
    local negate="${4:-}"

    local body
    body=$(curl -sL --max-time 10 "$url") || {
        echo "FAIL: $description - could not fetch $url"
        FAILURES=$((FAILURES + 1))
        return
    }

    if [ "$negate" = "not" ]; then
        if echo "$body" | grep -q "$pattern"; then
            echo "FAIL: $description - found unwanted pattern: $pattern"
            FAILURES=$((FAILURES + 1))
        else
            echo "PASS: $description"
        fi
    else
        if echo "$body" | grep -q "$pattern"; then
            echo "PASS: $description"
        else
            echo "FAIL: $description - pattern not found: $pattern"
            FAILURES=$((FAILURES + 1))
        fi
    fi
}

echo "=== Post-Deploy Smoke Test ==="
echo "Target: $BASE_URL"
echo ""

# Landing page loads
check "Landing page returns 200" "$BASE_URL" "landing-page"

# Vaporwave design system is active
check "CSS theme loaded" "$BASE_URL" "theme.css"
check "CSS app loaded" "$BASE_URL" "app.css"

# Hero content present
check "Hero headline present" "$BASE_URL" "Your art deserves a real business"
check "Hero subtitle present" "$BASE_URL" "get back to making art"

# Problem cards present
check "Problem cards section" "$BASE_URL" "Less paperwork"
check "Feature card present" "$BASE_URL" "Fill your classes"

# Alignment copy
check "Alignment pricing visible" "$BASE_URL" "2.5%"

# CTA button present
check "CTA button present" "$BASE_URL" "Get Started"

# No mojibake
check "No UTF-8 mojibake (arrow)" "$BASE_URL" "â€" "not"
check "No raw Unicode arrow" "$BASE_URL" "→" "not"

# No server errors
check "No server error" "$BASE_URL" "Internal Server Error" "not"

# Tenant signup workflow reachable
check "Tenant signup reachable" "$BASE_URL/tenant-signup" "tenant-signup"

echo ""
echo "=== Results: $((13 - FAILURES))/13 passed, $FAILURES failed ==="

if [ $FAILURES -gt 0 ]; then
    echo "SMOKE TEST FAILED"
    exit 1
fi

echo "SMOKE TEST PASSED"
