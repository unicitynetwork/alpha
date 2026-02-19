#!/usr/bin/env bash
# Cleanup functions for E2E test suite

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"

    # Stop any running external miners before removing containers
    for i in $(seq 0 $((NUM_NODES - 1))); do
        docker exec "${CONTAINER_PREFIX}${i}" pkill -f minerd 2>/dev/null || true
    done

    # Stop and remove all test containers
    for i in $(seq 0 $((NUM_NODES - 1))); do
        docker rm -f "${CONTAINER_PREFIX}${i}" 2>/dev/null || true
    done
    # Also remove extra containers from edge-case tests (nodes 7, 8, 9)
    docker rm -f "${CONTAINER_PREFIX}7" 2>/dev/null || true
    docker rm -f "${CONTAINER_PREFIX}8" 2>/dev/null || true
    docker rm -f "${CONTAINER_PREFIX}9" 2>/dev/null || true
    # Remove the keygen container
    docker rm -f "alpha-e2e-keygen" 2>/dev/null || true

    # Remove Docker network
    docker network rm "${NETWORK_NAME}" 2>/dev/null || true

    # Remove temp config directories
    rm -rf /tmp/alpha-e2e-* 2>/dev/null || true

    echo "Cleanup complete."
}
