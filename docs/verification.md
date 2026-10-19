# Verification

## Automated

Run `scripts/test.sh`. The latest run passed **180 tests in 22 suites**. Coverage includes:

- Left/right Command-Control conversion, aggregate/device flags, other modifiers, held-session consistency.
- Pointer locator: left/right double taps, effective mapping, shortcut interruption, timing, reset, independent enablement, duration migration/clamping/persistence, fixed-deadline closure and retrigger cancellation.
- Finder cut/move switch; browsing/text/unknown focus; user exceptions and no built-in terminal/remote presets.
- Native paste versus history shortcuts, native function/Enter/arrow actions, independent feature switches, scroll axes and continuous scrolling.
- Config persistence, setting search, keep-awake timing/failure/release.
- Dock placement, hover preloading, click actions, sizing, SwiftUI hosting and middle-button event bridge.
- Original-position window peek: hover debounce, stale capture rejection, cancellation on exit, no idle polling, hover removal, nonactivating/click-through panel and secondary-display coordinates. Native-resolution dimensions above 2048×1536, 5 physical-pixel external border, preference migration/search and queued capture cancellation are covered. MIT reference attribution is in `THIRD_PARTY_NOTICES.md`.
- Snap geometry and shared thumbnail caching, cancellation, memory pressure and late results.

## Interactive checks completed

The packaged app launches on macOS 27.2. All six SwiftUI settings pages were inspected. Chinese and English layouts, system light/dark appearance, live language switching were checked.

## Requires user-granted permissions / hardware

The new app has not been granted Accessibility or Screen Recording on this Mac. Real global keyboard rewriting, Finder copy/move, direct paste into other apps, window movement, actual Dock thumbnail capture and permission revocation must be exercised after those grants. No permissions were changed during implementation. Multi-display and multiple physical mouse verification require the corresponding hardware.

Suggested acceptance sequence:

1. Grant Accessibility in General, then test native paste/history with swap off, swap on, and an explicitly added exception.
2. Test pointer location with double Ctrl (swap off / excluded apps) and double Command (swap on); verify the dim backdrop and shrinking clear spotlight at screen edges, on secondary displays and in full-screen apps. Set the spotlight duration to 1 and 5 seconds; check that the timer starts after focus completes and expires equally while moving or stationary. Retrigger before expiry and verify a fresh interval. Check that shortcuts, held modifiers, clicks and scrolling do not trigger it. Test left/right modifier presses and releases, Shift/Option combinations, repeats, app switching while holding a modifier, and exit/relaunch.
3. In a disposable Finder folder, exercise the cut/move switch; confirm search/rename fields are unaffected and a fresh copy cancels pending move.
4. Check both scroll axes, natural-scrolling on/off, a trackpad, and more than one ordinary mouse.
5. Check edge-drag half/quarter layouts, drag-to-restore, multiple displays, native tiling conflicts and the assistant with no panel edge gap.
6. Grant Screen Recording; inspect bottom/left/right Dock, minimized windows, animations, middle-click, and both thumbnail consumers disabled.
7. Revoke individual permissions and confirm Keep Awake and unrelated modules remain available.

Original-position peek acceptance (requires Accessibility and Screen Recording): hover a covered window's thumbnail for 250 ms and confirm the single-frame preview matches its real size and position without changing focus. Scrub between thumbnails, leave, click, close/resize the target, change Spaces, disable Dock preview and unplug a display; no old preview should remain. Check bottom/left/right Dock, secondary and vertically arranged displays, cross-display windows and a target overlapping the thumbnail panel. Minimized/hidden/other-Space windows should retain thumbnails without placing an overlay on the current desktop. These real-window and physical multi-display checks have not been performed for this change.

HD peek changes: removed the 2048×1536 cap and low-resolution cache fallback; capture uses the window filter’s pixel scale (at least the target display backing scale). One native-resolution screenshot is allowed in flight, separate from the two card captures; cancellation/timeout retain the underlying slot until its callback returns. The Dock settings toggle defaults on for existing users, persists independently and hides the current preview immediately when switched off. Verify readable Retina text, the external light-blue border on 1×/2× displays and live toggle behavior on a permission-enabled Mac.

Border settings: Dock → Original-position hover preview now includes persistent border width (1–20 physical pixels, default 5) and corner radius (0–40 points, default 10). Tests cover migration, invalid values, persistence, settings search and style changes that keep the same captured image and original image geometry. Check both controls in Chinese/English and confirm they disable with the peek switch.
