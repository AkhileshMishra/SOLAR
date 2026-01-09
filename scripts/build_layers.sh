#!/bin/bash
# Build script for all Lambda layers
# Creates zip files in .terraform/layers/ for Terraform deployment

set -e

echo "=========================================="
echo "Building Lambda Layers for Python 3.11"
echo "=========================================="

# Create output directory
mkdir -p .terraform/layers

# Python version for Lambda runtime
PYTHON_VERSION="python3.11"
SITE_PACKAGES="python/lib/${PYTHON_VERSION}/site-packages"

# Function to build a layer from requirements file
build_layer() {
    local LAYER_NAME=$1
    local REQUIREMENTS_FILE=$2
    local OUTPUT_ZIP=$3
    
    echo ""
    echo "Building ${LAYER_NAME}..."
    echo "----------------------------------------"
    
    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    mkdir -p "${TEMP_DIR}/${SITE_PACKAGES}"
    
    # Install dependencies
    echo "Installing dependencies from ${REQUIREMENTS_FILE}..."
    pip install -q -r "${REQUIREMENTS_FILE}" -t "${TEMP_DIR}/${SITE_PACKAGES}" --platform manylinux2014_x86_64 --only-binary=:all: 2>/dev/null || \
    pip install -q -r "${REQUIREMENTS_FILE}" -t "${TEMP_DIR}/${SITE_PACKAGES}"
    
    # Remove unnecessary files to reduce size
    find "${TEMP_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "${TEMP_DIR}" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
    find "${TEMP_DIR}" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
    find "${TEMP_DIR}" -type f -name "*.pyc" -delete 2>/dev/null || true
    
    # Create zip
    echo "Creating ${OUTPUT_ZIP}..."
    cd "${TEMP_DIR}"
    zip -q -r "${OLDPWD}/${OUTPUT_ZIP}" python
    cd "${OLDPWD}"
    
    # Cleanup
    rm -rf "${TEMP_DIR}"
    
    # Show size
    SIZE=$(du -h "${OUTPUT_ZIP}" | cut -f1)
    echo "✓ ${LAYER_NAME} built successfully (${SIZE})"
}

# Build pandas layer
build_layer "pandas-layer" "layers/pandas-layer-requirements.txt" ".terraform/layers/pandas-layer.zip"

# Build python-docx layer
build_layer "python-docx-layer" "layers/python-docx-requirements.txt" ".terraform/layers/python-docx.zip"

# Build pypdf layer (create requirements if not exists)
if [ ! -f "layers/pypdf-requirements.txt" ]; then
    echo ""
    echo "Creating pypdf requirements file..."
    cat > layers/pypdf-requirements.txt << EOF
pypdf>=4.0.0
cryptography>=41.0.0
EOF
fi
build_layer "pypdf-layer" "layers/pypdf-requirements.txt" ".terraform/layers/pypdf-layer.zip"

echo ""
echo "=========================================="
echo "All layers built successfully!"
echo "=========================================="
echo ""
echo "Layer files created:"
ls -lh .terraform/layers/*.zip
