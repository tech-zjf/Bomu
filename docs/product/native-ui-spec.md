# Native interface specification

This document maps the approved visual reference to the current SwiftUI and AppKit implementation. The reference is [`UI设计稿.html`](../../player_plan/开发定稿/UI设计稿.html), with shared values in [`设计规范.json`](../../player_plan/开发定稿/设计规范.json). The HTML is a design reference; it is not shipped as an application view.

## Current acceptance

The source implementation covers the Home, Library, Folders, Favorites, Search, Player, and Settings surfaces. Overall visual acceptance is still open. A recent desktop inspection could not establish that the visible window was the current Debug build, so it does not count as acceptance evidence. Do not describe the interface as pixel-identical or fully accepted until the current build is checked in one ordinary Bomu window.

The app currently declares English as its supported language. The Simplified Chinese catalog remains in the source tree for later activation and is checked for key and format-argument parity.

## Layout and components

| Surface | Native implementation | Reference behavior |
| --- | --- | --- |
| Application window | `BomuApp`, `MainWindowView` | System title bar and traffic lights; a single persistent player and library model |
| Navigation | `MediaLibrarySidebar` | Home, Library, Folders, Favorites, Search, locations, and Settings; selection remains visible without an enclosing panel |
| Home | `MediaLibraryView` and `MediaLibraryCard` | Two-column Continue Watching and three-column Recently Added sections; separate media artwork and details, with View All and source labels |
| Library and Search | `MediaLibraryView` | Real indexed files, category and watched filters, and explicit empty/loading/error states |
| Folder browser | `MediaLibraryFolderViews` | Real source roots and subdirectories, breadcrumbs, grid/list density, and preserved navigation state |
| Playback | `PlayerScreen`, `PlaybackControls`, `VideoHostView` | One persistent video host with playback controls layered over the picture; media and control state come from the playback model |
| Settings | `SettingsView` | Playback, subtitles, local data, privacy, and update information in the native Settings scene |

## Visual tokens

`AppTheme` is the single native source for shared visual values. Values below are points unless noted.

| Role | Current value |
| --- | --- |
| Text / secondary text | `#141D2D` / `#647084` |
| Surface / sidebar | `#FFFFFF` / `#F0F4F8` |
| Separator / warm accent | `#E5EAF0` / `#EFB98F` |
| Brand / page / section title | system serif 32 / system sans 27 / system sans 17 |
| Media title / metadata / subtitle | system sans 14 / 12 / 13 |
| Sidebar / content inset | 176 / 30 |
| Grid gap / section gap / player horizontal inset | 17 / 28 / 22 |
| Artwork / player / control / field radius | 4 / 4 / 4 / 4 |
| Selection / compact surface / badge radius | 2 / 3 / 2 |
| Empty-state icon backing radius | 10 |

System sans is used for interface text and media details; system serif is reserved for brand display; time values use monospaced digits. No external fonts are bundled.

Use radii only where the component needs a visible shape. Keep folder rows and empty states free of outer cards; the empty-state icon may have its own small backing. The play button remains circular. AppKit owns the native window corners.

## Interaction and accessibility

- A single click selects a media item; a double-click plays it. The explicit play action and context menu keep playback available to keyboard and pointer users, alongside favorite, watched, and manual-category actions.
- The playback page remains alive while browsing. Returning to the library does not stop playback; the current-playback bar reflects the same player state.
- Open, pause, seek, playback speed, audio/subtitle tracks, queue, volume, and fullscreen controls use native semantic controls with localized accessibility names.
- Playback controls remain visible while paused, while VoiceOver is active, or while a control is being used. Reduced transparency uses a more opaque control surface.
- Media duration, codec, resolution, tracks, and thumbnails must come from the selected local file. Do not substitute fabricated metadata or sample artwork.

## Remaining acceptance

- Compare the current Debug build with the approved reference in one ordinary Bomu window on Screen 1; keep desktop interaction within that window.
- Complete the 960×640, 1280×800, and 1440×900 layout checks, including keyboard focus order and VoiceOver navigation.
- Confirm the visual hierarchy, typography, spacing, colors, and control proportions with the user. The listed token values document implementation; they do not prove visual acceptance.
- Test real media artwork and metadata. Synthetic fixtures are for playback and behavior checks only.

Record new evidence in [`progress.md`](../engineering/roadmap/progress.md) and update this specification only when the accepted design or implementation changes. Keep the product plan as the source for requirements and task dependencies.
