# Alpha Node Docker Test Scripts

This directory contains utility scripts for testing and monitoring the Alpha node Docker container. These scripts help verify the correct operation of the container and monitor its performance.

## Available Scripts

### 1. `test_container.sh`

A comprehensive test suite that verifies the Alpha node container is working correctly. It checks:
- If the container is running
- If required ports are open
- If the alpha-cli tool is functioning properly
- If the node can respond to basic queries

**Usage:**
```bash
./test_container.sh
```

**Output:**
```
Starting Alpha node container test...
✅ Container alpha-node is running
✅ Ports 8589 (RPC) and 7933 (P2P) are open
✅ alpha-cli is working properly
✅ Node info can be retrieved
✅ All tests passed successfully!
```

### 2. `start_and_monitor.sh`

Automates the startup process and monitors the Alpha node until it's fully initialized. This script:
- Stops any existing Alpha node container
- Starts a fresh container using Docker Compose
- Waits for the node to initialize
- Reports on block height and node information
- Creates a log file at `/tmp/alpha_node_monitor.log`

**Usage:**
```bash
./start_and_monitor.sh
```

**Output:**
```
Starting Alpha node with Docker Compose...
Waiting for node to start (max 120 seconds)...
Waiting for node to be ready... (10s elapsed)
Waiting for node to be ready... (20s elapsed)
Node is running! Current block height: 197000

===== Alpha Node Information =====
{
  "version": 260100,
  "blocks": 197000,
  "connections": 8,
  "difficulty": 123456.78,
  ...
}
================================== 

Node is running and ready to use!
To run tests: ./test_container.sh
To stop node: docker compose -f /home/vrogojin/Projects/alpha/docker/docker-compose.yml down
To view logs: docker compose -f /home/vrogojin/Projects/alpha/docker/docker-compose.yml logs -f
```

### 3. `check_sync_status.sh`

Checks the blockchain synchronization status of a running Alpha node container. This script:
- Retrieves and displays current block height
- Shows synchronization progress as percentage
- Reports on connection count
- Shows mempool transaction count
- Displays container uptime

**Usage:**
```bash
./check_sync_status.sh
```

**Output:**
```
Checking Alpha node synchronization status...
Current Status:
Block Height: 197000
Headers: 197000
Sync Progress: 100.00%
✅ Node is fully synchronized with the network
Connections: 8
Mempool Transactions: 12
Container Uptime: 2d 5h 37m
```

## Integration with CI/CD

These scripts can be integrated into CI/CD pipelines for automated testing:

```yaml
# Example GitLab CI configuration
test_alpha_node:
  stage: test
  script:
    - cd docker/tests
    - ./start_and_monitor.sh
    - ./test_container.sh
    - ./check_sync_status.sh
  artifacts:
    paths:
      - /tmp/alpha_node_monitor.log
```

## Customizing the Scripts

You can customize these scripts by modifying the following variables:

### In `test_container.sh`:
- `CONTAINER_NAME`: The name of the Alpha node container
- `RPC_PORT`: The port used for RPC connections
- `P2P_PORT`: The port used for P2P connections

### In `start_and_monitor.sh`:
- `COMPOSE_FILE`: Path to the docker-compose.yml file
- `LOG_FILE`: Path where logs will be stored
- `MAX_STARTUP_TIME`: Maximum time to wait for the node to start
- `CHECK_INTERVAL`: Time between status checks

### In `check_sync_status.sh`:
- `CONTAINER_NAME`: The name of the Alpha node container

## Troubleshooting

If the scripts fail, check the following:

1. Make sure the container is running:
   ```bash
   docker ps | grep alpha-node
   ```

2. Check container logs for errors:
   ```bash
   docker logs alpha-node
   ```

3. Ensure docker-compose.yml path is correct in `start_and_monitor.sh`

4. Verify the Docker daemon is running:
   ```bash
   systemctl status docker
   ```

5. Ensure your user has permission to run Docker commands:
   ```bash
   sudo usermod -aG docker $USER
   ```
   (Log out and log back in after running this command)