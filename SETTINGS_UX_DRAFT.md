# Settings and Interaction Design (Draft v0.1)

**Status:** UX draft for review; no code changes are included.  
**Parent specification:** [PRODUCT_SPEC_DRAFT.md](PRODUCT_SPEC_DRAFT.md)  
**Branch:** `design/windows-snap-spec-v0.1`

## Product shell

- Run as a menu-bar utility with no permanent main window or Dock icon.
- Menu-bar menu provides quick actions for left/right half, maximize, restore, layout picker, Settings, and Quit.
- Every quick action is also available from Settings and can be bound to a user-chosen shortcut.
- Keep the app name and icon undecided until branding and release planning.

## First launch

1. Explain that Accessibility permission lets the app position windows the user selects.
2. Show the current permission state and a button that opens System Settings → Privacy & Security → Accessibility.
3. Do not grant permission automatically or request unrelated permissions.
4. Once permission is active, offer a reversible test action on the focused window.

## Settings navigation

Use a standard native macOS Settings window with these sections.

### General

- Launch at login: off by default, user-controlled.
- Menu-bar icon: on by default.
- Window animation: on by default and respects macOS Reduce Motion.
- Screen-edge gap and preview visibility.
- Reset all preferences to defaults.

### Shortcuts

Show one row per action with its current shortcut, an edit/record control, enabled state, and conflict status.

Include:

- Half, maximize, restore/minimize, corner, third, and two-thirds actions.
- Open layout picker.
- Snap Assist controls.
- Explicit move-to-next-display and move-to-previous-display actions.

All bindings can be changed or disabled, including `Control + Option + Z`. Support restoring one shortcut or all shortcuts to defaults. Detect duplicate bindings inside the app and report when macOS refuses a registration; do not silently replace another binding.

### Layouts

- List built-in presets: halves, quarters, thirds, and two-thirds.
- Enable/disable and reorder presets.
- Assign a separate shortcut to a preset.
- Add, rename, edit, and remove custom presets.
- Where supported by the window and display, adjust ratios and spacing.
- Provide a preview of the selected layout before saving.

### Behavior

- Edge and corner drag snapping: on by default, user-controlled.
- Target display: the display containing the focused window by default.
- Repeating a snap shortcut does not unexpectedly move a window to another display.
- Restore/minimize behavior: restore on the first Down action, minimize on the next; users can change the action binding and behavior.
- Snap Assist: on by default, shown after a window snaps; can be disabled or set to appear only when requested.
- Show layout previews and animate transitions: individually configurable.

### Accessibility and privacy

- Show whether Accessibility permission is active and provide a button to open its System Settings pane.
- Explain that the permission is used to identify and arrange the window selected by the user.
- No clipboard access, telemetry, account, cloud sync, or transmission of window data.
- Snap Assist shows app icons and app names by default. Window titles and previews are off by default because titles can contain private information; if previews are later offered, make them an explicit opt-in.

### About

- Show app version, source fork, upstream attribution, and MIT license.
- Link to the public source repository and its privacy statement.

## Layout picker interaction

- Open with the configurable picker shortcut; initial default is `Control + Option + Z`.
- Anchor the chooser near the focused window on its display.
- Show a visual map of available zones, including halves, quarters, thirds, and two-thirds.
- Navigate zones with arrow keys; apply with Return; dismiss with Escape. Pointer selection is also available.
- Use the display's usable area and configured gaps. Do not cover the Dock or menu bar.

## Snap Assist interaction

- After snapping one window, show eligible applications that can fill the remaining area.
- Select an app and destination zone to arrange it; Escape or clicking outside dismisses the suggestions.
- Never move a suggested window until the user selects it.
- Respect minimum window dimensions and explain when a selected layout cannot fit.

## Design constraints

- Keep all settings local to the Mac; do not sync them to GitHub or another service.
- Keep the public design docs free of personal information.
- Use the existing Rectangle settings architecture where possible, but keep every added control understandable without technical knowledge.
- Build and verify remotely on GitHub; do not create a local source clone.
