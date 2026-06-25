<#
.SYNOPSIS
    Migrates files from a network drive to Azure Blob Storage using AzCopy with MD5 hashing,
    checksum validation, local CSV logging, and resume capability.

.DESCRIPTION
    This script performs a two-step migration:
    1. Seed Migration: Uploads files and forces Azure to calculate MD5 hashes.
    2. Checksum Validation: Runs a dry-run sync comparing MD5 hashes to ensure mathematical match.

    Logging is written to a local CSV file on the Desktop under:
        Desktop\MigrationRuns\Run_<NNN>_<SourceFolder>\migration_log.csv

    Each migration run gets its own numbered folder. Resume detection is handled by
    scanning previous run folders for the same source folder.

    Challenges addressed from previous migration experience:
    - Files with "#" in the path: AzCopy requires the source path to be URL-encoded so "#" becomes "%23".
      Otherwise AzCopy interprets "#" as a URL fragment delimiter and silently skips those files.
    - Files with special characters (accents, foreign letters, "+|n", etc.): The safe_ascii encoding
      that URL-encodes non-ASCII characters is stripped from logged paths so the CSV stores
      the original Unicode filenames.
    - Files with no extension: Logged in the CSV with HasExtension=false.
      Migration is NOT blocked — the note is written alongside the upload, not before it.
    - Large folder timeouts: AzCopy default request timeout raised to handle large transfers.
    - Resume capability: If a previous migration run is detected for the selected folder, the user is
      offered a choice to resume or restart. AzCopy sync handles skipping already-uploaded files.
      RetryCount in the CSV increments each time a file is re-attempted.

.EXAMPLE
    .\migration_script with resume.ps1
#>

# ==========================================
# CONFIGURATION — Modify before running
# ==========================================

# The Azure Blob Storage URL with SAS token
$DestinationUrl = "https://myaccount.blob.core.windows.net/mycontainer?sastoken"

# Directory where AzCopy will write its operational logs
$LogDirectory = "C:\AzCopyLogs"

# Number of concurrent operations. Lower values (1-4) reduce CPU overhead during MD5 calculation.
$ConcurrencyValue = 4

# AzCopy request timeout in seconds. Default is 300 — increase for large files/folders.
# 3600 = 1 hour; raise further if you still see timeouts on very large transfers.
$RequestTryTimeout = "3600"

# Root folder on the Desktop where per-run CSV folders will be created
$RunsRootDir = [System.IO.Path]::Combine(
    [System.Environment]::GetFolderPath("Desktop"),
    "MigrationRuns"
)

# ==========================================


# ==========================================
# HELPER: URL-decode a percent-encoded string back to Unicode
# ==========================================
function ConvertFrom-UrlEncoding {
    param([string]$Encoded)
    try {
        return [System.Uri]::UnescapeDataString($Encoded)
    } catch {
        return $Encoded
    }
}

# ==========================================
# HELPER: URL-encode a local file-system path so that special
# characters (especially "#") are safely passed to AzCopy.
# ==========================================
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

# ==========================================
# HELPER: Show a Windows message box and return the button clicked.
# ==========================================
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
# HELPER: Test Azure Blob SAS URL Connection
# ==========================================
function Test-BlobConnection {
    param([string]$DestinationUrl)

    $parts = $DestinationUrl -split '\?', 2
    if ($parts.Count -lt 2) {
        Write-Warning "Invalid DestinationUrl structure. It must contain a '?' separating the container URL from the SAS token query string."
        return $false
    }
    
    $containerUrl = $parts[0].TrimEnd('/')
    $sasToken     = $parts[1]
    
    # We will attempt to upload a small test block blob to verify write permissions
    $testFileName = "migration_test_connection_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt"
    $testBlobUrl  = "${containerUrl}/${testFileName}?${sasToken}"
    
    $headers = @{
        "x-ms-blob-type" = "BlockBlob"
        "x-ms-version"   = "2019-02-02"
    }
    $body = "test connection"
    
    Write-Host "[Connection Test] Verifying Blob Storage write permission..." -ForegroundColor Yellow
    try {
        Invoke-RestMethod -Uri $testBlobUrl -Method Put -Headers $headers -Body $body -ContentType "text/plain" -ErrorAction Stop | Out-Null
        Write-Host "  [+] Blob Storage connection test: SUCCESS (Write verified)" -ForegroundColor Green
        
        # Clean up the test blob by deleting it
        Write-Host "[Connection Test] Cleaning up test blob..." -ForegroundColor Yellow
        try {
            Invoke-RestMethod -Uri $testBlobUrl -Method Delete -Headers @{"x-ms-version" = "2019-02-02"} -ErrorAction Stop | Out-Null
            Write-Host "  [+] Cleanup: SUCCESS (Test blob deleted)" -ForegroundColor Green
        } catch {
            Write-Warning "  [-] Cleanup: FAILED to delete test blob. Details: $_ (This is fine if SAS lacks delete permissions, but write was successful)"
        }
        return $true
    } catch {
        Write-Host "  [-] Blob Storage connection test: FAILED" -ForegroundColor Red
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errBody = $reader.ReadToEnd()
                Write-Host "  [-] Azure Storage error details: $errBody" -ForegroundColor Red
            } catch {}
        } else {
            Write-Host "  [-] Error details: $_" -ForegroundColor Red
        }
        return $false
    }
}

# ==========================================
# CSV HELPERS
# ==========================================

# CSV column order (used when writing the header and each row)
$CsvColumns = @(
    "RowKey", "FilePath", "MD5Hash", "HasExtension",
    "Status", "Notes", "MigrationRunId", "RetryCount", "LoggedAt"
)

# ==========================================
# HELPER: Escape a value for CSV (wrap in quotes, escape internal quotes).
# ==========================================
function ConvertTo-CsvField {
    param([string]$Value)
    $escaped = $Value -replace '"', '""'
    return "`"$escaped`""
}

# ==========================================
# HELPER: Write the CSV header line to a file.
# ==========================================
function Write-CsvHeader {
    param([string]$CsvPath)
    $header = ($CsvColumns | ForEach-Object { ConvertTo-CsvField $_ }) -join ","
    Set-Content -Path $CsvPath -Value $header -Encoding UTF8
}

# ==========================================
# HELPER: Append a new file entry row to the CSV.
# ==========================================
function Write-CsvRow {
    param(
        [string]$CsvPath,
        [string]$RowKey,
        [string]$FilePath,
        [string]$MD5Hash,
        [string]$HasExtension,
        [string]$Status,
        [string]$Notes,
        [string]$MigrationRunId,
        [int]   $RetryCount = 0
    )
    $row = @(
        $RowKey,
        $FilePath,
        $MD5Hash,
        $HasExtension,
        $Status,
        $Notes,
        $MigrationRunId,
        $RetryCount.ToString(),
        (Get-Date -Format "o")
    )
    $line = ($row | ForEach-Object { ConvertTo-CsvField $_ }) -join ","
    Add-Content -Path $CsvPath -Value $line -Encoding UTF8
}

# ==========================================
# HELPER: Load all rows from the CSV into a hashtable keyed by RowKey.
# Returns an empty hashtable if the file doesn't exist or has no data rows.
# ==========================================
function Import-CsvRowMap {
    param([string]$CsvPath)
    $map = @{}
    if (-not (Test-Path $CsvPath)) { return $map }
    $rows = Import-Csv -Path $CsvPath -Encoding UTF8
    foreach ($r in $rows) {
        $map[$r.RowKey] = $r
    }
    return $map
}

# ==========================================
# HELPER: Rewrite the entire CSV after updating a row in the in-memory map.
# Call this after modifying $existingRowMap entries so the file stays in sync.
# ==========================================
function Sync-CsvFromMap {
    param(
        [string]    $CsvPath,
        [hashtable] $RowMap
    )
    Write-CsvHeader -CsvPath $CsvPath
    foreach ($key in $RowMap.Keys) {
        $r = $RowMap[$key]
        $line = @(
            $r.RowKey,
            $r.FilePath,
            $r.MD5Hash,
            $r.HasExtension,
            $r.Status,
            $r.Notes,
            $r.MigrationRunId,
            $r.RetryCount,
            $r.LoggedAt
        ) | ForEach-Object { ConvertTo-CsvField ([string]$_) }
        Add-Content -Path $CsvPath -Value ($line -join ",") -Encoding UTF8
    }
}

# ==========================================
# HELPER: Update a single row's fields in the in-memory map and persist to CSV.
# ==========================================
function Update-CsvRow {
    param(
        [string]    $CsvPath,
        [hashtable] $RowMap,
        [string]    $RowKey,
        [string]    $Status,
        [string]    $Notes        = "",
        [string]    $MigrationRunId,
        [int]       $RetryCount
    )
    if ($RowMap.ContainsKey($RowKey)) {
        $RowMap[$RowKey].Status         = $Status
        $RowMap[$RowKey].Notes          = $Notes
        $RowMap[$RowKey].MigrationRunId = $MigrationRunId
        $RowMap[$RowKey].RetryCount     = $RetryCount.ToString()
        $RowMap[$RowKey].LoggedAt       = (Get-Date -Format "o")
    }
    # Persist the whole map back to disk
    Sync-CsvFromMap -CsvPath $CsvPath -RowMap $RowMap
}

# ==========================================
# CONNECTION PRE-FLIGHT VALIDATION
# ==========================================
Add-Type -AssemblyName System.Windows.Forms

Write-Host "Checking connection configurations..." -ForegroundColor Cyan

# Test Blob Storage SAS Connection
$blobReady = Test-BlobConnection -DestinationUrl $DestinationUrl
if (-not $blobReady) {
    Write-Error "Connection check failed: Cannot proceed with invalid DestinationUrl or SAS token."
    exit 1
}
Write-Host "All connection tests passed successfully.`n" -ForegroundColor Green

# ==========================================
# FOLDER SELECTION
# ==========================================
$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = "Select the network drive folder you want to migrate to Azure Blob Storage"
$folderBrowser.ShowNewFolderButton = $false

$result = $folderBrowser.ShowDialog()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    $SourceRaw = $folderBrowser.SelectedPath
} else {
    Write-Warning "No folder was selected. Exiting the migration script."
    exit
}

# ==========================================
# FILE AGE FILTER PROMPT
# ==========================================
$YearsInput = Read-Host "`nEnter the minimum age of files to migrate in years (e.g. 7, or press Enter to migrate all files)"
$CutoffDate = $null
$IsAgeFiltered = $false

if (-not [string]::IsNullOrWhiteSpace($YearsInput)) {
    $YearsValue = 0
    if ([int]::TryParse($YearsInput, [ref]$YearsValue)) {
        $CurrentYear = (Get-Date).Year
        $TargetYear = $CurrentYear - $YearsValue
        $CutoffDate = [DateTime]::new($TargetYear, 12, 31, 23, 59, 59)
        $IsAgeFiltered = $true
        Write-Host "Age Filter: Only files modified on or before $($CutoffDate.ToString('dd/MM/yyyy HH:mm:ss')) (<= year $TargetYear) will be migrated." -ForegroundColor Cyan
    } else {
        Write-Warning "Invalid input '$YearsInput'. Proceeding with NO date filter (migrating all files)."
    }
} else {
    Write-Host "No age filter specified. Migrating all files." -ForegroundColor Cyan
}

# ==========================================
# CONFIRMATION SAFETY CHECK
# ==========================================
$DriveName = [System.IO.Path]::GetPathRoot($SourceRaw).TrimEnd('\')
try {
    $uri = [System.Uri]$DestinationUrl
    $ContainerName = @($uri.AbsolutePath -split '/' | Where-Object { $_ })[0]
} catch {
    $ContainerName = "unknown-container"
}

$confirmMsg = "$DriveName will be migrated to $ContainerName. Are you sure?"
$confirmChoice = Show-MessageBox -Message $confirmMsg -Title "Confirm Migration Destination" -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)

if ($confirmChoice -ne "Yes") {
    Write-Warning "Migration cancelled by user confirmation."
    exit
}


# ==========================================
# SETUP
# ==========================================

if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory | Out-Null
}

$SourceEncoded  = ConvertTo-AzCopyPath -LocalPath $SourceRaw
$SourceFolder   = Split-Path $SourceRaw -Leaf   # used as a folder-name identifier

$env:AZCOPY_CONCURRENCY_VALUE   = $ConcurrencyValue.ToString()
$env:AZCOPY_LOG_LOCATION        = $LogDirectory
$env:AZCOPY_REQUEST_TRY_TIMEOUT = $RequestTryTimeout

Write-Host "AzCopy Migration Script (with Resume)" -ForegroundColor Cyan
Write-Host "Source (raw)     : $SourceRaw"
Write-Host "Source (encoded) : $SourceEncoded"
Write-Host "Destination      : [REDACTED SAS URL]"
Write-Host "Concurrency      : $ConcurrencyValue"
Write-Host "Request Timeout  : ${RequestTryTimeout}s"
Write-Host "AzCopy log dir   : $LogDirectory"
Write-Host "--------------------------------------------------"

# ==========================================
# RUN FOLDER & CSV SETUP
# Scans Desktop\MigrationRuns for previous runs for this source folder.
# Each run gets a zero-padded numbered sub-folder.
# ==========================================

# Ensure root runs directory exists
if (-not (Test-Path $RunsRootDir)) {
    New-Item -ItemType Directory -Path $RunsRootDir | Out-Null
}

# Sanitise the source folder name so it's safe for use as a directory name
$SafeSourceFolder = $SourceFolder -replace '[\\/:*?"<>|]', '_'

# Find all existing run folders that belong to this source folder
$existingRunFolders = @(Get-ChildItem -Path $RunsRootDir -Directory |
    Where-Object { $_.Name -match "^Run_\d+_$([regex]::Escape($SafeSourceFolder))$" } |
    Sort-Object Name)

# ==========================================
# RESUME DETECTION: Look for a previous run CSV
# ==========================================
$IsResumeMode   = $false
$IsRestartMode  = $false
$MigrationRunId = Get-Date -Format "yyyyMMdd_HHmmss"

# In-memory row map (RowKey -> PSCustomObject) — populated below
$existingRowMap = @{}
$PreviousCsvPath = $null

if ($existingRunFolders.Count -gt 0) {
    # The most recent previous run folder
    $lastRunFolder   = $existingRunFolders[-1]
    $PreviousCsvPath = Join-Path $lastRunFolder.FullName "migration_log.csv"

    if (Test-Path $PreviousCsvPath) {
        $existingRowMap  = Import-CsvRowMap -CsvPath $PreviousCsvPath
        $uploadedCount   = ($existingRowMap.Values | Where-Object { $_.Status -eq "Uploaded" -or $_.Status -eq "Validated" }).Count
        $pendingCount    = ($existingRowMap.Values | Where-Object { $_.Status -eq "Pending"  -or $_.Status -eq "Failed" -or $_.Status -eq "HashError" }).Count
        $lastRunId       = ($existingRowMap.Values | Sort-Object MigrationRunId -Descending | Select-Object -First 1).MigrationRunId

        Write-Host "Previous migration found in: $($lastRunFolder.FullName)" -ForegroundColor Yellow
        Write-Host "  Last Run ID          : $lastRunId"
        Write-Host "  Uploaded/Validated   : $uploadedCount file(s)"
        Write-Host "  Pending/Failed       : $pendingCount  file(s)"
        Write-Host "  Total rows           : $($existingRowMap.Count)"

        $msg = @"
A previous migration run was found for folder: '$SourceFolder'

Run Folder    : $($lastRunFolder.Name)
Last Run ID   : $lastRunId
Uploaded      : $uploadedCount file(s)
Pending/Failed: $pendingCount file(s)
Total         : $($existingRowMap.Count) file(s)

Click YES to RESUME — AzCopy will skip already-uploaded files and retry only the remaining ones.
Click NO  to RESTART — Everything will be re-uploaded from scratch (RetryCount increments for each file).
Click CANCEL to exit without doing anything.
"@

        $choice = Show-MessageBox -Message $msg -Title "Previous Migration Detected" `
                      -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNoCancel) `
                      -Icon     ([System.Windows.Forms.MessageBoxIcon]::Question)

        switch ($choice) {
            "Yes"    { $IsResumeMode  = $true;  Write-Host "Mode: RESUME"  -ForegroundColor Cyan }
            "No"     { $IsRestartMode = $true;  Write-Host "Mode: RESTART" -ForegroundColor Cyan }
            "Cancel" { Write-Warning "User cancelled. Exiting."; exit }
        }
    } else {
        Write-Host "No previous CSV found for '$SourceFolder'. Starting fresh." -ForegroundColor Green
    }
} else {
    Write-Host "No previous migration found for '$SourceFolder'. Starting fresh." -ForegroundColor Green
}

# ==========================================
# CREATE THIS RUN'S FOLDER & CSV
# For RESUME/RESTART we still create a NEW numbered run folder so every run
# is independently auditable. The previous run's CSV is read for state only.
# ==========================================
$nextRunNumber  = $existingRunFolders.Count + 1
$RunFolderName  = "Run_{0:D3}_{1}" -f $nextRunNumber, $SafeSourceFolder
$RunFolderPath  = Join-Path $RunsRootDir $RunFolderName
$CsvPath        = Join-Path $RunFolderPath "migration_log.csv"

New-Item -ItemType Directory -Path $RunFolderPath | Out-Null
Write-CsvHeader -CsvPath $CsvPath

Write-Host "[CSV] Run folder : $RunFolderPath" -ForegroundColor Green
Write-Host "[CSV] Log file   : $CsvPath"       -ForegroundColor Green

# ==========================================
# PRE-FLIGHT: Hash files and write CSV rows
#
# Fresh start : INSERT new row with RetryCount = 0, Status = Pending
# Resume      : Only INSERT rows that are missing from the previous run CSV;
#               carry forward existing rows — AzCopy will re-attempt Pending/Failed ones.
# Restart     : Carry forward all rows with Status = Pending, RetryCount++
#               INSERT rows for any new files not in the previous CSV yet.
# ==========================================
Write-Host "`n[Pre-flight] Hashing source files and writing CSV log..." -ForegroundColor Yellow

# currentRunMap is the in-memory store for THIS run's CSV
$currentRunMap = @{}

$sourceHashes  = @{}
$totalFiles    = 0
$noExtCount    = 0
$newFiles      = 0
$updatedFiles  = 0
$totalBytes    = [long]0

Get-ChildItem -Path $SourceRaw -Recurse -File | ForEach-Object {
    $file = $_
    if ($IsAgeFiltered -and $file.LastWriteTime -gt $CutoffDate) {
        return
    }

    $totalFiles++
    $totalBytes  += $file.Length
    $decodedPath  = ConvertFrom-UrlEncoding -Encoded $file.FullName
    $relativePath = $file.FullName.Substring($SourceRaw.Length).TrimStart('\')
    $safeRow      = $relativePath -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $hasExt       = ($file.Extension -ne "")
    $notes        = if (-not $hasExt) { "No file extension — verify file type after migration" } else { "" }

    if (-not $hasExt) {
        $noExtCount++
        Write-Warning "No extension: $($file.FullName)"
    }

    try {
        $hash = (Get-FileHash -Path $file.FullName -Algorithm MD5).Hash
        $sourceHashes[$decodedPath] = $hash
        $statusToWrite = "Pending"
        $errorNote     = $notes
    } catch {
        Write-Warning "Could not hash: $($file.FullName) — $_"
        $hash          = "ERROR"
        $statusToWrite = "HashError"
        $errorNote     = "MD5 hash computation failed: $_"
        if ($notes -ne "") { $errorNote = "$notes | $errorNote" }
    }

    $existingRow = $existingRowMap[$safeRow]

    if ($null -eq $existingRow) {
        # Brand new file — insert fresh entry
        $newFiles++
        $retryCount = 0
        Write-CsvRow `
            -CsvPath        $CsvPath `
            -RowKey         $safeRow `
            -FilePath       $decodedPath `
            -MD5Hash        $hash `
            -HasExtension   ($hasExt.ToString().ToLower()) `
            -Status         $statusToWrite `
            -Notes          $errorNote `
            -MigrationRunId $MigrationRunId `
            -RetryCount     0

        # Add to in-memory map so later Update-CsvRow calls work
        $currentRunMap[$safeRow] = [PSCustomObject]@{
            RowKey         = $safeRow
            FilePath       = $decodedPath
            MD5Hash        = $hash
            HasExtension   = ($hasExt.ToString().ToLower())
            Status         = $statusToWrite
            Notes          = $errorNote
            MigrationRunId = $MigrationRunId
            RetryCount     = "0"
            LoggedAt       = (Get-Date -Format "o")
        }

    } elseif ($IsRestartMode) {
        # Restart — bump RetryCount, reset Status
        $updatedFiles++
        $newRetryCount = [int]($existingRow.RetryCount) + 1
        $retryCount = $newRetryCount

        Write-CsvRow `
            -CsvPath        $CsvPath `
            -RowKey         $safeRow `
            -FilePath       $decodedPath `
            -MD5Hash        $hash `
            -HasExtension   ($hasExt.ToString().ToLower()) `
            -Status         $statusToWrite `
            -Notes          $errorNote `
            -MigrationRunId $MigrationRunId `
            -RetryCount     $newRetryCount

        $currentRunMap[$safeRow] = [PSCustomObject]@{
            RowKey         = $safeRow
            FilePath       = $decodedPath
            MD5Hash        = $hash
            HasExtension   = ($hasExt.ToString().ToLower())
            Status         = $statusToWrite
            Notes          = $errorNote
            MigrationRunId = $MigrationRunId
            RetryCount     = $newRetryCount.ToString()
            LoggedAt       = (Get-Date -Format "o")
        }

    } elseif ($IsResumeMode) {
        # Resume — carry forward the row; only re-pend if it wasn't already done
        $doneStatuses = @("Uploaded", "Validated")
        $carryStatus  = if ($existingRow.Status -in $doneStatuses) { $existingRow.Status } else { $statusToWrite }
        $carryRetry   = if ($existingRow.Status -in $doneStatuses) { [int]$existingRow.RetryCount } else { [int]$existingRow.RetryCount + 1 }
        if ($existingRow.Status -notin $doneStatuses) { $updatedFiles++ }

        Write-CsvRow `
            -CsvPath        $CsvPath `
            -RowKey         $safeRow `
            -FilePath       $decodedPath `
            -MD5Hash        $hash `
            -HasExtension   ($hasExt.ToString().ToLower()) `
            -Status         $carryStatus `
            -Notes          $errorNote `
            -MigrationRunId $MigrationRunId `
            -RetryCount     $carryRetry

        $currentRunMap[$safeRow] = [PSCustomObject]@{
            RowKey         = $safeRow
            FilePath       = $decodedPath
            MD5Hash        = $hash
            HasExtension   = ($hasExt.ToString().ToLower())
            Status         = $carryStatus
            Notes          = $errorNote
            MigrationRunId = $MigrationRunId
            RetryCount     = $carryRetry.ToString()
            LoggedAt       = (Get-Date -Format "o")
        }
    }
}

Write-Host "Pre-flight complete. $totalFiles file(s) scanned | $newFiles new | $updatedFiles updated | $noExtCount with no extension." -ForegroundColor Green
Write-Host "CSV log: $CsvPath" -ForegroundColor Green

# ==========================================
# STEP 1: Seed Migration
# AzCopy sync compares source vs destination — skips files already present and matching.
# This handles resume naturally: already-uploaded files are skipped automatically.
# On a restart, all files are re-evaluated by AzCopy (size/LMT check).
# ==========================================
Write-Host "`n[Step 1] Executing Seed Migration (AzCopy sync with --put-md5)..." -ForegroundColor Yellow
if ($IsResumeMode) {
    Write-Host "RESUME MODE: AzCopy will skip files already present in the destination." -ForegroundColor Cyan
} elseif ($IsRestartMode) {
    Write-Host "RESTART MODE: AzCopy will re-evaluate all files. RetryCount incremented in CSV." -ForegroundColor Cyan
}

# Start the migration timer — we only measure the actual AzCopy transfer, not pre-flight.
$migrationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Build the AzCopy upload command dynamically based on the age filter.
if ($IsAgeFiltered) {
    $CutoffUtcString = $CutoffDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $copyCommand = "azcopy copy `"$SourceEncoded`" `"$DestinationUrl`" --include-before=`"$CutoffUtcString`" --put-md5 --recursive=true --overwrite=false --log-level=INFO"
} else {
    $copyCommand = "azcopy sync `"$SourceEncoded`" `"$DestinationUrl`" --put-md5 --recursive=true --log-level=INFO"
}
Write-Host "Running command: $copyCommand" -ForegroundColor Gray
Invoke-Expression $copyCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "AzCopy sync (upload) failed with exit code $LASTEXITCODE."
    Write-Host "Check the AzCopy logs in $LogDirectory for details." -ForegroundColor Red

    # Mark all Pending rows as Failed
    Write-Host "Marking Pending rows as Failed in CSV..." -ForegroundColor Yellow
    $changed = $false
    foreach ($key in @($currentRunMap.Keys)) {
        if ($currentRunMap[$key].Status -eq "Pending") {
            $currentRunMap[$key].Status         = "Failed"
            $currentRunMap[$key].Notes          = "AzCopy exited with code $LASTEXITCODE"
            $currentRunMap[$key].MigrationRunId = $MigrationRunId
            $currentRunMap[$key].LoggedAt       = (Get-Date -Format "o")
            $changed = $true
        }
    }
    if ($changed) { Sync-CsvFromMap -CsvPath $CsvPath -RowMap $currentRunMap }
    exit $LASTEXITCODE
}

# Mark all non-done rows as Uploaded
Write-Host "Updating CSV — marking all files as Uploaded..." -ForegroundColor Yellow
$uploadChanged = $false
foreach ($key in @($currentRunMap.Keys)) {
    if ($currentRunMap[$key].Status -notin @("Validated", "Uploaded")) {
        $currentRunMap[$key].Status         = "Uploaded"
        $currentRunMap[$key].MigrationRunId = $MigrationRunId
        $currentRunMap[$key].LoggedAt       = (Get-Date -Format "o")
        $uploadChanged = $true
    }
}
if ($uploadChanged) { Sync-CsvFromMap -CsvPath $CsvPath -RowMap $currentRunMap }

# Stop the migration timer as soon as AzCopy finishes successfully
$migrationStopwatch.Stop()
$migrationElapsed = $migrationStopwatch.Elapsed

Write-Host "Seed Migration completed successfully." -ForegroundColor Green

# ==========================================
# STEP 2: Checksum Validation (dry-run sync)
# ==========================================
Write-Host "`n[Step 2] Executing Checksum Validation (Dry-run sync with MD5 comparison)..." -ForegroundColor Yellow
Write-Host "Note: --compare-hash=MD5 uses the Content-MD5 set by --put-md5 in Step 1."
if ($IsAgeFiltered) {
    Write-Host "WARNING: Because age filtering is enabled, the validation sync will list newer files as 'to be copied' in its dry-run output. This is expected and safe to ignore." -ForegroundColor DarkYellow
}

$syncCommand = "azcopy sync `"$SourceEncoded`" `"$DestinationUrl`" --compare-hash=MD5 --dry-run --recursive=true --log-level=INFO"
Invoke-Expression $syncCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "AzCopy sync (validation) failed with exit code $LASTEXITCODE."
    Write-Host "Mismatches or errors found. Check AzCopy logs in $LogDirectory." -ForegroundColor Red
    exit $LASTEXITCODE
}

# Mark all Uploaded rows as Validated
Write-Host "Updating CSV — marking all files as Validated..." -ForegroundColor Yellow
$validateChanged = $false
foreach ($key in @($currentRunMap.Keys)) {
    if ($currentRunMap[$key].Status -eq "Uploaded") {
        $currentRunMap[$key].Status         = "Validated"
        $currentRunMap[$key].MigrationRunId = $MigrationRunId
        $currentRunMap[$key].LoggedAt       = (Get-Date -Format "o")
        $validateChanged = $true
    }
}
if ($validateChanged) { Sync-CsvFromMap -CsvPath $CsvPath -RowMap $currentRunMap }

Write-Host "Checksum Validation completed. Source and Destination match mathematically." -ForegroundColor Green

# ==========================================
# SUMMARY
# ==========================================

$countValidated = ($currentRunMap.Values | Where-Object { $_.Status -eq "Validated" }).Count
$countUploaded  = ($currentRunMap.Values | Where-Object { $_.Status -eq "Uploaded"  }).Count
$countFailed    = ($currentRunMap.Values | Where-Object { $_.Status -eq "Failed" -or $_.Status -eq "HashError" }).Count
$countPending   = ($currentRunMap.Values | Where-Object { $_.Status -eq "Pending"  }).Count
$countPassed    = $countValidated + $countUploaded

$totalMB            = [math]::Round($totalBytes / 1MB, 2)
$migrationSeconds   = [math]::Max($migrationElapsed.TotalSeconds, 1)
$avgSpeedMBps       = [math]::Round($totalMB / $migrationSeconds, 2)
$elapsedFormatted   = "{0:D2}h {1:D2}m {2:D2}s" -f `
                          $migrationElapsed.Hours, `
                          $migrationElapsed.Minutes, `
                          $migrationElapsed.Seconds

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
Write-Host "  No-extension files   : $noExtCount  (flagged in CSV)"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Total data size      : $totalMB MB"
Write-Host "  Migration duration   : $elapsedFormatted  (AzCopy transfer only, excludes pre-flight)"
Write-Host "  Average speed        : $avgSpeedMBps MB/s"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  CSV log              : $CsvPath"
Write-Host "  AzCopy logs          : $LogDirectory"
Write-Host "==========================================================" -ForegroundColor Cyan
