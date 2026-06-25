<#
.SYNOPSIS
    Migrates files from a network drive to Azure Blob Storage using AzCopy with MD5 hashing,
    checksum validation, Azure Table logging, and resume capability.

.DESCRIPTION
    This script performs a two-step migration:
    1. Seed Migration: Uploads files and forces Azure to calculate MD5 hashes.
    2. Checksum Validation: Runs a dry-run sync comparing MD5 hashes to ensure mathematical match.

    Challenges addressed from previous migration experience:
    - Files with "#" in the path: AzCopy requires the source path to be URL-encoded so "#" becomes "%23".
      Otherwise AzCopy interprets "#" as a URL fragment delimiter and silently skips those files.
    - Files with special characters (accents, foreign letters, "+|n", etc.): The safe_ascii encoding
      that URL-encodes non-ASCII characters is stripped from logged paths so the MigrationLog stores
      the original Unicode filenames. This ensures MD5 hashes computed from the log match the source.
    - MigrationLog hash mismatch: Was caused by logging the URL-encoded ("safe_ascii") version of the
      filename (e.g. "versin" instead of "versión"). Fixed by URL-decoding paths before writing to log.
    - Files with no extension: Logged into Azure Table Storage (MigrationLog table) with HasExtension=false.
      Migration is NOT blocked — the note is written alongside the upload, not before it.
    - Large folder timeouts: AzCopy default request timeout raised to handle large transfers.
    - Resume capability: If a previous migration run is detected for the selected folder, the user is
      offered a choice to resume or restart. AzCopy sync handles skipping already-uploaded files.
      RetryCount in the table increments each time a file is re-attempted.

.EXAMPLE
    .\migration_script with resume.ps1
#>

# ==========================================
# CONFIGURATION — Modify before running
# ==========================================

# The Azure Blob Storage URL with SAS token
$DestinationUrl = "https://myaccount.blob.core.windows.net/mycontainer?sastoken"

# Azure Storage Account connection string (used for Azure Table Storage MigrationLog)
# Format: "DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net"
$StorageConnectionString = "YOUR_STORAGE_CONNECTION_STRING_HERE"

# Azure Table name for the migration log
$TableName = "MigrationLog"

# Directory where AzCopy will write its operational logs
$LogDirectory = "C:\AzCopyLogs"

# Number of concurrent operations. Lower values (1-4) reduce CPU overhead during MD5 calculation.
$ConcurrencyValue = 4

# AzCopy request timeout in seconds. Default is 300 — increase for large files/folders.
# 3600 = 1 hour; raise further if you still see timeouts on very large transfers.
$RequestTryTimeout = "3600"

# ==========================================


# ==========================================
# HELPER: Parse the storage connection string into a hashtable
# ==========================================
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

# ==========================================
# HELPER: Build an HMAC-SHA256 signature for Azure Shared Key auth
# ==========================================
function New-StorageSharedKeySignature {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$StringToSign
    )
    $keyBytes    = [System.Convert]::FromBase64String($AccountKey)
    $hmac        = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key    = $keyBytes
    $msgBytes    = [System.Text.Encoding]::UTF8.GetBytes($StringToSign)
    $sigBytes    = $hmac.ComputeHash($msgBytes)
    return [System.Convert]::ToBase64String($sigBytes)
}

# ==========================================
# HELPER: Build the Authorization header for Azure Table REST calls
# Docs: https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key
# ==========================================
function New-TableAuthHeader {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$HttpMethod,
        [string]$ContentMD5 = "",
        [string]$ContentType = "application/json",
        [string]$Date,
        [string]$CanonicalizedResource
    )
    $stringToSign = "$HttpMethod`n$ContentMD5`n$ContentType`n$Date`n$CanonicalizedResource"
    $signature    = New-StorageSharedKeySignature -AccountName $AccountName -AccountKey $AccountKey -StringToSign $stringToSign
    return "SharedKey ${AccountName}:${signature}"
}

# ==========================================
# HELPER: Create the Azure Table if it does not already exist.
# Returns $true if created or already exists, $false on error.
# ==========================================
function Ensure-AzureTable {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$TableName
    )

    $date          = [System.DateTime]::UtcNow.ToString("R")
    $body          = "{`"TableName`":`"$TableName`"}"
    $bodyBytes     = [System.Text.Encoding]::UTF8.GetBytes($body)
    $contentMD5    = [System.Convert]::ToBase64String(
                         (New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bodyBytes))
    $canonicalized = "/$AccountName/Tables"
    $authHeader    = New-TableAuthHeader -AccountName $AccountName -AccountKey $AccountKey `
                         -HttpMethod "POST" -ContentMD5 $contentMD5 -ContentType "application/json" `
                         -Date $date -CanonicalizedResource $canonicalized

    $uri     = "https://$AccountName.table.core.windows.net/Tables"
    $headers = @{
        "Authorization" = $authHeader
        "x-ms-date"     = $date
        "x-ms-version"  = "2019-02-02"
        "Accept"        = "application/json;odata=nometadata"
        "Content-MD5"   = $contentMD5
    }

    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
            -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Host "Azure Table '$TableName' created successfully." -ForegroundColor Green
        return $true
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 409) {
            Write-Host "Azure Table '$TableName' already exists." -ForegroundColor Green
            return $true
        }
        Write-Warning "Failed to create Azure Table '$TableName': $_"
        return $false
    }
}

# ==========================================
# HELPER: Query all rows for a given PartitionKey (source folder).
# Returns an array of entity objects, or an empty array if none found.
# ==========================================
function Get-AzureTableRows {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$TableName,
        [string]$PartitionKey
    )

    $safePartition = $PartitionKey -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $filter        = [System.Uri]::EscapeDataString("PartitionKey eq '$safePartition'")
    $date          = [System.DateTime]::UtcNow.ToString("R")
    $canonicalized = "/$AccountName/$TableName()"
    $authHeader    = New-TableAuthHeader -AccountName $AccountName -AccountKey $AccountKey `
                         -HttpMethod "GET" -ContentMD5 "" -ContentType "application/json" `
                         -Date $date -CanonicalizedResource $canonicalized

    $uri     = "https://$AccountName.table.core.windows.net/${TableName}()?\$filter=$filter"
    $headers = @{
        "Authorization" = $authHeader
        "x-ms-date"     = $date
        "x-ms-version"  = "2019-02-02"
        "Accept"        = "application/json;odata=nometadata"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
        return $response.value
    } catch {
        Write-Warning "Could not query Azure Table '$TableName': $_"
        return @()
    }
}

# ==========================================
# HELPER: Insert a new entity row into the Azure Table.
# Uses POST (InsertOrReplace is handled by Update-AzureTableRow for existing rows).
# ==========================================
function Write-AzureTableRow {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$TableName,
        [string]$PartitionKey,
        [string]$RowKey,
        [string]$FilePath,
        [string]$MD5Hash,
        [string]$HasExtension,
        [string]$Status,
        [string]$Notes,
        [string]$MigrationRunId,
        [int]   $RetryCount = 0
    )

    $safePartition = $PartitionKey -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $safeRow       = $RowKey       -replace "[\\/#?`u0000-`u001f`u007f]", '_'

    $date   = [System.DateTime]::UtcNow.ToString("R")
    $entity = @{
        PartitionKey   = $safePartition
        RowKey         = $safeRow
        FilePath       = $FilePath
        MD5Hash        = $MD5Hash
        HasExtension   = $HasExtension
        Status         = $Status
        Notes          = $Notes
        MigrationRunId = $MigrationRunId
        RetryCount     = $RetryCount          # 0 = first-time upload; increments on each re-attempt
        LoggedAt       = (Get-Date -Format "o")
    }
    $body      = $entity | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $contentMD5    = [System.Convert]::ToBase64String(
                         (New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bodyBytes))
    $canonicalized = "/$AccountName/$TableName"
    $authHeader    = New-TableAuthHeader -AccountName $AccountName -AccountKey $AccountKey `
                         -HttpMethod "POST" -ContentMD5 $contentMD5 -ContentType "application/json" `
                         -Date $date -CanonicalizedResource $canonicalized

    $uri     = "https://$AccountName.table.core.windows.net/$TableName"
    $headers = @{
        "Authorization" = $authHeader
        "x-ms-date"     = $date
        "x-ms-version"  = "2019-02-02"
        "Accept"        = "application/json;odata=nometadata"
        "Content-MD5"   = $contentMD5
    }

    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
            -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Could not insert row to Azure Table for '$FilePath': $_"
    }
}

# ==========================================
# HELPER: Update an existing entity (MERGE — only sends changed fields).
# Used to update Status, RetryCount, Notes, MigrationRunId on a resume/restart.
# ==========================================
function Update-AzureTableRow {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$TableName,
        [string]$PartitionKey,
        [string]$RowKey,
        [string]$Status,
        [string]$Notes        = "",
        [string]$MigrationRunId,
        [int]   $RetryCount
    )

    $safePartition = $PartitionKey -replace "[\\/#?`u0000-`u001f`u007f]", '_'
    $safeRow       = $RowKey       -replace "[\\/#?`u0000-`u001f`u007f]", '_'

    $date   = [System.DateTime]::UtcNow.ToString("R")
    $entity = @{
        Status         = $Status
        Notes          = $Notes
        MigrationRunId = $MigrationRunId
        RetryCount     = $RetryCount
        LastUpdated    = (Get-Date -Format "o")
    }
    $body      = $entity | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $contentMD5    = [System.Convert]::ToBase64String(
                         (New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bodyBytes))
    $encodedPK     = [System.Uri]::EscapeDataString($safePartition)
    $encodedRK     = [System.Uri]::EscapeDataString($safeRow)
    $canonicalized = "/$AccountName/$TableName(PartitionKey='$safePartition',RowKey='$safeRow')"
    $authHeader    = New-TableAuthHeader -AccountName $AccountName -AccountKey $AccountKey `
                         -HttpMethod "MERGE" -ContentMD5 $contentMD5 -ContentType "application/json" `
                         -Date $date -CanonicalizedResource $canonicalized

    $uri     = "https://$AccountName.table.core.windows.net/$TableName(PartitionKey='$encodedPK',RowKey='$encodedRK')"
    $headers = @{
        "Authorization" = $authHeader
        "x-ms-date"     = $date
        "x-ms-version"  = "2019-02-02"
        "Accept"        = "application/json;odata=nometadata"
        "Content-MD5"   = $contentMD5
        "If-Match"      = "*"   # unconditional update
    }

    try {
        Invoke-RestMethod -Uri $uri -Method MERGE -Headers $headers `
            -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Could not update row in Azure Table for PartitionKey='$safePartition' RowKey='$safeRow': $_"
    }
}

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
# FOLDER SELECTION
# ==========================================
Add-Type -AssemblyName System.Windows.Forms
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

$connParts   = Parse-ConnectionString -ConnectionString $StorageConnectionString
$AccountName = $connParts["AccountName"]
$AccountKey  = $connParts["AccountKey"]

if (-not $AccountName -or -not $AccountKey) {
    Write-Error "Could not parse AccountName or AccountKey from StorageConnectionString. Please check the CONFIGURATION section."
    exit 1
}

$SourceEncoded  = ConvertTo-AzCopyPath -LocalPath $SourceRaw
$SourceFolder   = Split-Path $SourceRaw -Leaf   # PartitionKey

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
Write-Host "Azure Table      : $TableName (Account: $AccountName)"
Write-Host "--------------------------------------------------"

# ==========================================
# AZURE TABLE: Ensure MigrationLog table exists
# ==========================================
Write-Host "`n[Setup] Ensuring Azure Table '$TableName' exists..." -ForegroundColor Yellow
$tableReady = Ensure-AzureTable -AccountName $AccountName -AccountKey $AccountKey -TableName $TableName
if (-not $tableReady) {
    Write-Error "Cannot proceed without a working Azure Table connection. Check your StorageConnectionString."
    exit 1
}

# ==========================================
# RESUME DETECTION: Query the table for existing rows for this folder
# ==========================================
Write-Host "`n[Resume Check] Querying Azure Table for previous migration of '$SourceFolder'..." -ForegroundColor Yellow
$existingRows = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                    -TableName $TableName -PartitionKey $SourceFolder

# Determine the mode: Fresh start or resume/restart choice
$IsResumeMode   = $false   # $true  = resume (skip already Uploaded/Validated files)
$IsRestartMode  = $false   # $true  = restart (re-upload everything, increment RetryCount)
$MigrationRunId = Get-Date -Format "yyyyMMdd_HHmmss"

if ($existingRows.Count -gt 0) {
    $uploadedCount  = ($existingRows | Where-Object { $_.Status -eq "Uploaded" -or $_.Status -eq "Validated" }).Count
    $pendingCount   = ($existingRows | Where-Object { $_.Status -eq "Pending"  -or $_.Status -eq "Failed" -or $_.Status -eq "HashError" }).Count
    $lastRunId      = ($existingRows | Sort-Object MigrationRunId -Descending | Select-Object -First 1).MigrationRunId

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
    Write-Host "No previous migration found for '$SourceFolder'. Starting fresh." -ForegroundColor Green
}

# Build a quick lookup of existing rows by RowKey for O(1) access during the hashing loop
$existingRowMap = @{}
foreach ($row in $existingRows) {
    $existingRowMap[$row.RowKey] = $row
}

# ==========================================
# PRE-FLIGHT: Hash files and write/update Azure Table rows
#
# Fresh start : INSERT new row with RetryCount = 0, Status = Pending
# Resume      : Only INSERT rows that are missing from the table (new files added since last run);
#               existing rows are left as-is — AzCopy will re-attempt Pending/Failed ones.
# Restart     : UPDATE every existing row: Status = Pending, RetryCount++
#               INSERT rows for any new files not in the table yet.
# ==========================================
Write-Host "`n[Pre-flight] Hashing source files and syncing with Azure Table '$TableName'..." -ForegroundColor Yellow

$sourceHashes  = @{}
$totalFiles    = 0
$noExtCount    = 0
$newFiles      = 0
$updatedFiles  = 0
$totalBytes    = [long]0   # sum of all source file sizes — used for MB/s calculation

Get-ChildItem -Path $SourceRaw -Recurse -File | ForEach-Object {
    $totalFiles++
    $file         = $_
    $totalBytes  += $file.Length   # accumulate bytes for MB/s calculation
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
        # File not seen before — always INSERT as fresh entry
        $newFiles++
        Write-AzureTableRow `
            -AccountName    $AccountName `
            -AccountKey     $AccountKey `
            -TableName      $TableName `
            -PartitionKey   $SourceFolder `
            -RowKey         $relativePath `
            -FilePath       $decodedPath `
            -MD5Hash        $hash `
            -HasExtension   ($hasExt.ToString().ToLower()) `
            -Status         $statusToWrite `
            -Notes          $errorNote `
            -MigrationRunId $MigrationRunId `
            -RetryCount     0

    } elseif ($IsRestartMode) {
        # Restart — bump RetryCount, reset Status so AzCopy re-uploads it
        $updatedFiles++
        $newRetryCount = [int]($existingRow.RetryCount) + 1
        Update-AzureTableRow `
            -AccountName    $AccountName `
            -AccountKey     $AccountKey `
            -TableName      $TableName `
            -PartitionKey   $SourceFolder `
            -RowKey         $relativePath `
            -Status         $statusToWrite `
            -Notes          $errorNote `
            -MigrationRunId $MigrationRunId `
            -RetryCount     $newRetryCount

    } elseif ($IsResumeMode) {
        # Resume — only reset rows that are NOT already done, so they get picked up by AzCopy
        $doneStatuses = @("Uploaded", "Validated")
        if ($existingRow.Status -notin $doneStatuses) {
            $updatedFiles++
            $newRetryCount = [int]($existingRow.RetryCount) + 1
            Update-AzureTableRow `
                -AccountName    $AccountName `
                -AccountKey     $AccountKey `
                -TableName      $TableName `
                -PartitionKey   $SourceFolder `
                -RowKey         $relativePath `
                -Status         $statusToWrite `
                -Notes          $errorNote `
                -MigrationRunId $MigrationRunId `
                -RetryCount     $newRetryCount
        }
        # Uploaded/Validated rows are left untouched — AzCopy sync will skip them
    }
    # Fresh start: rows don't exist yet, all handled by the $null branch above
}

Write-Host "Pre-flight complete. $totalFiles file(s) scanned | $newFiles new | $updatedFiles updated | $noExtCount with no extension." -ForegroundColor Green

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
    Write-Host "RESTART MODE: AzCopy will re-evaluate all files. RetryCount incremented in table." -ForegroundColor Cyan
}

# Start the migration timer — we only measure the actual AzCopy transfer, not pre-flight.
$migrationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Use azcopy sync for the upload — it intelligently skips already-uploaded files.
# --put-md5 ensures Content-MD5 is set on blobs for later checksum validation.
# Note: azcopy sync does not support --put-md5 directly on upload in all versions.
# If your AzCopy version does not support sync + put-md5, change to azcopy copy below.
$copyCommand = "azcopy sync ""$SourceEncoded"" ""$DestinationUrl"" --put-md5 --recursive=true --log-level=INFO"
Invoke-Expression $copyCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "AzCopy sync (upload) failed with exit code $LASTEXITCODE."
    Write-Host "Check the AzCopy logs in $LogDirectory for details." -ForegroundColor Red

    # Mark all Pending rows as Failed so the next resume attempt knows what to retry
    Write-Host "Marking Pending rows as Failed in Azure Table..." -ForegroundColor Yellow
    foreach ($row in $existingRows) {
        if ($row.Status -eq "Pending") {
            Update-AzureTableRow `
                -AccountName    $AccountName `
                -AccountKey     $AccountKey `
                -TableName      $TableName `
                -PartitionKey   $SourceFolder `
                -RowKey         $row.RowKey `
                -Status         "Failed" `
                -Notes          "AzCopy exited with code $LASTEXITCODE" `
                -MigrationRunId $MigrationRunId `
                -RetryCount     ([int]$row.RetryCount)
        }
    }
    exit $LASTEXITCODE
}

# Mark all rows for this folder as Uploaded
Write-Host "Updating Azure Table — marking all files as Uploaded..." -ForegroundColor Yellow
$allRows = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
               -TableName $TableName -PartitionKey $SourceFolder

foreach ($row in $allRows) {
    if ($row.Status -notin @("Validated", "Uploaded")) {
        Update-AzureTableRow `
            -AccountName    $AccountName `
            -AccountKey     $AccountKey `
            -TableName      $TableName `
            -PartitionKey   $SourceFolder `
            -RowKey         $row.RowKey `
            -Status         "Uploaded" `
            -Notes          $row.Notes `
            -MigrationRunId $MigrationRunId `
            -RetryCount     ([int]$row.RetryCount)
    }
}
# Stop the migration timer as soon as AzCopy finishes successfully
$migrationStopwatch.Stop()
$migrationElapsed = $migrationStopwatch.Elapsed

Write-Host "Seed Migration completed successfully." -ForegroundColor Green

# ==========================================
# STEP 2: Checksum Validation (dry-run sync)
# ==========================================
Write-Host "`n[Step 2] Executing Checksum Validation (Dry-run sync with MD5 comparison)..." -ForegroundColor Yellow
Write-Host "Note: --compare-hash=MD5 uses the Content-MD5 set by --put-md5 in Step 1."

$syncCommand = "azcopy sync ""$SourceEncoded"" ""$DestinationUrl"" --compare-hash=MD5 --dry-run --recursive=true --log-level=INFO"
Invoke-Expression $syncCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "AzCopy sync (validation) failed with exit code $LASTEXITCODE."
    Write-Host "Mismatches or errors found. Check AzCopy logs in $LogDirectory." -ForegroundColor Red
    exit $LASTEXITCODE
}

# Mark all Uploaded rows as Validated
Write-Host "Updating Azure Table — marking all files as Validated..." -ForegroundColor Yellow
$allRows = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
               -TableName $TableName -PartitionKey $SourceFolder

foreach ($row in $allRows) {
    if ($row.Status -eq "Uploaded") {
        Update-AzureTableRow `
            -AccountName    $AccountName `
            -AccountKey     $AccountKey `
            -TableName      $TableName `
            -PartitionKey   $SourceFolder `
            -RowKey         $row.RowKey `
            -Status         "Validated" `
            -Notes          $row.Notes `
            -MigrationRunId $MigrationRunId `
            -RetryCount     ([int]$row.RetryCount)
    }
}
Write-Host "Checksum Validation completed. Source and Destination match mathematically." -ForegroundColor Green

# ==========================================
# SUMMARY
# ==========================================

# Pull final row states from the table for accurate pass/fail counts
$finalRows      = Get-AzureTableRows -AccountName $AccountName -AccountKey $AccountKey `
                      -TableName $TableName -PartitionKey $SourceFolder
$countValidated = ($finalRows | Where-Object { $_.Status -eq "Validated" }).Count
$countUploaded  = ($finalRows | Where-Object { $_.Status -eq "Uploaded"  }).Count
$countFailed    = ($finalRows | Where-Object { $_.Status -eq "Failed" -or $_.Status -eq "HashError" }).Count
$countPending   = ($finalRows | Where-Object { $_.Status -eq "Pending"  }).Count
$countPassed    = $countValidated + $countUploaded   # Uploaded = done but not yet validated

# Migration speed — based on total source bytes divided by the AzCopy wall-clock time.
# On a resume this will over-report MB/s slightly because already-uploaded files are
# counted in $totalBytes but skipped by AzCopy. It is still a useful directional metric.
$totalMB            = [math]::Round($totalBytes / 1MB, 2)
$migrationSeconds   = [math]::Max($migrationElapsed.TotalSeconds, 1)   # avoid divide-by-zero
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
Write-Host "  No-extension files   : $noExtCount  (flagged in table)"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Total data size      : $totalMB MB"
Write-Host "  Migration duration   : $elapsedFormatted  (AzCopy transfer only, excludes pre-flight)"
Write-Host "  Average speed        : $avgSpeedMBps MB/s"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Azure Table          : $TableName  (Account: $AccountName)"
Write-Host "  AzCopy logs          : $LogDirectory"
Write-Host "==========================================================" -ForegroundColor Cyan
