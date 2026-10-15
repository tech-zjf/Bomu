# Playback history storage

## Boundary and ownership

`PlaybackState` remains the authority for the active request and live playback snapshot. `PlaybackHistoryStore` is the authority for durable resume preferences and owns the SQLite connection and schema migrations. The SwiftUI feature submits playback events and user commands; it does not hold a database handle or depend on GRDB.

Durable identity is the mounted volume UUID and filesystem resource identifier, with a metadata revision and bounded SHA-256 content samples that invalidate a checkpoint when the resource is rewritten. The path relative to the volume is location metadata and updates after a rename; a volume name is a display label. The original media remains read-only and is never copied. See [media identity](../library/media-identity.md) for the model, transaction, and migration contract.

## Schema

| Table | Authoritative fields | Query path |
| --- | --- | --- |
| `media_sources` | Stable `volume_id` primary key, mutable display name, update time | Resolve current mounted source |
| `media_files` | Integer row ID, source UUID, device/inode resource ID, metadata revision, nullable content fingerprint, volume-relative path, size and modification time | Identity lookup on open/save; path index for later browsing |
| `playback_history` | `media_file_id` primary/foreign key, nonnegative `position`, optional audio/subtitle track IDs, `volume` from 0 to 100, `updated_at` | One checkpoint lookup and atomic upsert per resolved file |
| `playback_history_legacy` | Original v0.0 canonical path primary key and checkpoint values | Exact-path migration on first access after upgrade |

The source and file rows retain location metadata needed by library browsing, while a composite source/path index supports location queries. Position and volume have both Swift validation and SQLite checks. Resolving identity, updating metadata, migrating any exact-path legacy record, and writing a checkpoint each occur in a GRDB `DatabaseQueue.write` transaction. Renames preserve the row; a changed metadata revision or known content fingerprint clears its prior checkpoint atomically. Existing rows receive fingerprints lazily after the additive `mediaContentFingerprint` migration.

## Lifecycle

The application opens its database in `~/Library/Application Support/Bomu/playback.sqlite` before accepting media. Startup shows the storage error and refuses playback if the store cannot be created or migrated. Opening a file loads its record asynchronously; the player checks the request ID after the read so a slow result cannot replace a newer file. Saved volume is applied before opening, and saved track IDs and position are applied after the native loaded event.

While a file is active, the player writes the latest native snapshot every five seconds. It also captures the current snapshot when replacing a file, stopping, reaching natural end, or terminating. Termination awaits the final write before releasing the playback engine. SQLite work stays behind the store actor and never runs from SwiftUI view evaluation. Hostless behavior tests now wait for a periodic checkpoint before shutdown, then reopen the on-disk database through a fresh store instance to verify that the final position, tracks, and volume survived.

After changing resume startup to pass the validated position to libmpv's `loadfile` start option, Xcode 27 native runs on 2026-10-15 passed both `testSavedAudioTrackAndPositionRestoreInNewNativeSession` and the first-snapshot assertion in `testRealPlaybackPauseSeekReplaceAndRelease`. The tests used a single host window and confirmed audio-track plus position restoration across fresh engines. A fresh visible-app check is still required to close the previously observed frame/timecode mismatch.

If the final checkpoint fails, shutdown still proceeds and releases the native engine; the failure remains visible through the persistence error state. A hostless injected-store test verifies the failure is attempted once, surfaced, and does not block teardown. Database-driver failure presentation has not yet been exercised with a real on-disk I/O fault in the app host.

## Migration and dependency policy

Migrations have stable identifiers and are append-only after release. GRDB is resolved to 7.11.1 and its exact source revision is recorded in `Config/Dependencies.lock.json` and `Bomu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Build and test scripts use the repository-local SwiftPM checkout cache. `scripts/dependencies.py check` rejects a missing or mismatched package pin. The dependency's MIT notice is retained in `ThirdParty/GRDB-LICENSE.txt`.

The migration interruption regression starts from the original path-keyed schema, injects a conflicting table so `mediaFileIdentity` fails after its first table rename, then verifies the rename and checkpoint both rolled back. Removing the conflict lets the same database migrate successfully and restores its saved position and track IDs. This tests failed-migration rollback and retry against the locked GRDB version; it does not replace backups or a process-kill test across every published schema.

Backup recovery is exercised separately through the versioned library archive: one store exports a checkpoint and library preferences, then a newly created database indexes the same unchanged local media and imports that archive. Version 2 archives carry the sampled fingerprint and require it when matching; legacy version 1 archives remain readable using their earlier metadata-only rules. The test verifies identity matching, restored progress/tracks/volume/favorites/category/settings and unchanged source bytes. The archive contains metadata only and cannot restore media that is unavailable or whose identity no longer matches.

## Current limits

Track IDs are persisted and restored through the native adapter, and B05 now exposes selection from the current file's native track list. The app-host suite has run in one ordinary window: 10/10 native integration tests passed, including switching between two real libmpv audio tracks and restoring the selected track plus playback position in a new native session. Cross-process restart accuracy and database fault presentation still need dedicated native evidence. If a file's track layout changes, libmpv may reject a stale ID; playback remains active and the selected track is not considered confirmed until the native snapshot reports it. Filesystems without a stable volume UUID or resource metadata produce an explicit checkpoint error; playback continues. Legacy records can only be matched to a file that still exists at its exact old canonical path when first opened.
