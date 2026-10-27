# Windows-Style Snap Mode — Product Specification (Draft v0.1)

**Status:** Design draft for review. No implementation changes are included in this document.  
**Base:** Public fork of [Rectangle](https://github.com/rxhanson/Rectangle).  
**Audience:** macOS users who want keyboard-driven window snapping with Windows-like behavior.

## Product goal

Build a native macOS window-management app, based on Rectangle, that makes familiar Windows-style snapping quick to learn while keeping every shortcut and layout adjustable.

The app should remain a lightweight menu-bar utility. It must not read window contents, collect personal data, or send app usage or window data to a service.

## Principles

- Native macOS behavior and accessibility APIs.
- Reuse Rectangle's existing snap, window calculation, and multi-display code where appropriate.
- Keep the upstream MIT license and notices.
- Every keyboard shortcut is editable, including the shortcut that opens the visual layout picker.
- Layout presets and Snap Assist behavior are configurable rather than hard-coded.
- Do not move a second window automatically without the user's selection.
- Keep the existing Rectangle installation separate: development builds must use a distinct app identity before running.

## Phase 1 — Quick snapping

### Proposed default actions

These are starting defaults only; every binding can be changed or disabled in Settings.

| Action | Proposed default |
| --- | --- |
| Left half / right half | Control + Option + Left / Right |
| Maximize | Control + Option + Up |
| Restore previous frame | Control + Option + Down |
| Four screen corners | Control + Option + Shift + Arrow |
| Open visual layout picker | Control + Option + Z |

The final key bindings remain open for review. The Down behavior is decided: the first press restores a snapped or maximized window to its previous frame; a second press minimizes it.

### Snap input

- Drag a window to an edge or corner to snap it to that area.
- Use the display containing the focused window as the target display.
- Provide configurable thirds and other supported Rectangle zones through Settings.
- Keep animation and edge-preview controls configurable.

## Phase 2 — Visual layouts and Snap Assist

### Layout picker

- Open with the configurable layout-picker shortcut; the initial proposal is Control + Option + Z.
- Show a compact chooser for the active display with halves, quarters, thirds, and wider layouts.
- Let the user choose by keyboard or pointer.
- Let users enable, disable, reorder, and configure available layouts. Where supported, allow custom width/height ratios and screen-edge gaps.
- The green macOS window button is not a trigger in this draft. Hover support would need separate feasibility work and explicit design approval.

### Snap Assist

- After a window is snapped, optionally show other eligible windows that could fill the remaining regions.
- Snap Assist is configurable: users can enable/disable it, choose when it appears, and dismiss it.
- It must not move or resize another window until the user selects that window and a target region.
- Respect minimum window sizes and report when an app cannot fit a selected region.

## Settings and customization

Settings should include:

- A shortcut recorder for every action, including the layout picker and Snap Assist controls.
- Per-action enable/disable, conflict warnings, and a restore-defaults command.
- Conflict checks for duplicate bindings within the app. If macOS or another app prevents a shortcut from registering, explain that and let the user choose another binding.
- Layout management: enable/disable presets, choose their order, configure supported ratios and spacing, and assign shortcuts.
- Controls for edge snapping, preview, animation, repeated actions, and multi-display behavior.
- An Accessibility onboarding page that explains why permission is needed and opens the relevant System Settings pane. The app must not grant permission by itself.
- Optional launch-at-login setting, with a clear off/on state.

## Privacy and distribution

- No telemetry, account requirement, cloud sync, clipboard access, or window-content collection.
- Accessibility is used only for the window-management functions the user invokes.
- The source fork is public, so source changes and design documents in the repository are public. Never add personal or confidential information.
- Keep source work, design decisions, and review branches on GitHub. Do not create a local source clone.
- Use GitHub Actions with a macOS runner for remote build and verification if the repository's workflow supports it. Do not claim a build passed unless CI reports success.

## Decision recorded

- **Control + Option + Down:** first press restores a snapped or maximized window to its previous frame; a second press minimizes it, matching Windows behavior.

## Review decisions still open

1. Product name, app name, and icon.
2. Final default shortcut map and whether users can choose modifier presets.
3. Whether Snap Assist appears automatically after a snap or only on request.
4. Which custom ratios and spacing controls are included in the first release.
5. Exact multi-display cycling behavior.
6. Minimum macOS version and the remote build/release workflow.

## Acceptance criteria for the first implementation phase

- Left/right half, maximize, restore, and four-corner actions work on supported windows.
- Edge and corner dragging continue to work.
- Every action shortcut can be recorded, edited, disabled, and reset.
- A failed or conflicting shortcut is reported clearly.
- The app targets the focused window and its display.
- No window content is read or transmitted.
- Development builds cannot conflict with the installed Rectangle app.
