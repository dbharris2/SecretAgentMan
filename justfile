# SecretAgentMan - macOS Agent Session Manager

# List available recipes
default:
    @just --list

# Install pinned dev tools (SwiftLint, SwiftFormat) via mint
bootstrap: _check-xcode
    mint bootstrap

# Verify the active Xcode matches .xcode-version (fails fast if mismatched)
_check-xcode:
    #!/usr/bin/env bash
    set -eu
    required=$(cat .xcode-version)
    version_output=$(xcodebuild -version)
    first_line=${version_output%%$'\n'*}
    actual=${first_line#Xcode }
    if [ "$required" != "$actual" ]; then
        echo "This repo pins Xcode $required, but you're on $actual."
        echo "If Xcode $required is already installed:"
        echo "  sudo xcode-select -s /Applications/Xcode_$required.app"
        echo "If not, install it with the third-party 'xcodes' tool:"
        echo "  brew install xcodesorg/made/xcodes && xcodes install $required && xcodes select $required"
        exit 1
    fi

# Generate Xcode project from project.yml
generate: _check-xcode
    xcodegen generate

# Build the app (regenerates project first)
build: generate
    xcodebuild -scheme SecretAgentMan -configuration Debug build

# Run the app (builds first, kills existing instance)
run: build
    -pkill -x SecretAgentMan
    @open "$( xcodebuild -scheme SecretAgentMan -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}' )/SecretAgentMan.app"

# Open the app without rebuilding
open:
    -pkill -x SecretAgentMan
    @open "$( xcodebuild -scheme SecretAgentMan -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}' )/SecretAgentMan.app"

# Run SwiftFormat to auto-fix formatting
format:
    mint run swiftformat .

# Run SwiftLint with auto-fix
lint-fix:
    mint run swiftlint --fix

# Check formatting and linting without modifying files
lint:
    mint run swiftformat . --lint
    mint run swiftlint

# Scan for unused code with Periphery (config in .periphery.yml)
periphery: generate
    periphery scan

# Build release configuration
release: generate
    xcodebuild -scheme SecretAgentMan -configuration Release build

# Run the release build
run-release: release
    -pkill -x SecretAgentMan
    @open "$( xcodebuild -scheme SecretAgentMan -configuration Release -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}' )/SecretAgentMan.app"

# Run unit tests
test: generate
    xcodebuild -scheme SecretAgentMan -configuration Debug -destination 'platform=macOS' test

# Clean build artifacts
clean:
    xcodebuild -scheme SecretAgentMan -configuration Debug clean
    rm -rf ~/Library/Developer/Xcode/DerivedData/SecretAgentMan-*

# Open project in Xcode
xcode: generate
    open SecretAgentMan.xcodeproj
