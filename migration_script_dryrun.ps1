<#
.SYNOPSIS
    DRY RUN of the migration script - no Azure Storage, no AzCopy required.

.DESCRIPTION
    Every external call (Azure Table REST API, AzCopy) is replaced with a simulated/mocked
    version that prints what it WOULD do without actually doing it.

    Real operations that DO run:
      - Windows folder picker
      - Recursive file scan (Get-ChildItem)
      - MD5 hashing of source files
      - Resume-detection popup (simulated in-memory table)
      - Stopwatch timing
      - Full summary output

    Mocked operations (printed as [DRY RUN] messages):
      - Ensure-AzureTable    → pretends table exists/is created
      - Get-AzureTableRows   → returns simulated previous-run rows if $SimulateResume = $true
      - Write-AzureTableRow  → prints what would be inserted
      - Update-AzureTableRow → prints what would be updated
      - azcopy sync (Step 1) → sleeps 3 seconds to simulate transfer
      - azcopy sync (Step 2) → sleeps 1 second to simulate validation

.NOTES
    Set $SimulateResume = $true to see the Resume/Restart popup as if a prior run existed.
    Set $SimulateResume = $false to see a clean first-run flow.
    Set $SimulateAzCopyFailure = $true to see the failure/Failed-row path.
#>

# ==========================================
# DRY RUN CONTROLS
# ==========================================
$SimulateResume        = $true    # $true  → shows Resume/Restart popup with fake prior rows
                                   # $false → fresh-start flow
$SimulateAzCopyFailure = $false   # $true  → AzCopy "fails" so you can see the error path
$SimulatedPriorUploads = 3        # How many files to pretend were already Uploaded in prior run
$SimulatedPriorFailed  = 1        # How many files to pretend Failed in prior run

# ==========================================
# CONFIGURATION (values don't matter for dry run)
# ==========================================
$DestinationUrl          = "https://DRYRUN.blob.core.windows.net/dryrun-container?FAKE_SAS"
$StorageConnectionString = "DefaultEndpointsProtocol=https;AccountName=dryrunaccount;AccountKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==;EndpointSuffix=core.windows.net"
$TableName               = "MigrationLog"
$LogDirectory            = "C:\AzCopyLogs"
$ConcurrencyValue        = 4
$RequestTryTimeout       = "3600"

# ==========================================
# MOCK AZURE TABLE - in-memory store for dry run
# ==========================================
$MockTable = [System.Collections.Generic.List[hashtable]]::new()

function Parse-ConnectionString {
    param([string]$ConnectionString)
    $result = @{}
    foreach ($part in $ConnectionString -split ';') {
        $idx = $part.IndexOf('=')
        if ($idx -gt 0) {
            $key   = $part.Substring(0, $idx).Trim()
            $value = $part.Substring($idx + 1).Trim()
            $result[$key] = $value
        }
    }
    return $result
}

function Ensure-AzureTable {
    param([string]$AccountName, [string]$AccountKey, [string]$TableName)
    Write-Host "  [DRY RUN] Ensure-AzureTable: Would POST to https://$AccountName.table.core.windows.net/Tables" -ForegroundColor DarkGray
    Write-Host "  [DRY RUN] Table '$TableName' - simulating: already exists (200/409 OK)" -ForegroundColor DarkGray
    return $true
}

function Get-AzureTableRows {
    param([string]$AccountName, [string]$AccountKey, [string]$TableName, [string]$PartitionKey)
    Write-Host "  [DRY RUN] Get-AzureTableRows: Would GET $TableName()?`$filter=PartitionKey eq '$PartitionKey'" -ForegroundColor DarkGray

    # Return the in-memory mock table rows for this PartitionKey
    $rows = $MockTable | Where-Object { $_.PartitionKey -eq $PartitionKey }
    Write-Host "  [DRY RUN] Returning $($rows.Count) simulated row(s) from in-memory mock table." -ForegroundColor DarkGray
    return $rows
}

function Write-AzureTableRow {
    param(
        [string]$AccountName, [string]$AccountKey, [string]$TableName,
        [string]$PartitionKey, [string]$RowKey,
        [string]$FilePath, [string]$MD5Hash, [string]$HasExtension,
        [string]$Status, [string]$Notes, [string]$MigrationRunId, [int]$RetryCount = 0
    )
    $safePartition = $PartitionKey -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $safeRow       = $RowKey       -replace "[\\/#?`u0000-`u001f`u007f]", '_'

    Write-Host "  [DRY RUN] INSERT row → PK='$safePartition' | RK='$safeRow' | Status=$Status | MD5=$MD5Hash | HasExt=$HasExtension | Retries=$RetryCount" -ForegroundColor DarkGray

    # Save to in-memory mock table so resume detection works within the dry run
    $MockTable.Add(@{
        PartitionKey   = $safePartition
        RowKey         = $safeRow
        FilePath       = $FilePath
        MD5Hash        = $MD5Hash
        HasExtension   = $HasExtension
        Status         = $Status
        Notes          = $Notes
        MigrationRunId = $MigrationRunId
        RetryCount     = $RetryCount
        LoggedAt       = (Get-Date -Format "o")
    })
}

function Update-AzureTableRow {
    param(
        [string]$AccountName, [string]$AccountKey, [string]$TableName,
        [string]$PartitionKey, [string]$RowKey,
        [string]$Status, [string]$Notes = "", [string]$MigrationRunId, [int]$RetryCount
    )
    $safePartition = $PartitionKey -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $safeRow       = $RowKey       -replace "[\\/#?`u0000-`u001f`u007f]", '_'

    Write-Host "  [DRY RUN] MERGE row  → PK='$safePartition' | RK='$safeRow' | Status=$Status | Retries=$RetryCount" -ForegroundColor DarkGray

    # Update the in-memory mock table
    $existing = $MockTable | Where-Object { $_.PartitionKey -eq $safePartition -and $_.RowKey -eq $safeRow }
    if ($existing) {
        $existing.Status         = $Status
        $existing.Notes          = $Notes
        $existing.MigrationRunId = $MigrationRunId
        $existing.RetryCount     = $RetryCount
        $existing.LastUpdated    = (Get-Date -Format "o")
    }
}

function ConvertFrom-UrlEncoding {
    param([string]$Encoded)
    try { return [System.Uri]::UnescapeDataString($Encoded) } catch { return $Encoded }
}

function ConvertTo-AzCopyPath {
    param([string]$LocalPath)
    $segments = $LocalPath -split '\\'
    $encodedSegments = $segments | ForEach-Object {
        $seg = $_ -replace '#', '%23'
        $seg = $seg -replace '\+', '%2B'
        return $seg
    }
    return ($encodedSegments -join '\')
}

function Show-MessageBox {
    param(
        [string]$Message,
        [string]$Title,
        [System.Windows.Forms.MessageBoxButtons]$Buttons,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

# ==========================================
# FOLDER SELECTION
# ==========================================
Add-Type -AssemblyName System.Windows.Forms

$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "DRY RUN - Select any local folder to simulate migration"
$folderBrowser.ShowNewFolderButton = $false

$result = $folderBrowser.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    $SourceRaw = $folderBrowser.SelectedPath
} else {
    Write-Warning "No folder selected. Exiting dry run."
    exit
}

# ==========================================
# SETUP
# ==========================================
$connParts   = Parse-ConnectionString -ConnectionString $StorageConnectionString
$AccountName = $connParts["AccountName"]
$AccountKey  = $connParts["AccountKey"]

$SourceEncoded  = ConvertTo-AzCopyPath -LocalPath $SourceRaw
$SourceFolder   = Split-Path $SourceRaw -Leaf
$MigrationRunId = Get-Date -Format "yyyyMMdd_HHmmss"

$env:AZCOPY_CONCURRENCY_VALUE   = $ConcurrencyValue.ToString()
$env:AZCOPY_LOG_LOCATION        = $LogDirectory
$env:AZCOPY_REQUEST_TRY_TIMEOUT = $RequestTryTimeout

Write-Host ""
Write-Host "========================================================" -ForegroundColor Magenta
Write-Host "  *** DRY RUN MODE - No data will be uploaded ***" -ForegroundColor Magenta
Write-Host "========================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "AzCopy Migration Script (with Resume) - DRY RUN" -ForegroundColor Cyan
Write-Host "Source (raw)     : $SourceRaw"
Write-Host "Source (encoded) : $SourceEncoded"
Write-Host "Destination      : [REDACTED - FAKE SAS URL]"
Write-Host "Concurrency      : $ConcurrencyValue"
Write-Host "Request Timeout  : ${RequestTryTimeout}s"
Write-Host "AzCopy log dir   : $LogDirectory  (not created in dry run)"
Write-Host "Azure Table      : $TableName  (Account: $AccountName)"
Write-Host "--------------------------------------------------"

# ==========================================
# AZURE TABLE: Ensure table exists (mocked)
# ==========================================
Write-Host "`n[Setup] Ensuring Azure Table '$TableName' exists..." -ForegroundColor Yellow
$tableReady = Ensure-AzureTable -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName
if (-not $tableReady) {
    Write-Error "Table check failed (dry run). Exiting."
    exit 1
}
Write-Host "Azure Table '$TableName' ready." -ForegroundColor Green

# ==========================================
# SIMULATE PRIOR RUN ROWS (if $SimulateResume = $true)
# Inject some fake rows into the mock table BEFORE resume detection runs,
# as if a previous run had already partially migrated this folder.
# ==========================================
if ($SimulateResume) {
    Write-Host "`n[DRY RUN] Pre-populating mock table with $($SimulatedPriorUploads + $SimulatedPriorFailed) simulated prior-run rows..." -ForegroundColor DarkGray

    $priorRunId = (Get-Date).AddHours(-2).ToString("yyyyMMdd_HHmmss")

    # Grab real files from the chosen folder to use as realistic RowKeys
    $realFiles = @(Get-ChildItem -Path $SourceRaw -Recurse -File | Select-Object -First ($SimulatedPriorUploads + $SimulatedPriorFailed))

    for ($i = 0; $i -lt $realFiles.Count; $i++) {
        $rp     = $realFiles[$i].FullName.Substring($SourceRaw.Length).TrimStart('\')
        $safeRK = $rp -replace "[\\/#?`u0000-`u001f`u007f]", '_'
        $safePK = $SourceFolder -replace "[\\/#?`u0000-`u001f`u007f]", '_'
        $st     = if ($i -lt $SimulatedPriorUploads) { "Uploaded" } else { "Failed" }

        $MockTable.Add(@{
            PartitionKey   = $safePK
            RowKey         = $safeRK
            FilePath       = $realFiles[$i].FullName
            MD5Hash        = "FAKEHASH$(Get-Random -Maximum 9999)"
            HasExtension   = ($realFiles[$i].Extension -ne "").ToString().ToLower()
            Status         = $st
            Notes          = if ($st -eq "Failed") { "Simulated failure from prior run" } else { "" }
            MigrationRunId = $priorRunId
            RetryCount     = 0
            LoggedAt       = (Get-Date).AddHours(-2).ToString("o")
        })
    }
    Write-Host "  [DRY RUN] Injected $SimulatedPriorUploads Uploaded + $SimulatedPriorFailed Failed rows (RunId: $priorRunId)" -ForegroundColor DarkGray
}

# ==========================================
# RESUME DETECTION
# ==========================================
Write-Host "`n[Resume Check] Querying Azure Table for previous migration of '$SourceFolder'..." -ForegroundColor Yellow
$existingRows = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                    -TableName $TableName -PartitionKey $SourceFolder

$IsResumeMode  = $false
$IsRestartMode = $false

if ($existingRows.Count -gt 0) {
    $uploadedCount = ($existingRows | Where-Object { $_.Status -eq "Uploaded" -or $_.Status -eq "Validated" }).Count
    $pendingCount  = ($existingRows | Where-Object { $_.Status -eq "Pending"  -or $_.Status -eq "Failed" -or $_.Status -eq "HashError" }).Count
    $lastRunId     = ($existingRows | Sort-Object MigrationRunId -Descending | Select-Object -First 1).MigrationRunId

    Write-Host "Previous migration found (last run: $lastRunId):" -ForegroundColor Yellow
    Write-Host "  Uploaded/Validated : $uploadedCount file(s)"
    Write-Host "  Pending/Failed     : $pendingCount  file(s)"
    Write-Host "  Total rows         : $($existingRows.Count)"

    $msg = @"
A previous migration run was found for folder: '$SourceFolder'

Last Run ID   : $lastRunId
Uploaded      : $uploadedCount file(s)
Pending/Failed: $pendingCount file(s)
Total         : $($existingRows.Count) file(s)

Click YES to RESUME - AzCopy will skip already-uploaded files and retry only the remaining ones.
Click NO  to RESTART - Everything will be re-uploaded from scratch (RetryCount increments for each file).
Click CANCEL to exit without doing anything.
"@

    $choice = Show-MessageBox -Message $msg -Title "[DRY RUN] Previous Migration Detected" `
                  -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNoCancel) `
                  -Icon    ([System.Windows.Forms.MessageBoxIcon]::Question)

    switch ($choice) {
        "Yes"    { $IsResumeMode  = $true;  Write-Host "Mode: RESUME"  -ForegroundColor Cyan }
        "No"     { $IsRestartMode = $true;  Write-Host "Mode: RESTART" -ForegroundColor Cyan }
        "Cancel" { Write-Warning "User cancelled. Exiting."; exit }
    }
} else {
    Write-Host "No previous migration found for '$SourceFolder'. Starting fresh." -ForegroundColor Green
}

$existingRowMap = @{}
foreach ($row in $existingRows) { $existingRowMap[$row.RowKey] = $row }

# ==========================================
# PRE-FLIGHT: Hash files + write/update mock table
# ==========================================
Write-Host "`n[Pre-flight] Hashing source files and syncing with Azure Table '$TableName'..." -ForegroundColor Yellow

$sourceHashes = @{}
$totalFiles   = 0
$noExtCount   = 0
$newFiles     = 0
$updatedFiles = 0
$totalBytes   = [long]0

Get-ChildItem -Path $SourceRaw -Recurse -File | ForEach-Object {
    $totalFiles++
    $file         = $_
    $totalBytes  += $file.Length
    $decodedPath  = ConvertFrom-UrlEncoding -Encoded $file.FullName
    $relativePath = $file.FullName.Substring($SourceRaw.Length).TrimStart('\')
    $safeRow      = $relativePath -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $hasExt       = ($file.Extension -ne "")
    $notes        = if (-not $hasExt) { "No file extension - verify file type after migration" } else { "" }

    if (-not $hasExt) {
        $noExtCount++
        Write-Warning "No extension: $($file.FullName)"
    }

    try {
        $hash          = (Get-FileHash -Path $file.FullName -Algorithm MD5).Hash
        $sourceHashes[$decodedPath] = $hash
        $statusToWrite = "Pending"
        $errorNote     = $notes
    } catch {
        Write-Warning "Could not hash: $($file.FullName) - $_"
        $hash          = "ERROR"
        $statusToWrite = "HashError"
        $errorNote     = "MD5 hash computation failed: $_"
        if ($notes -ne "") { $errorNote = "$notes | $errorNote" }
    }

    $existingRow = $existingRowMap[$safeRow]

    if ($null -eq $existingRow) {
        $newFiles++
        Write-AzureTableRow `
            -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName `
            -PartitionKey $SourceFolder -RowKey $relativePath `
            -FilePath $decodedPath -MD5Hash $hash -HasExtension ($hasExt.ToString().ToLower()) `
            -Status $statusToWrite -Notes $errorNote -MigrationRunId $MigrationRunId -RetryCount 0

    } elseif ($IsRestartMode) {
        $updatedFiles++
        $newRetryCount = [int]($existingRow.RetryCount) + 1
        Update-AzureTableRow `
            -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName `
            -PartitionKey $SourceFolder -RowKey $relativePath `
            -Status $statusToWrite -Notes $errorNote -MigrationRunId $MigrationRunId -RetryCount $newRetryCount

    } elseif ($IsResumeMode) {
        $doneStatuses = @("Uploaded", "Validated")
        if ($existingRow.Status -notin $doneStatuses) {
            $updatedFiles++
            $newRetryCount = [int]($existingRow.RetryCount) + 1
            Update-AzureTableRow `
                -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName `
                -PartitionKey $SourceFolder -RowKey $relativePath `
                -Status $statusToWrite -Notes $errorNote -MigrationRunId $MigrationRunId -RetryCount $newRetryCount
        }
    }
}

Write-Host "Pre-flight complete. $totalFiles file(s) scanned | $newFiles new | $updatedFiles updated | $noExtCount with no extension." -ForegroundColor Green

# ==========================================
# STEP 1: Seed Migration (MOCKED - simulated AzCopy)
# ==========================================
Write-Host "`n[Step 1] Executing Seed Migration (AzCopy sync with --put-md5)..." -ForegroundColor Yellow
if ($IsResumeMode)  { Write-Host "RESUME MODE: AzCopy will skip files already present in the destination." -ForegroundColor Cyan }
if ($IsRestartMode) { Write-Host "RESTART MODE: AzCopy will re-evaluate all files. RetryCount incremented in table." -ForegroundColor Cyan }

$dryRunCmd1 = 'azcopy sync "' + $SourceEncoded + '" "[FAKE_DEST_URL]" --put-md5 --recursive=true --log-level=INFO'
Write-Host "  [DRY RUN] Would run: $dryRunCmd1" -ForegroundColor DarkGray
Write-Host "  [DRY RUN] Simulating AzCopy transfer (sleeping 3 seconds)..." -ForegroundColor DarkGray

$migrationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 3   # simulates AzCopy running

if ($SimulateAzCopyFailure) {
    $migrationStopwatch.Stop()
    $migrationElapsed = $migrationStopwatch.Elapsed
    Write-Error "[DRY RUN] Simulated AzCopy FAILURE (exit code 1)."

    Write-Host "Marking Pending rows as Failed in Azure Table..." -ForegroundColor Yellow
    $allRowsNow = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                      -TableName $TableName -PartitionKey $SourceFolder
    foreach ($row in $allRowsNow) {
        if ($row.Status -eq "Pending") {
            Update-AzureTableRow `
                -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName `
                -PartitionKey $SourceFolder -RowKey $row.RowKey `
                -Status "Failed" -Notes "AzCopy exited with code 1 (simulated)" `
                -MigrationRunId $MigrationRunId -RetryCount ([int]$row.RetryCount)
        }
    }

    Write-Host "`n[DRY RUN] Simulated failure complete. In a real run the script would exit here." -ForegroundColor Red
    # Don't actually exit in dry run - fall through to summary
} else {
    $migrationStopwatch.Stop()
    $migrationElapsed = $migrationStopwatch.Elapsed

    # Mark all non-done rows as Uploaded
    Write-Host "  [DRY RUN] Simulating AzCopy success - marking rows as Uploaded..." -ForegroundColor DarkGray
    $allRowsNow = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                      -TableName $TableName -PartitionKey $SourceFolder
    foreach ($row in $allRowsNow) {
        if ($row.Status -notin @("Validated", "Uploaded")) {
            Update-AzureTableRow `
                -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName `
                -PartitionKey $SourceFolder -RowKey $row.RowKey `
                -Status "Uploaded" -Notes $row.Notes -MigrationRunId $MigrationRunId -RetryCount ([int]$row.RetryCount)
        }
    }
    Write-Host "Seed Migration completed successfully." -ForegroundColor Green
}

# ==========================================
# STEP 2: Checksum Validation (MOCKED)
# ==========================================
Write-Host "`n[Step 2] Executing Checksum Validation (Dry-run sync with MD5 comparison)..." -ForegroundColor Yellow
$dryRunCmd2 = 'azcopy sync "' + $SourceEncoded + '" "[FAKE_DEST_URL]" --compare-hash=MD5 --dry-run --recursive=true --log-level=INFO'
Write-Host "  [DRY RUN] Would run: $dryRunCmd2" -ForegroundColor DarkGray
Write-Host "  [DRY RUN] Simulating validation (sleeping 1 second)..." -ForegroundColor DarkGray
Start-Sleep -Seconds 1

if (-not $SimulateAzCopyFailure) {
    # Mark Uploaded rows as Validated
    Write-Host "  [DRY RUN] Simulating validation success - marking rows as Validated..." -ForegroundColor DarkGray
    $allRowsNow = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                      -TableName $TableName -PartitionKey $SourceFolder
    foreach ($row in $allRowsNow) {
        if ($row.Status -eq "Uploaded") {
            Update-AzureTableRow `
                -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName `
                -PartitionKey $SourceFolder -RowKey $row.RowKey `
                -Status "Validated" -Notes $row.Notes -MigrationRunId $MigrationRunId -RetryCount ([int]$row.RetryCount)
        }
    }
    Write-Host "Checksum Validation completed. Source and Destination match mathematically." -ForegroundColor Green
}

# ==========================================
# SUMMARY
# ==========================================
$finalRows      = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                      -TableName $TableName -PartitionKey $SourceFolder
$countValidated = ($finalRows | Where-Object { $_.Status -eq "Validated" }).Count
$countUploaded  = ($finalRows | Where-Object { $_.Status -eq "Uploaded"  }).Count
$countFailed    = ($finalRows | Where-Object { $_.Status -eq "Failed" -or $_.Status -eq "HashError" }).Count
$countPending   = ($finalRows | Where-Object { $_.Status -eq "Pending"  }).Count
$countPassed    = $countValidated + $countUploaded

$totalMB          = [math]::Round($totalBytes / 1MB, 2)
$migrationSeconds = [math]::Max($migrationElapsed.TotalSeconds, 1)
$avgSpeedMBps     = [math]::Round($totalMB / $migrationSeconds, 2)
$elapsedFormatted = "{0:D2}h {1:D2}m {2:D2}s" -f $migrationElapsed.Hours, $migrationElapsed.Minutes, $migrationElapsed.Seconds

Write-Host ""
Write-Host "==================== MIGRATION SUMMARY ====================" -ForegroundColor Cyan
Write-Host "  Mode                 : $(if ($IsResumeMode) { 'RESUME' } elseif ($IsRestartMode) { 'RESTART' } else { 'FRESH START' })"
Write-Host "  Migration Run ID     : $MigrationRunId"
Write-Host "  Source Folder        : $SourceRaw"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Files scanned        : $totalFiles"
Write-Host "  Files migrated       : $countPassed  (Uploaded + Validated)" -ForegroundColor Green
Write-Host "  Files validated (MD5): $countValidated" -ForegroundColor Green
Write-Host "  Files failed         : $countFailed"    -ForegroundColor $(if ($countFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Files still pending  : $countPending"   -ForegroundColor $(if ($countPending -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  No-extension files   : $noExtCount  (flagged in table)"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Total data size      : $totalMB MB"
Write-Host "  Migration duration   : $elapsedFormatted  (simulated AzCopy only, excludes pre-flight)"
Write-Host "  Average speed        : $avgSpeedMBps MB/s  [DRY RUN - based on 3s sleep]"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Azure Table          : $TableName  (Account: $AccountName)  [DRY RUN - in-memory only]"
Write-Host "  AzCopy logs          : $LogDirectory  [DRY RUN - not created]"
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [DRY RUN] In-memory table final state:" -ForegroundColor DarkGray
$MockTable | Sort-Object Status | ForEach-Object {
    $line = '    {0,-12} | Retries={1} | HasExt={2} | {3}' -f $_.Status, $_.RetryCount, $_.HasExtension, $_.RowKey
    Write-Host $line -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "========================================================" -ForegroundColor Magenta
Write-Host "  *** DRY RUN COMPLETE - Nothing was uploaded ***" -ForegroundColor Magenta
Write-Host "========================================================" -ForegroundColor Magenta
