# Phase 1 Implementation Plan — Windows-Style Quick Snapping

**Status:** Implementation plan; no Swift source changes are included.  
**Branch:** `design/windows-snap-spec-v0.1`  
**Related documents:** [Product specification](PRODUCT_SPEC_DRAFT.md), [Settings and interaction draft](SETTINGS_UX_DRAFT.md)

## Repository findings

The fork already contains the core building blocks:

- `Rectangle/Snapping/SnappingManager.swift` and `SnapEdgeDetection.swift` handle drag-to-edge snapping and previews.
- `Rectangle/WindowAction.swift` already models left/right halves, top/bottom halves, four corners, maximize, restore, thirds, and other zones.
- `Rectangle/ShortcutManager.swift` binds actions and routes them to `WindowManager`.
- `Rectangle/SettingsWindow/ShortcutsViewController.swift` already provides editable shortcut recording and conflict validation.
- `Rectangle/WindowHistory.swift` stores restore frames and previous maximize frames.
- `Rectangle/WindowManager.swift` calculates and applies frame changes, including multi-display handling.

The first phase should extend these systems rather than introduce a second snapping engine or shortcut framework.

## Phase 0 — Safe baseline

1. Confirm the branch is based on the current fork and keep all changes on this branch.
2. Run the existing GitHub Actions build on the branch before changing Swift code; record the run and any existing failure.
3. Inspect the Xcode project’s app identifier, signing settings, and test targets. Keep a development build distinguishable from the separately installed Rectangle app.
4. Preserve Rectangle’s MIT license, copyright notices, and upstream attribution.
5. Do not add local machine paths, account details, credentials, or personal data to the repository.

**Exit condition:** A baseline CI result and a documented development identity are available before implementation.

## Phase 1 — Windows-style keyboard actions

### Shortcut map and compatibility

Use the agreed defaults:

| Action | Default |
| --- | --- |
| Left / right half | Control + Option + Left / Right |
| Maximize | Control + Option + Up |
| Restore, then minimize on the next press | Control + Option + Down |
| Four corners | Control + Option + Shift + Arrow |

Before registering these defaults, resolve the existing top-half and bottom-half bindings that currently use Control + Option + Up / Down. Give those two actions non-conflicting defaults or leave them unassigned, and show them in Settings so the user can bind them. Do not silently change a user’s saved shortcuts during upgrade: apply new mappings only to a clean install, and provide an explicit reset-to-new-defaults action.

Keep all existing Rectangle shortcuts editable, disableable, conflict-checked, and resettable through its current shortcut recorder. Preserve the existing shortcut storage keys and raw action identifiers; add new identifiers without renumbering persisted actions.

### Restore/minimize sequence

Implement the selected two-press behavior as a dedicated, documented action:

1. On the first press, if the focused window is snapped or maximized and has a recorded prior frame, restore it to that frame.
2. On the next press of the same action for that window, minimize it using the supported macOS accessibility/window action path.
3. If there is no saved restore frame, use the action’s defined fallback consistently and expose that behavior in Settings.
4. Clear or refresh the per-window sequence state when the user manually moves/resizes the window, changes the focused window, or invokes another placement action.
5. Never minimize a different window because focus changed between presses.

Reuse Rectangle’s existing restore history where it matches the behavior. Add only the smallest per-window state needed for the second press; do not infer state from window titles or contents.

### Settings and accessibility

- Add the new actions to the existing shortcut list and localization resources.
- Explain why Accessibility permission is needed and expose the current permission state.
- If permission is missing or a window rejects a move, leave the window untouched and show a clear, actionable message.
- Keep launch-at-login optional and off by default.
- Continue to respect the active display, minimum window sizes, Reduce Motion, and existing edge-preview settings.

## Phase 1 verification

Run checks through GitHub Actions on the implementation branch:

- Build the existing Xcode scheme on the configured macOS runner.
- Run the existing unit/UI test targets if they are configured; add focused tests for shortcut-default collisions, restore/minimize sequencing, and history reset only when a suitable test target exists.
- Verify CI reports the exact branch commit being reviewed.
- Record failing or unavailable checks as such; do not describe an unrun check as passing.

Manual checks that CI cannot prove should be listed for a later on-device pass: Accessibility permission, global shortcut registration against common apps, multi-display targeting, and minimizing/restoring representative windows.

## Phase 2 — Visual layout picker and Snap Assist

Start only after Phase 1 meets its acceptance criteria:

- Add the visual picker on the agreed editable default Control + Option + Z.
- Reuse existing window calculation and display geometry.
- Keep halves, quarters, thirds, and two-thirds editable, ordered, and hideable.
- Show Snap Assist automatically after a snap by default, but never move another window until the user selects it.
- Keep app names/icons visible by default; leave window titles and previews off unless explicitly enabled.
- Add focused interaction and geometry checks, then run the GitHub Actions build for the same branch.

## Phase 1 acceptance criteria

- Existing drag snapping and Rectangle actions remain available.
- Left/right halves, maximize, four corners, and the restore/minimize sequence act on the focused window.
- No default shortcut collision remains, and saved user bindings are preserved.
- Every new shortcut can be changed or disabled in the existing Settings UI.
- Accessibility denial or unsupported window behavior does not cause an uncontrolled move.
- CI results are visible on GitHub for the implementation commit.
- No source clone or build artifact is required on the user’s Mac.
