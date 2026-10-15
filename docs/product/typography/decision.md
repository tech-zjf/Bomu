# Typography direction

## Decision

Bomu uses a restrained two-face system. The default platform sans-serif stays responsible for the working interface. The platform serif is a display accent for the brand wordmark, page titles, and media-section headings.

| Role | Typeface | Use |
| --- | --- | --- |
| Brand and page titles | System serif | App identity and the first heading on a library page |
| Content-section titles | System serif | “Continue Watching”, “Recently Added”, and equivalent section labels |
| Navigation and controls | Default system sans-serif | Sidebar, buttons, menus, search, and playback controls |
| Media titles and technical details | Default system sans-serif | Dynamic file names, codecs, dimensions, durations, and file sizes |
| Time readouts | System sans-serif with monospaced digits | Stable alignment while playback time changes |

The serif face gives the media library a warmer, film-editorial character. Keeping it out of file names and controls preserves fast scanning and familiar macOS interaction. Both faces are system designs rather than bundled font files, avoiding an extra font dependency and allowing the platform to choose localized glyph fallbacks when Chinese is enabled.

## Implementation and verification

`AppTheme.Typography` is the single source for display roles. `StartView` uses the brand role; `MediaLibraryView` uses the page and section roles. Other views inherit the normal SwiftUI system face unless a distinct technical role such as monospaced digits is explicitly needed.

The English-only app bundle builds successfully with the locked Xcode 27.0 toolchain. The current Home window was visually reviewed on Screen 1: display headings are distinct from the sans-serif media labels and technical metadata, with no clipping at the tested window size. Chinese strings are retained for future localization, but fallback glyphs and line wrapping have not been visually reviewed yet.
