# GitHub Actions Workflows for Alpha

This directory contains GitHub Actions workflows for automating tasks in the Alpha project.

## Docker Image Publishing

The `docker-publish.yml` workflow automatically builds and publishes Docker images to GitHub Container Registry (ghcr.io) when:

1. A new GitHub Release is published
2. The workflow is manually triggered

### How It Works

When a new release is created:

1. GitHub Actions checks out the code
2. Sets up Docker Buildx for multi-platform builds
3. Logs in to GitHub Container Registry using the built-in GITHUB_TOKEN
4. Builds the Docker image using the Dockerfile in the docker/ directory
5. Tags the image with both the release version and 'latest'
6. Pushes the image to ghcr.io/{owner}/alpha
7. Updates the container description with the contents of docker/README.md

### Manual Triggering

You can manually trigger a build by:

1. Going to the "Actions" tab in GitHub
2. Selecting "Build and Publish Docker Image" workflow
3. Clicking "Run workflow"
4. Optionally specifying a tag (leave empty for 'latest')

### Image Access

The published images will be available at:

```
ghcr.io/{owner}/alpha:latest
ghcr.io/{owner}/alpha:{tag}
```

Where `{owner}` is your GitHub username or organization name, and `{tag}` is the release version.

### Local Building and Publishing

You can also build and push the Docker image locally using the provided script:

```bash
./docker/publish-image.sh [tag]
```

This script will:

1. Build the Docker image locally
2. Tag it with both the specified tag and 'latest'
3. Push it to GitHub Container Registry (if you're logged in)

### Required Permissions

For the workflow to function properly:

1. The repository must have "Read and write permissions" for "Workflow permissions" in Settings → Actions → General
2. If using organization packages, the repository must have package write access configured in the organization settings