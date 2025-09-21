#!/bin/bash

# Check if number of containers is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <number_of_containers>"
    exit 1
fi

NUM_CONTAINERS=$1
IMAGE_NAME="tanmoysrt/minc:v2"
HOST_PORT=8081
CONTAINER_PORT=3000

# Kill all running containers at the start
echo "Stopping and removing all running containers..."
docker ps -q | xargs -r docker kill

# Function to clean up containers on exit
cleanup() {
    echo -e "\nCleaning up containers..."
    for cid in "${CONTAINER_IDS[@]}"; do
        docker kill "$cid" &>/dev/null
    done
    exit 0
}

# Trap Ctrl+C
trap cleanup SIGINT

# Run the containers
CONTAINER_IDS=()
for ((i=1;i<=NUM_CONTAINERS;i++)); do
    PORT=$((HOST_PORT + i - 1))
    echo "Starting container $i on port $PORT..."
    cid=$(docker run -d -p $PORT:$CONTAINER_PORT --hostname minc$i $IMAGE_NAME)
    CONTAINER_IDS+=("$cid")
done

# Wait indefinitely until Ctrl+C
echo "All containers running. Press Ctrl+C to stop..."
while true; do
    sleep 1
done