#!/bin/bash
set -e

echo "Installing Python dependencies on $(hostname)..."
sudo pip3 install --ignore-installed pandas pyarrow numpy requests boto3 sentence-transformers lancedb torch
echo "Bootstrap complete."
