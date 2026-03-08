#!/bin/bash
# Run all Dart test files in this directory
# Stops on first failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART="/home/brito/flutter/bin/dart"

echo "========================================"
echo "Running all server tests"
echo "========================================"
echo ""

# Count tests
total=0
passed=0

# Find all dart files in this directory (not subdirectories)
for test_file in "$SCRIPT_DIR"/*_test.dart; do
    if [[ -f "$test_file" ]]; then
        filename=$(basename "$test_file")
        echo "Running: $filename"
        echo "----------------------------------------"

        if $DART "$test_file"; then
            passed=$((passed + 1))
            echo ""
            echo ">>> $filename PASSED"
            echo ""
        else
            echo ""
            echo ">>> $filename FAILED - stopping"
            echo ""
            echo "========================================"
            echo "Tests stopped due to failure"
            echo "Passed: $passed / $((total + 1))"
            echo "========================================"
            exit 1
        fi

        total=$((total + 1))
    fi
done

if [[ $total -eq 0 ]]; then
    echo "No test files found (*_test.dart)"
    exit 1
fi

echo "========================================"
echo "All tests passed!"
echo "Total: $total"
echo "========================================"
