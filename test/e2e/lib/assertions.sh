#!/usr/bin/env bash
# Test assertion functions

assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $description"
        echo -e "    expected: ${expected}"
        echo -e "    actual:   ${actual}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_ne() {
    local description="$1"
    local not_expected="$2"
    local actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$not_expected" != "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $description"
        echo -e "    should not be: ${not_expected}"
        echo -e "    actual:        ${actual}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_gt() {
    local description="$1"
    local threshold="$2"
    local actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $description (expected > ${threshold}, got ${actual})"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_ge() {
    local description="$1"
    local threshold="$2"
    local actual="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$actual" -ge "$threshold" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $description (expected >= ${threshold}, got ${actual})"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_contains() {
    local description="$1"
    local needle="$2"
    local haystack="$3"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if echo "$haystack" | grep -q "$needle"; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $description"
        echo -e "    expected to contain: ${needle}"
        echo -e "    actual: ${haystack:0:200}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_fail() {
    local description="$1"
    local exit_code="$2"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$exit_code" -ne 0 ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: $description (exit code: ${exit_code})"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $description (expected non-zero exit, got 0)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

test_header() {
    local test_num="$1"
    local test_name="$2"
    echo ""
    echo -e "${BLUE}=== Test ${test_num}: ${test_name} ===${NC}"
}

print_summary() {
    echo ""
    echo "======================================"
    echo -e "  Tests passed: ${GREEN}${TESTS_PASSED}${NC} / ${TESTS_TOTAL}"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "  Tests failed: ${RED}${TESTS_FAILED}${NC}"
        echo "======================================"
        return 1
    else
        echo -e "  ${GREEN}All tests passed!${NC}"
        echo "======================================"
        return 0
    fi
}
