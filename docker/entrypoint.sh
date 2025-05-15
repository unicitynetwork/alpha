#!/bin/bash
set -e

# Function to handle configuration
setup_config() {
  # Default location for config
  CONFIG_DIR="/root/.alpha"
  mkdir -p $CONFIG_DIR
  
  # Check for mounted config file
  if [ -f "/config/alpha.conf" ]; then
    echo "Using mounted configuration from /config/alpha.conf"
    cp /config/alpha.conf $CONFIG_DIR/alpha.conf
  # Check for local config file
  elif [ -f "/etc/alpha/alpha.conf" ]; then
    echo "Using local configuration from /etc/alpha/alpha.conf"
    cp /etc/alpha/alpha.conf $CONFIG_DIR/alpha.conf
  # Use default config file
  else
    echo "Using default configuration file"
    cp /etc/alpha/alpha.conf.default $CONFIG_DIR/alpha.conf
  fi
}

# Handle configuration
setup_config

# First argument is alphad or alpha-cli
if [ "$1" = "alphad" ]; then
  echo "Starting Alpha daemon..."
  exec alphad -conf=/root/.alpha/alpha.conf "${@:2}"
elif [ "$1" = "alpha-cli" ]; then
  echo "Running Alpha CLI command..."
  exec alpha-cli -conf=/root/.alpha/alpha.conf "${@:2}"
else
  # Assume any other command is to be executed directly
  exec "$@"
fi