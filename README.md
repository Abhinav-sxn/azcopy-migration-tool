# AzCopy Migration Tool

A PowerShell-based migration toolkit for moving files from a **network drive to Azure Blob Storage** using AzCopy, with full Azure Table Storage logging, MD5 checksum validation, and resume capability.

---

## Scripts

| Script | Purpose |
|---|---|
| `migration_script with resume.ps1` | ✅ **Production script** — use this for real migrations |
| `migration_script.ps1` | 📦 Iteration 1 — base script without resume (kept for reference) |
| `migration_script_dryrun.ps1` | 🧪 Dry-run simulator — tests the full flow without uploading anything |

---

## Features

- **Folder picker UI** — Windows dialog to select the source folder at runtime
- **Azure Table logging** — Creates a `MigrationLog` table automatically if it doesn't exist; one row per file
- **MD5 checksum validation** — Uses `--put-md5` on upload and `--compare-hash=MD5` on sync to mathematically verify every file
- **Resume capability** — Detects prior migration runs for the same folder and offers Resume / Restart / Cancel via popup
- **Retry tracking** — `RetryCount` column in Azure Table starts at 0 (first upload) and increments on each re-attempt
- **No-extension file flagging** — Files without extensions are flagged in the table (`HasExtension=false`) without blocking migration
- **Migration speed summary** — Reports total data size, actual AzCopy transfer duration, and average MB/s at the end
- **Large folder timeout fix** — AzCopy request timeout raised to 1 hour (configurable)

### Challenges solved from previous migration experience

| Problem | Fix |
|---|---|
| Files with `#` in path silently skipped by AzCopy | Path URL-encoded before passing to AzCopy (`#` → `%23`) |
| Files with accents/foreign letters not logged correctly | `safe_ascii` encoding stripped; Unicode paths stored decoded in table |
| MigrationLog hash mismatch (`versión` logged as `versin`) | Paths decoded via `Uri.UnescapeDataString` before hashing and logging |
| Files with no extension | Detected and flagged in Azure Table with `HasExtension=false`; migration not blocked |
| Large folder timeouts (300s default) | `AZCOPY_REQUEST_TRY_TIMEOUT` raised to 3600s |

---

## Azure Table Schema (`MigrationLog`)

| Column | Description |
|---|---|
| `PartitionKey` | Source folder name |
| `RowKey` | Relative file path from source root |
| `FilePath` | Full decoded Unicode path |
| `MD5Hash` | MD5 hash of the source file |
| `HasExtension` | `true` / `false` |
| `Status` | `Pending` → `Uploaded` → `Validated` (or `Failed` / `HashError`) |
| `RetryCount` | `0` = first-time upload; increments on each re-attempt |
| `Notes` | Any flags (e.g. no extension, hash error) |
| `MigrationRunId` | Timestamp-based ID grouping all rows for one run |
| `LoggedAt` | ISO 8601 timestamp when the row was written |

---

## Prerequisites

- [AzCopy v10+](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10) installed and on `PATH`
- PowerShell 5.1 or later
- Azure Storage Account with:
  - A Blob container and SAS token (for the migration destination)
  - A connection string with Table Storage access (for the `MigrationLog` table)

---

## Configuration

Open `migration_script with resume.ps1` and edit the `CONFIGURATION` block at the top:

```powershell
# The Azure Blob Storage URL with SAS token
$DestinationUrl = "https://youraccount.blob.core.windows.net/yourcontainer?sastoken"

# Azure Storage Account connection string (for Table Storage)
$StorageConnectionString = "DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net"

# Azure Table name
$TableName = "MigrationLog"

# AzCopy log directory
$LogDirectory = "C:\AzCopyLogs"

# Concurrent operations (lower = less CPU during MD5 calculation)
$ConcurrencyValue = 4

# Request timeout in seconds (default 300 raised to 3600)
$RequestTryTimeout = "3600"
```

---

## Running

```powershell
# Production migration
.\migration_script with resume.ps1

# Dry run (no uploads, no Azure connection needed)
.\migration_script_dryrun.ps1
```

When the script starts:
1. A **folder picker** dialog opens — select the network drive folder to migrate
2. If a previous migration run is detected for that folder, a **Resume / Restart / Cancel** popup appears
3. The script hashes all files, logs them to Azure Table, runs AzCopy, and prints a summary

---

## Migration Summary Output

```
==================== MIGRATION SUMMARY ====================
  Mode                 : FRESH START / RESUME / RESTART
  Migration Run ID     : 20260623_190310
  Source Folder        : \\server\SharedFolder
------------------------------------------------------------
  Files scanned        : 2590
  Files migrated       : 2464  (Uploaded + Validated)
  Files validated (MD5): 2464
  Files failed         : 0
  Files still pending  : 0
  No-extension files   : 126  (flagged in table)
------------------------------------------------------------
  Total data size      : 205.94 MB
  Migration duration   : 00h 12m 47s  (AzCopy transfer only)
  Average speed        : 6.29 MB/s
------------------------------------------------------------
  Azure Table          : MigrationLog  (Account: youraccount)
  AzCopy logs          : C:\AzCopyLogs
==========================================================
```

---

## License

MIT
