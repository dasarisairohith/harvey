param(
    [int]$RetrySeconds = 300
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$python = Join-Path $projectRoot ".venv\Scripts\python.exe"
$harvey = Join-Path $projectRoot ".venv\Scripts\harvey.exe"
$dataDirectory = Join-Path $projectRoot "data"
$logPath = Join-Path $dataDirectory "startup.log"
$lastWaitReason = ""

New-Item -ItemType Directory -Force -Path $dataDirectory | Out-Null
$env:PYTHONPATH = if ($env:PYTHONPATH) {
    "$projectRoot;$env:PYTHONPATH"
} else {
    $projectRoot
}

function Write-StartupLog([string]$message) {
    Add-Content -LiteralPath $logPath -Encoding UTF8 `
        -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $message"
}

function Get-ClaudeExecutable {
    $command = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $packageRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $packageRoot) {
        $packages = Get-ChildItem -LiteralPath $packageRoot -Directory `
            -Filter "Anthropic.ClaudeCode*" -ErrorAction SilentlyContinue
        foreach ($package in $packages) {
            $executable = Join-Path $package.FullName "claude.exe"
            if (Test-Path -LiteralPath $executable) {
                return $executable
            }
        }
    }
    return $null
}

while ($true) {
    if (-not (Test-Path -LiteralPath $python) -or
        -not (Test-Path -LiteralPath $harvey)) {
        $reason = "Harvey is not installed in its project virtual environment."
    } else {
        $setupState = & $python -c `
            "from harvey.main import _needs_setup; print('setup_required' if _needs_setup() else 'ready')" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $reason = "Harvey setup could not be checked."
        } elseif ($setupState -contains "setup_required") {
            $reason = "Waiting for first-time Harvey setup. Run harvey setup from the project folder."
        } else {
            $claude = Get-ClaudeExecutable
            if (-not $claude) {
                $reason = "Waiting for Claude Code to be installed and signed in."
            } else {
                $authOutput = & $claude auth status 2>$null
                if ($LASTEXITCODE -ne 0) {
                    $reason = "Waiting for Claude Code to be signed in."
                } else {
                    try {
                        $auth = ($authOutput -join "`n") | ConvertFrom-Json
                        if (-not $auth.loggedIn) {
                            $reason = "Waiting for Claude Code to be signed in."
                        } else {
                            $reason = ""
                        }
                    } catch {
                        $reason = "Claude Code login status could not be checked."
                    }
                }
            }
        }
    }

    if ($reason) {
        if ($reason -ne $lastWaitReason) {
            Write-StartupLog $reason
            $lastWaitReason = $reason
        }
        Start-Sleep -Seconds $RetrySeconds
        continue
    }

    $lastWaitReason = ""
    Write-StartupLog "Starting Harvey heartbeat. Email approval remains controlled by Harvey configuration."
    try {
        Push-Location $projectRoot
        try {
            & $harvey run >> $logPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        Write-StartupLog "Harvey heartbeat exited with code $exitCode; retrying in $RetrySeconds seconds."
    } catch {
        Write-StartupLog "Harvey heartbeat could not start ($($_.Exception.GetType().Name)); retrying in $RetrySeconds seconds."
    }
    Start-Sleep -Seconds $RetrySeconds
}
