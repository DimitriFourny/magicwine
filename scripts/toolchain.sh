#!/bin/bash
# Shared by the app packager and test runner; does not modify the selected tools.
TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
SDK="${MAGICWINE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
# The macOS 27 preview Command Line Tools omit SwiftUIMacros. This app uses
# macOS 14 APIs, so the complete installed 26.5 SDK builds the same app on 27.
if [[ -z "${MAGICWINE_SDK:-}" && "$TOOLCHAIN_USR" == /Library/Developer/CommandLineTools/usr \
      && "$(xcrun --sdk macosx --show-sdk-version)" == 27.* && ! -f "$TOOLCHAIN_USR/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    SDK="$(xcrun --sdk macosx26.5 --show-sdk-path)"
    printf 'Using complete macOS 26.5 SDK; preview Command Line Tools lack SwiftUIMacros.\n'
fi
SWIFT_OPTIONS=(--sdk "$SDK")
