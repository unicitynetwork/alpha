#!/bin/bash

set -e

# Configuration
COMPOSE_FILE="/home/vrogojin/Projects/alpha/docker/docker-compose.yml"
LOG_FILE="/tmp/alpha_node_monitor.log"
MAX_STARTUP_TIME=120  # Maximum time to wait for node to start (seconds)
CHECK_INTERVAL=10     # Time between status checks (seconds)

echo "Starting Alpha node with Docker Compose..."
echo "$(date): Starting container" >> ${LOG_FILE}

# Make sure any previous instance is stopped
docker compose -f ${COMPOSE_FILE} down 2>/dev/null || true

# Start the container
docker compose -f ${COMPOSE_FILE} up -d

echo "Waiting for node to start (max ${MAX_STARTUP_TIME} seconds)..."

# Wait for the node to fully start
start_time=$(date +%s)
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    if [ ${elapsed} -gt ${MAX_STARTUP_TIME} ]; then
        echo "Error: Startup timed out after ${MAX_STARTUP_TIME} seconds"
        echo "$(date): Startup timed out after ${MAX_STARTUP_TIME} seconds" >> ${LOG_FILE}
        docker compose -f ${COMPOSE_FILE} logs
        exit 1
    fi
    
    # Check if container is running and service is ready
    if docker exec alpha-node alpha-cli getblockcount &>/dev/null; then
        block_count=$(docker exec alpha-node alpha-cli getblockcount)
        echo "Node is running! Current block height: ${block_count}"
        echo "$(date): Node started successfully. Block height: ${block_count}" >> ${LOG_FILE}
        break
    fi
    
    echo "Waiting for node to be ready... (${elapsed}s elapsed)"
    sleep ${CHECK_INTERVAL}
done

# Display node information
echo "===== Alpha Node Information ====="
docker exec alpha-node alpha-cli getinfo | grep -v "\"privatekeys\|\"walletname\|\"hdmasterkeyid\|\"keypoololdest\|\"paytxfee\|\"relayfee"
echo "=================================="

echo "Node is running and ready to use!"
echo "To run tests: ./test_container.sh"
echo "To stop node: docker compose -f ${COMPOSE_FILE} down"
echo "To view logs: docker compose -f ${COMPOSE_FILE} logs -f"