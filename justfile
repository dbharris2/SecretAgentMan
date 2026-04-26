# SecretAgentMan - macOS Agent Session Manager

# List available recipes
default:
    @just --list

# Generate Xcode project from project.yml
generate:
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
    swiftformat .

# Run SwiftLint with auto-fix
lint-fix:
    swiftlint --fix

# Check formatting and linting without modifying files
lint:
    swiftformat . --lint
    swiftlint

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
