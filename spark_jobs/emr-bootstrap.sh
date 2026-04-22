#!/bin/bash
set -e

echo "Installing Python dependencies on $(hostname)..."
sudo pip3 install pandas pyarrow numpy requests boto3
echo "Bootstrap complete."
