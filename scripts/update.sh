#!/bin/bash

echo "Stopping containers"
docker compose down

echo "Downloading latest images from docker hub ... this can take a while"
docker compose pull

echo "Building images if needed"
docker compose build

echo "Starting compose stack up again"
docker compose up -d

echo "Consider running prune-images /volumes to free up space"
