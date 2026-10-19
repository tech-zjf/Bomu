# Native interface specification

This document maps the approved visual reference to the current SwiftUI and AppKit implementation. The reference is [`UI设计稿.html`](../../player_plan/开发定稿/UI设计稿.html), with shared values in [`设计规范.json`](../../player_plan/开发定稿/设计规范.json). The HTML is a design reference; it is not shipped as an application view.

## Current acceptance

The source implementation covers the Home, Library, Folders, Favorites, Search, Player, and Settings surfaces. Earlier Screen 1 checks used one ordinary Bomu window and verified navigation, grid/list switching, an `h264` search, real local fixture names, and actual file-size fallbacks; no HTML view or prototype labels appeared. Comparing that build to the approved HTML exposed extra rounded media-card wrappers and an inset pane gap. The correction was rebuilt with Xcode 27 and passed static analysis; the current Debug app was reopened in one ordinary Screen 1 window. Home, Library, and Folders now share a continuous gray sidebar beside a white content pane; the media grid shows rounded artwork and no extra outer card surface, while the folder list remains flat. A fresh post-rebuild Library check also confirmed that every visible card uses the same 16:10 artwork box, one-line title, reserved two-line metadata area, and aligned file-size baseline. This removes the accidental uneven card heights caused by short metadata on some files and wrapped metadata on others; the grid is not intended as a masonry layout. The valid H.264, HEVC, and mixed-audio fixtures displayed their resolved file metadata; the other two fixtures remained explicitly unknown. A later Screen 1 capture at 1800×1264 image pixels showed the navigation, empty Continue Watching state, and three-column Recently Added grid without visible clipping. The screenshot API does not expose the AppKit point-space window frame. An earlier 1440×900 content-size attempt on the built-in display returned 884 pt for height, so that attempt failed and does not establish the required point-size layout. `system_profiler` now confirms an attached external display with a 1920×1080 pt UI mode; the user authorized moving the same ordinary Bomu window there, and the exact-size recheck remains pending. On 2026-10-16, temporarily enabling macOS Full Keyboard Access allowed Tab to reach the visible Library controls and Shift+Tab from main-pane Add Folder to return to sidebar Settings; the original system preference was restored afterward. Overall acceptance remains open: inspect at the three specified sizes, complete VoiceOver checks, and compare remaining visual details. Do not describe the interface as pixel-identical or fully accepted.

A previous Screen 1 Home capture showed real thumbnails and file sizes but `Unknown` technical metadata on three valid fixtures after relaunch. `ffprobe` and hostless probe/model tests confirmed the files contain metadata. Code inspection found that the cards used the same `Unknown` text while the asynchronous probe was pending and after an unavailable result, so that capture could not prove the final probe result. Cards and list rows now have a distinct localized loading state and a behavior test covers the loading-to-unavailable distinction. The latest clean Debug relaunch visibly resolved metadata for the H.264, HEVC, and mixed-audio fixtures in the single Library window. First-visible timing and VoiceOver order remain unverified.

The app currently declares English as its supported language. The Simplified Chinese catalog remains in the source tree for later activation and is checked for key and format-argument parity.

On 2026-10-19, the canonical Debug bundle (0.0.1, build 2, English only) was launched again in one restored ordinary window. Library showed matching artwork bounds and aligned filename/file-size baselines for `corrupt.mp4`, H.264, HEVC, mixed-audio, and MPEG-2 entries; unavailable metadata remained Unknown. The screenshot was 1920×1280 image pixels, with no independently measured AppKit content dimensions. The same window accepted a Chinese/space-containing directory through its open panel, displayed the corrupt-file error page, and recovered to silent video through keyboard selection in the new error-page queue menu. Returning to Library exposed the current playback bar; returning to Player showed an advanced timecode matching its playhead. The test app was quit afterward. These are specific visible behavior checks, not three-size or pixel-identical acceptance.

### Playback information placement — 2026-10-19

The user superseded the reference's external `.m-player-meta` footer for active playback: the playback page must be entirely a fixed 16:9 player stage, with no filename/path/size/format strip below it. A stage-local info icon opens those file details in a popover. The stage uses the largest size permitted by the available width and height and stays centered; its measured content no longer determines the parent window height. This is an explicit, documented deviation from `UI设计稿.html`, not a claim that the changed playback screen is pixel-identical to that reference. The media library keeps scroll gestures but hides scroll indicators at all times so its hidden layer does not switch indicator behavior as navigation changes. Debug build succeeded; visible popover and flicker acceptance remain pending because standard Launch Services activation returned `kLSNoExecutableErr`, and a direct executable launch produced an AppKit `RegisterApplication` abort before Bomu view code.

An earlier player-layout revision used the full available width and allowed the page to scroll. The subsequent viewport correction keeps the stage at a fixed 16:9 ratio, constrains it to the width and remaining height after measuring the details footer, and keeps the details in the same viewport. The stage has a 12 pt inset on all four sides; file details retain their independent 24 pt horizontal inset. A source comparison found that the top and stage-to-details insets had been omitted and the layout was corrected. After the user authorized updating the exact toolchain lock to installed Xcode 27.1 (27A9275), lock validation, Debug build, and static analysis passed. The rebuilt canonical Debug app was visibly checked at 960×640 pt (1928×1288 screenshot) and resized toward 1280×800 pt in one ordinary window; in both views the stage stayed 16:9, controls and file details remained visible, and no page scroll indicator appeared. AppKit frame dimensions were not independently available for the second view, so it is not counted as an exact-size pass. The latest Debug build visibly confirms the player toolbar's individual glass surfaces, 16 pt top/side placement, 6 pt button spacing, fixed 16:9 stage, complete file details, and no page scrollbar in one ordinary window. This is a single-window visual check, not a pixel-perfect comparison across the three required sizes. Sound/sync, calibrated color, reduced-transparency appearance, VoiceOver, and complete UI comparison remain open. The same content-area layout uses the design's 30 pt horizontal and 28 pt vertical inset on library pages. A source-to-CSS audit corrected shared typography tokens to the visual reference: page titles are 27 pt bold and section titles are 18 pt semibold. Search width was visibly checked at the earlier three sizes; the remaining screens and component details still need size-by-size visual comparison.

## Layout and components

| Surface | Native implementation | Reference behavior |
| --- | --- | --- |
| Application window | `BomuApp`, `MainWindowView` | System title bar and traffic lights; a single persistent player and library model |
| Navigation | `MediaLibrarySidebar` | Home, Library, Folders, Favorites, Search, locations, and Settings in a full-height gray pane directly beside the white content area; the selected destination remains distinct |
| Home | `MediaLibraryView` and `MediaLibraryCard` | Two-column Continue Watching and three-column Recently Added sections; rounded artwork with details below, without an additional outer card; View All and source labels |
| Library and Search | `MediaLibraryView` | Real indexed files, category and watched filters, and explicit empty/loading/error states |
| Preference feedback | `MediaLibraryView` | A five-second Undo action appears at the bottom after changing one file's favorite or watched state; it restores that preference through the library store. Live visual and accessibility review is still pending. |
| Folder browser | `MediaLibraryFolderViews` | Real source roots and subdirectories, breadcrumbs, grid/list density, and preserved navigation state |
| Playback | `PlayerScreen`, `EmptyPlayerView`, `PlaybackControls`, `VideoHostView` | One persistent video host with playback controls layered over the picture; media and control state come from the playback model |
| Startup failure | `StartupFailureView` in the application shell | The library and player stay unavailable after an unrecoverable startup failure; show the diagnostic and a clear quit-and-reopen action |
| Settings | `SettingsView` | Playback, subtitles, local data, and privacy settings use the native Settings scene. The Updates page shows the current version and explains that the pre-release build has no update service; active beta checks belong to C13. |

### Settings navigation — 2026-10-19

At the user's request, the Settings page replaces its horizontal tabs with a compact vertical section list inside the white content pane. The application-wide sidebar remains the primary navigation; the 164 pt Settings navigation rail is separated from the form area by a thin divider and does not introduce a second full-height gray panel. Section selection retains the existing five groups and their current state and actions. The rebuilt page was inspected in one ordinary window: the vertical hierarchy and selection state were visible, and Appearance and Storage both switched to their matching content. This is a deliberate update to the earlier horizontal-tab reference; the Settings page is not claimed to be pixel-identical to that reference. Exact-size and keyboard review remain part of overall acceptance.

## Visual tokens

`AppTheme` is the single native source for shared visual values. Values below are points unless noted.

The 2026-10-16 token audit corrected the content canvas to white. The approved UI reference styles `.m-sidebar` with `#F0F4F8` and `.m-main` with `#FFFFFF`; the earlier `contentCanvas` entry incorrectly repeated the sidebar color. `AppTheme.mutedSurface` names the shared gray secondary surface without implying that the main content pane is gray.

| Role | Current value |
| --- | --- |
| Text / secondary text | `#141D2D` / `#647084` |
| Library surface / sidebar and secondary surface / player fallback | `#FFFFFF` / `#F0F4F8` / `#111722` |
| Separator / warm accent | `#E5EAF0` / `#EFB98F` |
| Brand / page / section title | system serif 32 / system sans 27 / system sans 18 |
| Media title / media metadata / page subtitle / body subtitle | system sans 13 semibold / 11 / 12 / 13 |
| Sidebar width / Settings section navigation width / content horizontal and vertical insets | 176 / 164 / 30 and 28 |
| Sidebar outer insets / row height / section gap | 25, 13, 17 / 40 / 5 |
| Compact action / player toolbar target | 28 / 35 |
| Folder row icon / vertical inset | 44 / 12 |
| Metadata reserved height: standard grid / Continue Watching and list | 28 / 14 |
| Sidebar heading top, side, bottom / local tag top | 21, 12, 7 / 35 |
| Media grid columns / column gap / row gap / Continue Watching gap / folder grid gap | 3 / 17 / 23 / 16 / 17 |
| Section gap / player horizontal inset | 28 / 22 |
| Player stage outer inset / reference-only file details horizontal inset | 12 / 24 |
| Reference-only file details top / bottom inset | 3 / 17 |
| Window default / minimum / acceptance sizes | 1100×720 / 900×600 / 960×640, 1280×800, 1440×900 |
| Artwork / player / control / field radius | 14 / 14 / 12 / 12 |
| Selection / badge radius | 11 / 6 |
| Empty-state icon backing radius | 20 |

`BomuApp` declares the 1100×720 default and `.windowResizability(.contentMinSize)`. Both the library and player roots apply the shared 900×600 minimum. The three acceptance sizes come from the design baseline; they remain unverified as AppKit point-space frames until measured directly in the running app.

System sans is used for interface text and media details; system serif is reserved for brand display; time values use monospaced digits. No external fonts are bundled.

The library uses a continuous gray sidebar and white content plane. Media items do not receive an extra rounded background or border; only their artwork and the controls have component shapes. Menus, file panels, and system alerts retain their native macOS appearance.

Text and SF Symbol font roles live in `AppTheme.Typography`, including the player and library icon sizes and weights. View implementations do not define ad hoc font literals, so later visual tuning has one source of truth without changing the selected system font family.

Use the same tokens wherever components share a shape role. Keep folder rows, media items, and empty states free of outer cards; the empty-state icon may have its own backing. The play button remains circular. AppKit owns the native window corners.

## Interaction and accessibility

- A single click selects a media item; a double-click plays it. The explicit play action and context menu keep playback available to keyboard and pointer users, alongside favorite, watched, and manual-category actions.
- The playback page remains alive while browsing. Returning to the library does not stop playback; the current-playback bar reflects the same player state.
- Open, pause, seek, playback speed, audio/subtitle tracks, queue, volume, and fullscreen controls use native semantic controls with localized accessibility names.
- Playback controls remain visible while paused, while VoiceOver is active, or while a control is being used. Reduced transparency uses opaque backgrounds for the transport, header, timeline, loading/ended panels, drag prompt, and artwork controls/badges. Reduced motion disables the controls' visibility fade. The 2026-10-19 Debug build and static analysis pass; live system-preference verification remains open.
- Media duration, codec, resolution, tracks, and thumbnails must come from the selected local file. Do not substitute fabricated metadata or sample artwork.

## Application-wide consistency

The 2026-10-19 pass covers navigation, cards/lists, folder rows, playback controls and menus, error/ended pages, and all Settings tabs. Shared row hit areas, selection feedback, metadata sizing, seek availability, subtitle Off selection, and Settings slider layout were corrected. Detailed native evidence and remaining boundaries are in [interaction-consistency.md](interaction-consistency.md). Native form controls retain platform sizing instead of inheriting the media-card shape.

The subsequent application-wide pass also unified Search empty-state presentation and grid/list action-menu access, added adaptive folder breadcrumbs based on the actual navigation stack, constrained long folder headings, and disabled the hidden library/player layer's controls. These are implemented changes, with live keyboard and layout acceptance still pending; see the follow-up section of [interaction-consistency.md](interaction-consistency.md).

Toolbar menu entries now use the same icon geometry as ordinary toolbar buttons; ended actions share one style. Artwork overlays no longer intercept pointer input, and long Settings paths preserve action sizing. These source-level corrections passed build, regression and static analysis; Screen 1 was locked, so native focus, menu tracking and decorative-area click checks remain open.

## Remaining acceptance

- Compare every screen in the current Debug build with the approved reference at 960×640, 1280×800, and 1440×900 pt in one ordinary Bomu window on the same display. Player fit/ratio and Search width have been checked at these sizes; Home, Library, Folders, Favorites, and Settings still need full size-by-size comparison.
- Complete keyboard focus order and VoiceOver navigation across navigation, grids/lists, menus, file panels, Settings, and player controls.
- Confirm the visual hierarchy, typography, spacing, colors, and control proportions with the user. The listed token values document implementation; they do not prove visual acceptance.
- Test real media artwork and metadata. Synthetic fixtures are for playback and behavior checks only.

Record new evidence in [`progress.md`](../engineering/roadmap/progress.md) and update this specification only when the accepted design or implementation changes. Keep the product plan as the source for requirements and task dependencies.
