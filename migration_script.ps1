<#
.SYNOPSIS
    Migrates files from a network drive to Azure Blob Storage using AzCopy with MD5 hashing and checksum validation.

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

.EXAMPLE
    .\migration_script.ps1
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
        [string]$HttpMethod,       # GET, PUT, POST, DELETE
        [string]$ContentMD5 = "",
        [string]$ContentType = "application/json",
        [string]$Date,             # RFC1123 date string
        [string]$CanonicalizedResource  # e.g. /accountname/Tables
    )

    $stringToSign = "$HttpMethod`n$ContentMD5`n$ContentType`n$Date`n$CanonicalizedResource"
    $signature    = New-StorageSharedKeySignature -AccountName $AccountName -AccountKey $AccountKey -StringToSign $stringToSign

    return "SharedKey ${AccountName}:${signature}"
}

# ==========================================
# HELPER: Create the Azure Table if it does not already exist
# Uses the Tables REST endpoint: PUT https://<account>.table.core.windows.net/Tables
# Returns $true if created or already exists, $false on error.
# ==========================================
function Ensure-AzureTable {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$TableName
    )

    $date            = [System.DateTime]::UtcNow.ToString("R")
    $body            = "{`"TableName`":`"$TableName`"}"
    $bodyBytes       = [System.Text.Encoding]::UTF8.GetBytes($body)
    $contentMD5      = [System.Convert]::ToBase64String(
                            (New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bodyBytes)
                       )
    $canonicalized   = "/$AccountName/Tables"
    $authHeader      = New-TableAuthHeader `
                            -AccountName $AccountName `
                            -AccountKey  $AccountKey `
                            -HttpMethod  "POST" `
                            -ContentMD5  $contentMD5 `
                            -ContentType "application/json" `
                            -Date        $date `
                            -CanonicalizedResource $canonicalized

    $uri     = "https://$AccountName.table.core.windows.net/Tables"
    $headers = @{
        "Authorization"         = $authHeader
        "x-ms-date"             = $date
        "x-ms-version"          = "2019-02-02"
        "Accept"                = "application/json;odata=nometadata"
        "Content-MD5"           = $contentMD5
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
                        -Body $body -ContentType "application/json" -ErrorAction Stop
        Write-Host "Azure Table '$TableName' created successfully." -ForegroundColor Green
        return $true
    } catch {
        # 409 Conflict = table already exists — that is fine
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 409) {
            Write-Host "Azure Table '$TableName' already exists." -ForegroundColor Green
            return $true
        }
        Write-Warning "Failed to create Azure Table '$TableName': $_"
        return $false
    }
}

# ==========================================
# HELPER: Insert a single entity row into the Azure Table.
# PartitionKey = source folder name (safe for table keys)
# RowKey       = relative file path (safe for table keys)
# ==========================================
function Write-AzureTableRow {
    param(
        [string]$AccountName,
        [string]$AccountKey,
        [string]$TableName,
        [string]$PartitionKey,   # source folder name
        [string]$RowKey,         # relative file path
        [string]$FilePath,
        [string]$MD5Hash,
        [string]$HasExtension,   # "true" or "false"
        [string]$Status,
        [string]$Notes,
        [string]$MigrationRunId  # timestamp-based run identifier
    )

    # Azure Table keys cannot contain certain characters — sanitise them
    $safePartition = $PartitionKey -replace '[\\/#?\x00-\x1f\x7f]', '_'
    $safeRow       = $RowKey       -replace '[\\/#?\x00-\x1f\x7f]', '_'

    $date      = [System.DateTime]::UtcNow.ToString("R")
    $entity    = @{
        PartitionKey   = $safePartition
        RowKey         = $safeRow
        FilePath       = $FilePath
        MD5Hash        = $MD5Hash
        HasExtension   = $HasExtension
        Status         = $Status
        Notes          = $Notes
        MigrationRunId = $MigrationRunId
        Timestamp      = (Get-Date -Format "o")   # ISO 8601
    }
    $body      = $entity | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $contentMD5    = [System.Convert]::ToBase64String(
                         (New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bodyBytes)
                     )
    $canonicalized = "/$AccountName/$TableName"
    $authHeader    = New-TableAuthHeader `
                         -AccountName $AccountName `
                         -AccountKey  $AccountKey `
                         -HttpMethod  "POST" `
                         -ContentMD5  $contentMD5 `
                         -ContentType "application/json" `
                         -Date        $date `
                         -CanonicalizedResource $canonicalized

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
        Write-Warning "Could not write row to Azure Table for '$FilePath': $_"
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
# Only the path portion is encoded — the drive letter and
# backslashes are left intact so AzCopy can still resolve it.
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

# Ensure local AzCopy log directory exists
if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory | Out-Null
}

# Parse connection string and extract account credentials
$connParts   = Parse-ConnectionString -ConnectionString $StorageConnectionString
$AccountName = $connParts["AccountName"]
$AccountKey  = $connParts["AccountKey"]

if (-not $AccountName -or -not $AccountKey) {
    Write-Error "Could not parse AccountName or AccountKey from StorageConnectionString. Please check the CONFIGURATION section."
    exit 1
}

# Migration run identifier — used as a shared tag across all rows for this run
$MigrationRunId = Get-Date -Format "yyyyMMdd_HHmmss"

# URL-encode the source path so "#" and other special chars survive AzCopy parsing
$SourceEncoded  = ConvertTo-AzCopyPath -LocalPath $SourceRaw
$SourceFolder   = Split-Path $SourceRaw -Leaf   # used as PartitionKey

# AzCopy environment variables
$env:AZCOPY_CONCURRENCY_VALUE   = $ConcurrencyValue.ToString()
$env:AZCOPY_LOG_LOCATION        = $LogDirectory
$env:AZCOPY_REQUEST_TRY_TIMEOUT = $RequestTryTimeout

Write-Host "Starting AzCopy Migration Script" -ForegroundColor Cyan
Write-Host "Source (raw)      : $SourceRaw"
Write-Host "Source (encoded)  : $SourceEncoded"
Write-Host "Destination       : [REDACTED SAS URL]"
Write-Host "Concurrency       : $ConcurrencyValue"
Write-Host "Request Timeout   : ${RequestTryTimeout}s"
Write-Host "AzCopy log dir    : $LogDirectory"
Write-Host "Azure Table       : $TableName (Account: $AccountName)"
Write-Host "Migration Run ID  : $MigrationRunId"
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
# PRE-FLIGHT: Compute MD5 hashes and log each file to Azure Table
# Files with no extension are flagged (HasExtension=false) but do NOT block migration.
# ==========================================
Write-Host "`n[Pre-flight] Hashing source files and writing to Azure Table '$TableName'..." -ForegroundColor Yellow
Write-Host "Note: Files with no extension will be flagged in the table but migration will NOT be delayed."

$sourceHashes = @{}
$totalFiles   = 0
$noExtCount   = 0

Get-ChildItem -Path $SourceRaw -Recurse -File | ForEach-Object {
    $totalFiles++
    $file         = $_
    $decodedPath  = ConvertFrom-UrlEncoding -Encoded $file.FullName
    $relativePath = $file.FullName.Substring($SourceRaw.Length).TrimStart('\')
    $hasExt       = ($file.Extension -ne "")
    $notes        = ""

    if (-not $hasExt) {
        $noExtCount++
        $notes = "No file extension — verify file type after migration"
        Write-Warning "No extension: $($file.FullName)"
    }

    try {
        $hash = (Get-FileHash -Path $file.FullName -Algorithm MD5).Hash
        $sourceHashes[$decodedPath] = $hash

        Write-AzureTableRow `
            -AccountName   $AccountName `
            -AccountKey    $AccountKey `
            -TableName     $TableName `
            -PartitionKey  $SourceFolder `
            -RowKey        $relativePath `
            -FilePath      $decodedPath `
            -MD5Hash       $hash `
            -HasExtension  ($hasExt.ToString().ToLower()) `
            -Status        "Pending" `
            -Notes         $notes `
            -MigrationRunId $MigrationRunId

    } catch {
        Write-Warning "Could not hash file: $($file.FullName) — $_"

        Write-AzureTableRow `
            -AccountName   $AccountName `
            -AccountKey    $AccountKey `
            -TableName     $TableName `
            -PartitionKey  $SourceFolder `
            -RowKey        $relativePath `
            -FilePath      $decodedPath `
            -MD5Hash       "ERROR" `
            -HasExtension  ($hasExt.ToString().ToLower()) `
            -Status        "HashError" `
            -Notes         "MD5 hash computation failed: $_" `
            -MigrationRunId $MigrationRunId
    }
}

Write-Host "Pre-flight complete. $totalFiles file(s) catalogued ($noExtCount with no extension)." -ForegroundColor Green

# ==========================================
# STEP 1: Seed Migration
# ==========================================
Write-Host "`n[Step 1] Executing Seed Migration (Upload with MD5)..." -ForegroundColor Yellow
Write-Host "Note: Source path is URL-encoded so files with '#' and special characters are included."

$copyCommand = "azcopy copy ""$SourceEncoded\*"" ""$DestinationUrl"" --put-md5 --recursive=true --log-level=INFO"
Invoke-Expression $copyCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "AzCopy copy operation failed with exit code $LASTEXITCODE."
    Write-Host "Check the AzCopy logs in $LogDirectory for details." -ForegroundColor Red
    exit $LASTEXITCODE
}
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

Write-Host "Checksum Validation completed. Source and Destination match mathematically." -ForegroundColor Green

# ==========================================
# SUMMARY
# ==========================================
Write-Host "`n==================== MIGRATION SUMMARY ====================" -ForegroundColor Cyan
Write-Host "Total files catalogued : $totalFiles"
Write-Host "Files with no extension: $noExtCount  (flagged in Azure Table '$TableName')"
Write-Host "Migration Run ID       : $MigrationRunId"
Write-Host "Azure Table            : $TableName (Account: $AccountName)"
Write-Host "AzCopy logs            : $LogDirectory"
Write-Host "Status                 : Migration and validation completed successfully."
Write-Host "===========================================================" -ForegroundColor Cyan
