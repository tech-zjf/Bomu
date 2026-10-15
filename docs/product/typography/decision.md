# Typography direction

## Decision

Bomu uses the platform sans-serif for the working interface. The system serif is reserved for the brand wordmark; page and section titles, navigation, controls, filenames, and technical details stay sans-serif. Time values use monospaced digits. No external font files are bundled.

| Role | Typeface | Use |
| --- | --- | --- |
| Brand wordmark | System serif | Bomu identity in the start view |
| Page and section titles | System sans-serif | Library and folder hierarchy |
| Navigation and controls | System sans-serif | Sidebar, buttons, menus, search, and playback controls |
| Media names and technical details | System sans-serif | Dynamic filenames, codecs, dimensions, durations, and file sizes |
| Time values | System sans-serif with monospaced digits | Stable playback and duration readouts |

The typeface split follows the product tokens in [`设计规范.json`](../../../player_plan/开发定稿/设计规范.json). Localized text relies on platform glyph fallback, so enabling Chinese later still requires visual review of line wrapping and fallback glyphs.

## Implementation

`AppTheme.Typography` owns the text styles used by product views. Semantic roles preserve the selected sizes and weights while keeping repeated typography in one place. SF Symbol sizing may remain local to a control because it defines icon geometry rather than a text role.

The currently bundled app localization remains English. Chinese strings are retained for later activation. Shared typography tokens and a successful build do not establish visual acceptance; the current Debug build still needs comparison in one ordinary Bomu window at the specified sizes, followed by keyboard and VoiceOver checks.
