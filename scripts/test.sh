#!/bin/bash
# Runs the Swift package tests.
#
# With only the Command Line Tools installed, SwiftPM's default build engine does not pass the
# Swift Testing macro plugin path to the compiler ("plugin for module 'TestingMacros' not found").
# Add it explicitly in that case; with full Xcode selected this adds nothing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

extra=()
developer_dir="$(xcode-select -p)"
plugin_dir="$developer_dir/usr/lib/swift/host/plugins/testing"
if [[ "$developer_dir" == *CommandLineTools* && -d "$plugin_dir" ]]; then
  extra=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
fi

exec swift test ${extra[@]+"${extra[@]}"} "$@"
