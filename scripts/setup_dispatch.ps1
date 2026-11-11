# One-time setup for the external trigger of the "Send emails daily" workflow.
#
# 1. asks for a fine-grained PAT (Actions: Read and write on this repo only)
# 2. verifies the token against the GitHub API
# 3. stores it DPAPI-encrypted in %USERPROFILE%\.zotero-arxiv-daily\pat.txt
# 4. optionally registers a daily Windows scheduled task that runs dispatch_daily.ps1
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_dispatch.ps1

param(
    [string]$Repo = '17862398256/zotero-arxiv-daily',
    [string]$TaskTime = '06:30'
)

$ErrorActionPreference = 'Stop'
$patDir  = Join-Path $env:USERPROFILE '.zotero-arxiv-daily'
$patFile = Join-Path $patDir 'pat.txt'

Write-Host '=== zotero-arxiv-daily: external trigger setup ===' -ForegroundColor Cyan

if (Test-Path $patFile) {
    $answer = Read-Host 'A token is already stored. Replace it? (y/N)'
    if ($answer -ne 'y') {
        Write-Host 'Keeping the existing token.'
    } else {
        Remove-Item $patFile -Force
    }
}

if (-not (Test-Path $patFile)) {
    Write-Host ''
    Write-Host 'Create the token at: https://github.com/settings/personal-access-tokens/new'
    Write-Host '  Repository access : Only select repositories -> 17862398256/zotero-arxiv-daily'
    Write-Host '  Permissions       : Actions = Read and write   (Metadata = Read is added automatically)'
    Write-Host '  Expiration        : 90 days or longer (remember to renew)'
    Write-Host ''
    $secure = Read-Host 'Paste the token (input is hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'Empty token, aborting.' }
    if (-not $plain.StartsWith('github_pat_') -and -not $plain.StartsWith('ghp_')) {
        Write-Host 'Warning: the token does not look like a GitHub PAT. Continuing anyway.' -ForegroundColor Yellow
    }

    # Verify the token can read the workflow (needs Actions: Read).
    $headers = @{ Authorization = "Bearer $plain"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'zotero-arxiv-setup' }
    try {
        $wf = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/workflows/main.yml" -Headers $headers -TimeoutSec 20
        Write-Host ("Token OK. Sees workflow '{0}' (state: {1})." -f $wf.name, $wf.state) -ForegroundColor Green
    }
    catch {
        throw "Token check failed: $($_.Exception.Message). Check repository selection and the Actions permission."
    }

    if (-not (Test-Path $patDir)) { New-Item -ItemType Directory -Path $patDir -Force | Out-Null }
    ($secure | ConvertFrom-SecureString) | Set-Content -Path $patFile -Encoding utf8
    Write-Host "Token stored (encrypted, current Windows user only): $patFile" -ForegroundColor Green
}

# Optional: register the daily task.
Write-Host ''
$answer = Read-Host ("Register a daily scheduled task at {0} (local time)? (y/N)" -f $TaskTime)
if ($answer -eq 'y') {
    $cmd = Join-Path $PSScriptRoot 'run_dispatch.cmd'
    if (-not (Test-Path $cmd)) { throw "Missing $cmd" }
    if ($cmd -match '\s') {
        Write-Host 'Path contains spaces; scheduled task quoting may fail. Move the repo to a path without spaces, or create the task manually.' -ForegroundColor Yellow
    }
    $taskName = 'zotero-arxiv-daily-dispatch'
    try {
        $action  = New-ScheduledTaskAction -Execute $cmd
        $trigger = New-ScheduledTaskTrigger -Daily -At $TaskTime
        $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $set -Description 'Trigger the zotero-arxiv-daily email workflow every morning.' -Force | Out-Null
        Write-Host "Scheduled task '$taskName' registered for $TaskTime daily." -ForegroundColor Green
    }
    catch {
        Write-Host "Could not register the task automatically: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Run this in an elevated PowerShell instead:'
        Write-Host ('  schtasks /Create /TN "{0}" /TR "{1}" /SC DAILY /ST {2} /F' -f $taskName, $cmd, $TaskTime)
    }
}

# Optional: fire one test dispatch now.
Write-Host ''
$answer = Read-Host 'Send one test dispatch now? (y/N)'
if ($answer -eq 'y') {
    & (Join-Path $PSScriptRoot 'dispatch_daily.ps1') -Force
}

Write-Host ''
Write-Host 'Done. Verify at https://github.com/17862398256/zotero-arxiv-daily/actions' -ForegroundColor Cyan
