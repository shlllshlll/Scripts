#!/bin/bash
# export DOCKER_API_VERSION=1.41
# command docker "$@"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/docker-wrapper.sh"

docker "$@"

