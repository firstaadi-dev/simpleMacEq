#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# Keep test access to private graph state out of the shipping app.
cat simpleMacEq/Audio/AudioController.swift tests/AudioRecoveryTests.swift > "$test_dir/AudioController.swift"
cat simpleMacEq/Audio/AudioProcessMonitor.swift tests/AudioProcessMonitorTestSupport.swift > "$test_dir/AudioProcessMonitor.swift"
swiftc -swift-version 5 -suppress-warnings -o "$test_dir/regressions" \
    "$test_dir/AudioController.swift" \
    "$test_dir/AudioProcessMonitor.swift" \
    simpleMacEq/Audio/OutputDeviceManager.swift \
    simpleMacEq/Audio/CoreAudioHelpers.swift \
    simpleMacEq/Audio/ProcessTap.swift simpleMacEq/Audio/RingBuffer.swift \
    simpleMacEq/App/*.swift simpleMacEq/Models/*.swift \
    tests/RingBufferTests.swift
"$test_dir/regressions"
cat simpleMacEq/Audio/AudioController.swift tests/AudioGraphRecoveryTests.swift > "$test_dir/AudioController.swift"
cat simpleMacEq/App/AppState.swift tests/AppStateTestSupport.swift > "$test_dir/AppState.swift"
swiftc -swift-version 5 -suppress-warnings -o "$test_dir/graph-regressions" \
    "$test_dir/AudioController.swift" "$test_dir/AudioProcessMonitor.swift" \
    simpleMacEq/Audio/OutputDeviceManager.swift simpleMacEq/Audio/CoreAudioHelpers.swift \
    simpleMacEq/Audio/RingBuffer.swift tests/SyntheticProcessTap.swift \
    "$test_dir/AppState.swift" simpleMacEq/App/AppSettings.swift simpleMacEq/Models/*.swift
"$test_dir/graph-regressions"
