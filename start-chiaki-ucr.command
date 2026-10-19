#!/bin/zsh
# Launch Chiaki-ng with the Virtual DualSense Mouse+Keyboard UCR plugin injected
# and open the Chiaki-UCR control panel alongside it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB_PATH="${SCRIPT_DIR}/plugin/libchiaki_ucr.dylib"
CHIAKI_APP="/Applications/chiaki-ng.app"

if [ ! -f "$DYLIB_PATH" ]; then
    echo "Error: No se encontró $DYLIB_PATH"
    exit 1
fi

# Close any previous Chiaki instance so the plugin and network permissions load cleanly
killall chiaki 2>/dev/null || true

# Open the UCR Control Panel GUI if not already running
open -a "${SCRIPT_DIR}/Chiaki-UCR.app"

# Launch chiaki-ng via LaunchServices (open -n -a) so macOS grants org.streetpea.chiaking
# its native Local Network permission while injecting the UCR Virtual DualSense plugin
open -n -a "$CHIAKI_APP" \
    --env "DYLD_INSERT_LIBRARIES=$DYLIB_PATH" \
    --env "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1"

