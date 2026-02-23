#!/usr/bin/env bash
# E2E test configuration constants

# Docker
IMAGE_NAME="alpha-e2e"
NETWORK_NAME="alpha-e2e-net"
CONTAINER_PREFIX="alpha-e2e-node"
NUM_AUTHORIZED=5
NUM_NODES=7  # 5 authorized + 2 non-authorized

# Chain
CHAIN="alpharegtest"
FORK_HEIGHT=10
COINBASE_MATURITY=100

# Ports (alpharegtest defaults both P2P and RPC to 28589; we separate them)
P2P_PORT=28589
RPC_PORT=28590

# RPC credentials
RPC_USER="test"
RPC_PASS="test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0
