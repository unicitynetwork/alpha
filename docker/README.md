# Alpha Node Docker Implementation

This document explains how to build and run the Alpha node in a Docker container.

## Overview

The Docker implementation provides:
- A multi-stage build process that minimizes container size
- Proper handling of RandomX dependency
- Volume mounting for persistent blockchain data
- Configuration customization options
- Automated test scripts for validation

## Quick Start

To build and run the Alpha node container:

```bash
# Build the Docker image
docker compose -f docker/docker-compose.yml build

# Start the container
docker compose -f docker/docker-compose.yml up -d

# Check the logs
docker compose -f docker/docker-compose.yml logs -f
```

## Directory Structure

- `Dockerfile` - Multi-stage build definition
- `docker-compose.yml` - Service definition with volume configuration
- `entrypoint.sh` - Container startup script
- `alpha.conf.default` - Default node configuration
- `config/` - Directory for custom configuration (optional)
- `tests/` - Test scripts for verification and monitoring

## Configuration

The Alpha node supports flexible configuration using a layered approach:

1. A default configuration (`/etc/alpha/alpha.conf.default`) is embedded in the Docker image
2. You can override it by providing your own config when running the container

### Using a Custom Configuration File

You have multiple options for using a custom configuration:

#### Option 1: Bind Mount a Configuration File

```bash
docker run -d --name alpha-node \
  -p 8589:8589 \
  -p 7933:7933 \
  -v alpha-data:/root/.alpha \
  -v $(pwd)/your-alpha.conf:/config/alpha.conf:ro \
  alpha-node
```

#### Option 2: Using Docker Compose with Custom Config

1. Copy the example config in the `config` directory:

```bash
cd docker
cp config/alpha.conf.example config/alpha.conf
```

2. Edit `config/alpha.conf` with your preferred settings

3. Run using docker-compose:

```bash
docker compose -f docker/docker-compose.yml up -d
```

The configuration will be automatically detected and used.

## Persistent Storage

The docker-compose configuration already includes persistent storage. The blockchain data is stored in a named volume `alpha-data` that persists when the container is destroyed and recreated.

## Exposed Ports

- **8589** - RPC port (for API access)
- **7933** - P2P port (for network communication)

## Testing and Monitoring

Several test scripts are provided in the `tests/` directory:

- `test_container.sh` - Verifies the container is working properly
- `start_and_monitor.sh` - Automates starting and monitoring the node
- `check_sync_status.sh` - Checks blockchain synchronization status

Example usage:
```bash
cd docker/tests
./start_and_monitor.sh
./test_container.sh
./check_sync_status.sh
```

## Running alpha-cli in the Container

### Method 1: Execute Commands Directly

```bash
docker exec -it alpha-node alpha-cli getblockcount
```

### Method 2: Interactive Shell

```bash
docker exec -it alpha-node bash
```

Then from within the container:
```bash
alpha-cli getblockcount
```

### Method 3: Using Docker Compose

```bash
docker compose -f docker/docker-compose.yml exec alpha alpha-cli getblockcount
```

## RPC Access from Outside the Container

To access the RPC interface from outside, ensure:

1. Your alpha.conf contains these settings:
```
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0
rpcuser=your_username
rpcpassword=your_secure_password
```

2. The port is published as shown above (8589)

3. Use RPC with appropriate credentials:
```bash
curl --user your_username:your_secure_password \
  --data-binary '{"jsonrpc":"1.0","method":"getblockcount","params":[]}' \
  -H 'content-type: text/plain;' http://localhost:8589/
```

## Container Structure

- `/root/.alpha`: Data directory (mount point for persistent data)
- `/config`: Mount point for custom configuration
- `/etc/alpha/alpha.conf.default`: Default configuration file
- `/entrypoint.sh`: Startup script that manages configuration priorities

## Default Configuration

The default configuration in `docker/alpha.conf.default` includes:

```
rpcuser=user
rpcpassword=password
chain=alpha
server=1
rpcbind=0.0.0.0
rpcport=8589
txindex=1
```

## Troubleshooting

### Common Issues

1. **RandomX Dependency Issues**
   - The container includes proper linking for the RandomX library
   - Verify library presence with: `docker exec alpha-node ls -la /usr/local/lib/librandomx*`

2. **Binary Name Mismatches**
   - The Dockerfile handles renaming between bitcoind/alphad appropriately
   - Verify binary names with: `docker exec alpha-node which alphad alpha-cli`

3. **Permission Problems**
   - If you encounter permission issues with mounted volumes:
     ```bash
     sudo chown -R 1000:1000 ./config
     ```

4. **Connection Issues**
   - Ensure ports 8589 and 7933 are accessible on your host
   - Check firewall settings if connecting remotely

## Security Considerations

- The example RPC settings allow connections from anywhere. In production, use specific IP addresses in `rpcallowip`.
- Always use strong passwords for RPC access
- Consider using a reverse proxy with TLS for public-facing nodes
- For production environments, consider additional security measures:
  - Use a non-root user in the container
  - Implement proper firewall rules
  - Set strong RPC credentials