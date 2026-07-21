#!/bin/sh
set -e

# Use a local DerivedData path inside the workspace if not overridden.
# This makes it self-contained and suitable for CI/CD pipelines.
DERIVED_DATA="${DERIVED_DATA_PATH:-./DerivedData}"

echo "DerivedData: $DERIVED_DATA"

xcodebuild \
    -project Chicken.xcodeproj \
    -scheme Chicken \
    -configuration Deployment \
    -derivedDataPath "$DERIVED_DATA"

