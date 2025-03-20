#!/bin/bash

# Alpha Node Docker Deployment Script
# This script automates the deployment of an Alpha node via Docker

set -e

# Configuration
COMPOSE_FILE="docker-compose.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
EXAMPLE_CONFIG="${CONFIG_DIR}/alpha.conf.example"
CUSTOM_CONFIG="${CONFIG_DIR}/alpha.conf"
LOG_FILE="/tmp/alpha_deploy.log"

# Header
echo "========================================"
echo "   Alpha Node Docker Deployment Tool   "
echo "========================================"
echo ""

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Create log file
touch "${LOG_FILE}"
log "Starting Alpha node deployment"

# Check Docker installation
if ! command -v docker &> /dev/null; then
    log "❌ Error: Docker is not installed"
    echo "Please install Docker first: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! command -v docker compose &> /dev/null; then
    log "❌ Error: Docker Compose is not installed"
    echo "Please install Docker Compose first: https://docs.docker.com/compose/install/"
    exit 1
fi

log "✅ Docker and Docker Compose are installed"

# Check if we're in the right directory
if [ ! -f "${SCRIPT_DIR}/${COMPOSE_FILE}" ]; then
    log "❌ Error: ${COMPOSE_FILE} not found in ${SCRIPT_DIR}"
    exit 1
fi

# Check if custom config exists or offer to create it
if [ ! -f "${CUSTOM_CONFIG}" ]; then
    echo "No custom configuration found at ${CUSTOM_CONFIG}"
    echo "Would you like to:"
    echo "1) Use default configuration"
    echo "2) Create custom configuration from example"
    read -p "Enter choice (1-2): " config_choice
    
    if [ "$config_choice" == "2" ]; then
        if [ -f "${EXAMPLE_CONFIG}" ]; then
            cp "${EXAMPLE_CONFIG}" "${CUSTOM_CONFIG}"
            log "Created custom configuration from example"
            echo "Please edit ${CUSTOM_CONFIG} with your preferred settings"
            read -p "Press Enter when ready to continue..."
        else
            log "❌ Error: Example configuration not found at ${EXAMPLE_CONFIG}"
            exit 1
        fi
    else
        log "Using default configuration"
    fi
fi

# Check if container is already running
if docker ps --format '{{.Names}}' | grep -q "alpha-node"; then
    echo "Alpha node is already running."
    echo "Would you like to:"
    echo "1) Stop and recreate it"
    echo "2) Leave it running and exit"
    read -p "Enter choice (1-2): " container_choice
    
    if [ "$container_choice" == "1" ]; then
        log "Stopping existing Alpha node container"
        docker compose -f "${SCRIPT_DIR}/${COMPOSE_FILE}" down
    else
        log "Leaving existing container running"
        echo "Exiting deployment script"
        exit 0
    fi
fi

# Build and start the container
log "Building Alpha node container"
echo "This may take a while..."
docker compose -f "${SCRIPT_DIR}/${COMPOSE_FILE}" build

log "Starting Alpha node container"
docker compose -f "${SCRIPT_DIR}/${COMPOSE_FILE}" up -d

# Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "alpha-node"; then
    log "❌ Error: Failed to start Alpha node container"
    echo "Please check logs with: docker compose -f ${SCRIPT_DIR}/${COMPOSE_FILE} logs"
    exit 1
fi

log "✅ Alpha node container started successfully"

# Wait for node to respond
echo "Waiting for Alpha node to initialize..."
attempts=0
max_attempts=30
success=false

while [ $attempts -lt $max_attempts ]; do
    if docker exec alpha-node alpha-cli getblockcount &>/dev/null; then
        success=true
        block_count=$(docker exec alpha-node alpha-cli getblockcount)
        log "✅ Alpha node is responsive at block height: ${block_count}"
        break
    fi
    
    attempts=$((attempts + 1))
    echo -n "."
    sleep 5
done

echo ""

if [ "$success" != "true" ]; then
    log "⚠️ Alpha node did not respond within expected timeframe"
    echo "The node may still be initializing. Check status with:"
    echo "docker exec alpha-node alpha-cli getblockcount"
else
    echo "Container information:"
    docker ps --format "ID: {{.ID}}\nName: {{.Names}}\nStatus: {{.Status}}\nPorts: {{.Ports}}" | grep -A3 "alpha-node"
    
    echo ""
    echo "Node is running! Use the following commands to interact with it:"
    echo "  View logs: docker compose -f ${SCRIPT_DIR}/${COMPOSE_FILE} logs -f"
    echo "  Stop node: docker compose -f ${SCRIPT_DIR}/${COMPOSE_FILE} down"
    echo "  Run CLI:   docker exec -it alpha-node alpha-cli getinfo"
    echo ""
    echo "Run tests:   cd ${SCRIPT_DIR}/tests && ./test_container.sh"
fi

log "Deployment script completed"