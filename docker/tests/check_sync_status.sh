#!/bin/bash

# Check if the Alpha node is in sync with the network
# Usage: ./check_sync_status.sh

CONTAINER_NAME="alpha-node"

echo "Checking Alpha node synchronization status..."

# Get current blockchain info
if ! blockchain_info=$(docker exec ${CONTAINER_NAME} alpha-cli getblockchaininfo 2>/dev/null); then
    echo "❌ Error: Cannot retrieve blockchain info"
    exit 1
fi

# Extract relevant information
current_height=$(echo "${blockchain_info}" | grep "\"blocks\"" | awk '{print $2}' | sed 's/,//')
headers=$(echo "${blockchain_info}" | grep "\"headers\"" | awk '{print $2}' | sed 's/,//')
verification_progress=$(echo "${blockchain_info}" | grep "\"verificationprogress\"" | awk '{print $2}' | sed 's/,//')

# Convert verification progress to percentage
sync_percent=$(echo "${verification_progress} * 100" | bc -l | xargs printf "%.2f")

echo "Current Status:"
echo "Block Height: ${current_height}"
echo "Headers: ${headers}"
echo "Sync Progress: ${sync_percent}%"

# Check if node is synced
if [[ $(echo "${verification_progress} > 0.9999" | bc -l) -eq 1 && ${current_height} -eq ${headers} ]]; then
    echo "✅ Node is fully synchronized with the network"
else
    remaining_blocks=$((headers - current_height))
    echo "⏳ Node is still synchronizing (${remaining_blocks} blocks remaining)"
fi

# Get network information
connection_count=$(docker exec ${CONTAINER_NAME} alpha-cli getconnectioncount 2>/dev/null || echo "unknown")
echo "Connections: ${connection_count}"

# Get memory pool information
mempool_info=$(docker exec ${CONTAINER_NAME} alpha-cli getmempoolinfo 2>/dev/null)
tx_count=$(echo "${mempool_info}" | grep "\"size\"" | awk '{print $2}' | sed 's/,//')
echo "Mempool Transactions: ${tx_count}"

# Simple uptime check
uptime=$(docker inspect --format='{{.State.StartedAt}}' ${CONTAINER_NAME} | xargs date +%s -d)
now=$(date +%s)
uptime_seconds=$((now - uptime))
uptime_days=$((uptime_seconds / 86400))
uptime_hours=$(( (uptime_seconds % 86400) / 3600 ))
uptime_minutes=$(( (uptime_seconds % 3600) / 60 ))

echo "Container Uptime: ${uptime_days}d ${uptime_hours}h ${uptime_minutes}m"