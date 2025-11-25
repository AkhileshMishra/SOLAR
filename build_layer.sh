#!/bin/bash
# Build script for python-docx Lambda layer

set -e

echo "Building python-docx Lambda layer..."

# Create directory structure
mkdir -p layers/python-docx/python
mkdir -p .terraform/layers

# Install dependencies
echo "Installing dependencies..."
pip install -r layers/python-docx-requirements.txt -t layers/python-docx/python/

# Create zip archive
echo "Creating zip archive..."
cd layers/python-docx
zip -r ../../.terraform/layers/python-docx.zip .
cd ../..

echo "Lambda layer built successfully: .terraform/layers/python-docx.zip"
