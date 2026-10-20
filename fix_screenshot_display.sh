#!/usr/bin/env bash
# Fix blank screenshots from gestures (3-finger swipe etc.) when the freeform
# virtual display (id != 0) is reported as the "focused display".
#
# Patches SystemUI TakeScreenshotExecutor.kt so that the focused-display branch
# only accepts a real (internal/external, non-freeform) display and otherwise
# falls back to the default display, like the key-chord path already does.
#
# Usage (from the ROM source root):   bash fix_screenshot_display.sh
#   or:  FWB=/path/to/frameworks/base bash fix_screenshot_display.sh
# Idempotent: safe to run on every build. Exits non-zero if the code changed
# upstream and the anchor can't be found, so a silent no-op can't slip by.
set -euo pipefail

FWB="${FWB:-frameworks/base}"
FILE="$FWB/packages/SystemUI/src/com/android/systemui/screenshot/TakeScreenshotExecutor.kt"

[ -f "$FILE" ] || { echo "[screenshot-fix] not found: $FILE" >&2; exit 1; }

python3 - "$FILE" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARK = "isScreenshotCapableDisplay"
if MARK in src:
    print("[screenshot-fix] already applied")
    sys.exit(0)

old_branch = """                val focusedDisplay = getFocusedDisplay()
                Log.i(TAG, "Focused display ID is $focusedDisplay")
                displayManager.getDisplay(focusedDisplay)
                    ?: displayManager.getDisplay(Display.DEFAULT_DISPLAY)
                    ?: error("Can't find default display")
"""
new_branch = """                val focusedDisplay = getFocusedDisplay()
                Log.i(TAG, "Focused display ID is $focusedDisplay")
                displayManager.getDisplay(focusedDisplay)?.takeIf { isScreenshotCapableDisplay(it) }
                    ?: displayManager.getDisplay(Display.DEFAULT_DISPLAY)
                    ?: error("Can't find default display")
"""
old_fn = """    private suspend fun getFocusedDisplay() =
        withContext(backgroundDispatcher) { screenshotProxy.getFocusedDisplay() }
"""
new_fn = old_fn + """
    /**
     * The focus tracker can report a virtual display (e.g. the freeform display) that has no
     * content, which produces blank screenshots. Only trust the default display or a real
     * internal/external display; anything else falls back to the default display.
     */
    private fun isScreenshotCapableDisplay(display: Display): Boolean {
        if (display.displayId == Display.DEFAULT_DISPLAY) return true
        val realType = display.type == Display.TYPE_INTERNAL || display.type == Display.TYPE_EXTERNAL
        val freeform = display.name?.contains("freeform", ignoreCase = true) == true
        return realType && !freeform
    }
"""

for label, old in (("focused-display branch", old_branch), ("getFocusedDisplay()", old_fn)):
    if src.count(old) != 1:
        sys.exit(f"[screenshot-fix] anchor for {label} not found exactly once - "
                 "upstream changed, update the script")

src = src.replace(old_branch, new_branch).replace(old_fn, new_fn)
open(path, "w", encoding="utf-8").write(src)
print("[screenshot-fix] applied")
PY
