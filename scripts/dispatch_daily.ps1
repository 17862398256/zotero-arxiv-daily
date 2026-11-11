# Trigger the "Send emails daily" workflow via the GitHub API.
# Needed because GitHub's own `on: schedule` stopped firing for this repo (2026-10).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dispatch_daily.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dispatch_daily.ps1 -DryRun
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dispatch_daily.ps1 -Force
#
# PAT lookup order:
#   1. -Token <string>            (avoid: ends up in shell history)
#   2. $env:GH_PAT
#   3. %USERPROFILE%\.zotero-arxiv-daily\pat.txt  (DPAPI-encrypted, created by setup_dispatch.ps1)

param(
    [string]$Repo   = '17862398256/zotero-arxiv-daily',
    [string]$Branch = 'main',
    [string]$WorkflowFile = 'main.yml',
    [string]$Token,
    [int]$WindowHours = 4,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['Invoke-RestMethod:TimeoutSec'] = 20

$patFile = Join-Path $env:USERPROFILE '.zotero-arxiv-daily\pat.txt'
$logDir  = Join-Path $PSScriptRoot 'logs'
$logFile = Join-Path $logDir ('dispatch-{0}.log' -f (Get-Date -Format 'yyyy-MM'))

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

function Get-Pat {
    if ($Token) { return $Token }
    if ($env:GH_PAT) { return $env:GH_PAT }
    if (Test-Path $patFile) {
        $sec = Get-Content -Path $patFile -Encoding utf8 | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return $null
}

function Invoke-GitHubApi {
    param([string]$Method, [string]$Uri, $Payload, [string]$Auth)

    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'zotero-arxiv-dispatch'
    }
    if ($Auth) { $headers['Authorization'] = "Bearer $Auth" }

    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($Payload) {
        $params['Body'] = ($Payload | ConvertTo-Json -Depth 4)
        $params['ContentType'] = 'application/json'
    }
    return Invoke-RestMethod @params
}

try {
    Write-Log "Repo=$Repo workflow=$WorkflowFile branch=$Branch window=${WindowHours}h dryRun=$DryRun force=$Force"

    $auth = $null
    if (-not $DryRun) { $auth = Get-Pat }
    if (-not $DryRun -and -not $auth) {
        Write-Log 'No PAT found. Run setup_dispatch.ps1 first, or set $env:GH_PAT.' 'ERROR'
        exit 2
    }
    if ($DryRun -and -not $auth) {
        Write-Log 'DryRun without PAT: using anonymous API (fine for public repos).' 'WARN'
    }

    # 1) Did the workflow already start recently? Then today's email is presumably on its way.
    $runsUri = "https://api.github.com/repos/$Repo/actions/workflows/$WorkflowFile/runs?per_page=15"
    $runs = (Invoke-GitHubApi -Method Get -Uri $runsUri -Auth $auth).workflow_runs

    $cutoff = (Get-Date).ToUniversalTime().AddHours(-$WindowHours)
    $recent = @($runs | Where-Object {
        $_.created_at -and ([datetime]::Parse($_.created_at).ToUniversalTime() -ge $cutoff)
    })

    if ($recent.Count -gt 0 -and -not $Force) {
        $latest = $recent | Sort-Object { [datetime]::Parse($_.created_at) } -Descending | Select-Object -First 1
        Write-Log ('Skip: run {0} ({1}, {2}) already started at {3} UTC (within {4}h).' -f `
            $latest.id, $latest.event, $latest.status, $latest.created_at, $WindowHours)
        Write-Log 'Nothing dispatched. Use -Force to dispatch anyway.'
        exit 0
    }
    Write-Log "No run in the last ${WindowHours}h. Proceeding with dispatch."

    # 2) Dispatch
    $dispatchUri = "https://api.github.com/repos/$Repo/actions/workflows/$WorkflowFile/dispatches"
    if ($DryRun) {
        Write-Log "DryRun: would POST $dispatchUri with body ref=$Branch"
        exit 0
    }

    Invoke-GitHubApi -Method Post -Uri $dispatchUri -Auth $auth -Payload @{ ref = $Branch } | Out-Null
    Write-Log 'Dispatch accepted (HTTP 204). Waiting for the run to appear...'

    # 3) Confirm a run was created
    Start-Sleep -Seconds 8
    $after = (Invoke-GitHubApi -Method Get -Uri "https://api.github.com/repos/$Repo/actions/workflows/$WorkflowFile/runs?per_page=5" -Auth $auth).workflow_runs
    $newRun = $after | Where-Object { $_['event'] -eq 'workflow_dispatch' } | Select-Object -First 1
    if ($newRun) {
        Write-Log ('Run {0} created at {1} UTC, status={2}. {3}' -f $newRun.id, $newRun.created_at, $newRun.status, $newRun.html_url)
    } else {
        Write-Log 'Dispatch accepted but no new run found yet. Check the Actions tab.' 'WARN'
    }
    exit 0
}
catch {
    Write-Log ('FAILED: {0}' -f $_.Exception.Message) 'ERROR'
    exit 1
}
