#!/bin/bash

# Script to manually build and push the Alpha node Docker image to GitHub Container Registry
# Usage: ./publish-image.sh [tag]

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="alpha"
TAG="${1:-latest}"

# Detect GitHub repository if in a Git repo
if git -C "${PROJECT_ROOT}" remote -v &>/dev/null; then
    GITHUB_REPO=$(git -C "${PROJECT_ROOT}" remote get-url origin | sed -n 's/.*github.com[:/]\([^/]*\/[^.]*\)\(\.git\)\?$/\1/p' | tr '[:upper:]' '[:lower:]')
    if [ -n "${GITHUB_REPO}" ]; then
        FULL_IMAGE_NAME="ghcr.io/${GITHUB_REPO}/${IMAGE_NAME}"
    else
        echo "Cannot detect GitHub repository from Git remote URL."
        echo "Using local image name: ${IMAGE_NAME}"
        FULL_IMAGE_NAME="${IMAGE_NAME}"
    fi
else
    echo "Not a Git repository or no remotes configured."
    echo "Using local image name: ${IMAGE_NAME}"
    FULL_IMAGE_NAME="${IMAGE_NAME}"
fi

echo "========================================"
echo "   Alpha Node Docker Image Publisher   "
echo "========================================"
echo ""
echo "Building and publishing Docker image for Alpha node"
echo "Image: ${FULL_IMAGE_NAME}:${TAG}"
echo ""

# Check Docker installation
if ! command -v docker &>/dev/null; then
    echo "❌ Error: Docker is not installed"
    echo "Please install Docker first: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if user is logged in to GitHub Container Registry
if [[ "${FULL_IMAGE_NAME}" == ghcr.io/* ]]; then
    if ! docker info | grep -q "ghcr.io"; then
        echo "⚠️ You don't appear to be logged in to GitHub Container Registry"
        echo "To login, run:"
        echo "  echo \${GITHUB_PAT} | docker login ghcr.io -u USERNAME --password-stdin"
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# Build the Docker image
echo "Building Docker image..."
docker build -t "${FULL_IMAGE_NAME}:${TAG}" -f "${SCRIPT_DIR}/Dockerfile" "${PROJECT_ROOT}"

# Tag as latest if not already
if [ "${TAG}" != "latest" ]; then
    echo "Tagging as latest as well..."
    docker tag "${FULL_IMAGE_NAME}:${TAG}" "${FULL_IMAGE_NAME}:latest"
fi

# Ask for confirmation before pushing
if [[ "${FULL_IMAGE_NAME}" == ghcr.io/* ]]; then
    echo ""
    echo "Ready to push the following tags to GitHub Container Registry:"
    echo "  ${FULL_IMAGE_NAME}:${TAG}"
    echo "  ${FULL_IMAGE_NAME}:latest"
    echo ""
    read -p "Push these images? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Pushing images to GitHub Container Registry..."
        docker push "${FULL_IMAGE_NAME}:${TAG}"
        docker push "${FULL_IMAGE_NAME}:latest"
        echo "✅ Images pushed successfully!"
    else
        echo "Push cancelled. Images are built locally only."
    fi
else
    echo ""
    echo "Local image built successfully:"
    echo "  ${FULL_IMAGE_NAME}:${TAG}"
fi

echo ""
echo "To run this image:"
echo "  docker run -d --name alpha-node \\"
echo "    -p 8589:8589 -p 7933:7933 \\"
echo "    -v alpha-data:/root/.alpha \\"
echo "    ${FULL_IMAGE_NAME}:${TAG}"