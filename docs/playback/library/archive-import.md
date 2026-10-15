# Media library archive import

## Scope

The version 2 JSON archive transfers library metadata between Bomu installations. It contains source roots, local file identity including a bounded content fingerprint, membership, favorite/watched/category state, playback checkpoints, private-folder rules, and playback preferences. Its logical file ID includes the fingerprint, so replacing content at the same inode produces a distinct identity. It never contains media bytes. Version 1 archives remain readable for backups created before fingerprint support.

Import is additive for sources and memberships. Version 2 records require a 64-character lowercase hexadecimal SHA-256 sampled fingerprint plus matching metadata revision. The importer first checks volume UUID and filesystem resource identifier; if that identifier changed, it accepts a fallback only when volume UUID, relative path, byte count, metadata revision, and fingerprint all match. Version 1 records retain their historical metadata-only match rules. Ambiguous duplicate matches reject the archive. Files without a safe match are skipped and counted in the preview and result.

The settings screen previews match and replacement counts before the user confirms. The importer validates the complete archive before writing. Source roots, privacy rules, file preferences, checkpoints, and memberships are then applied in one SQLite transaction, so a failed write rolls back the whole import. Existing privacy rules on the destination also prevent checkpoint import for excluded files.

## Call path

`SettingsView` reads the selected JSON file under its security-scoped URL using `MediaLibraryArchive.read`, then asks `PlayerModel` for a preview. The archive reader enforces the 256 MiB limit while streaming from the file handle, so missing or stale filesystem size metadata cannot cause an unbounded allocation. Export uses the same limit and rejects an archive that would exceed the importer's supported size. `PlaybackHistoryStore` decodes and validates the schema, matches local media identities, and returns counts without changing the database. After confirmation, `PlayerModel` waits for pending checkpoint writes and calls `PlaybackHistoryStore.importArchive`. The store applies rows inside one GRDB write transaction. On success, `PlayerModel` applies archived playback settings and the library view reloads. A currently playing item immediately records its current position after import, preserving the live playback session as the current checkpoint.

## Failure and privacy behavior

- Archives over 256 MiB, unsupported schema versions, invalid settings/checkpoints, invalid identities, duplicate identities, and non-canonical relative paths are rejected before a transaction begins. Path validation covers source roots, file identities, membership roots, and privacy folders, so imported state cannot make the scanner or library resolve outside a mounted volume.
- An import failure inside the transaction leaves sources, preferences, checkpoints, and memberships unchanged.
- A file that cannot be matched is never recreated as a local media file and is never copied.
- A destination private-folder rule takes precedence over an archived checkpoint.
- Import never changes source media bytes.

## Verification

`PlaybackHistoryStoreTests` covers matched record replacement, unmatched-file skips, successful preference/history restore, rollback after an injected SQLite write failure, traversal rejection for all four persisted relative-path fields at both preview and import, bounded archive reads at and above the configured byte limit, and export rejection at the same size boundary. The suite uses temporary media files and never opens or modifies user media. The settings confirmation remains subject to the Screen 1, single-window visible UI walkthrough.
