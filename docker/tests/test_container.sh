#!/bin/bash

set -e

CONTAINER_NAME="alpha-node"
RPC_PORT=8589
P2P_PORT=7933

echo "Starting Alpha node container test..."

# Check if container exists and is running
if ! docker ps -f "name=${CONTAINER_NAME}" --format '{{.Names}}' | grep -q "${CONTAINER_NAME}"; then
    echo "❌ Error: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

echo "✅ Container ${CONTAINER_NAME} is running"

# Check if ports are open
if ! docker exec ${CONTAINER_NAME} netstat -tuln | grep -q "${RPC_PORT}"; then
    echo "❌ Error: RPC port ${RPC_PORT} is not listening"
    exit 1
fi

if ! docker exec ${CONTAINER_NAME} netstat -tuln | grep -q "${P2P_PORT}"; then
    echo "❌ Error: P2P port ${P2P_PORT} is not listening"
    exit 1
fi

echo "✅ Ports ${RPC_PORT} (RPC) and ${P2P_PORT} (P2P) are open"

# Check if alpha-cli is working
if ! docker exec ${CONTAINER_NAME} alpha-cli -version &> /dev/null; then
    echo "❌ Error: alpha-cli command not working"
    exit 1
fi

echo "✅ alpha-cli is working properly"

# Check if the node can get info
if ! docker exec ${CONTAINER_NAME} alpha-cli getinfo &> /dev/null; then
    echo "❌ Error: Cannot get node information"
    exit 1
fi

echo "✅ Node info can be retrieved"

echo "✅ All tests passed successfully!"
