#requires -Version 5.1
<#
WRMS bootstrap installer. Copyright (c) 2026 Rocky Roos. See LICENSE.
Downloads the pinned official self-contained release and checks its SHA-256.
Run from Windows PowerShell 5.1 or PowerShell 7 (x64).
#>
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'WRMS'),
    [switch]$NoLaunch
)

& {
    param([string]$Destination, [bool]$SkipLaunch)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $version = '0.1.0'
    $asset = 'WRMS-v0.1.0-win-x64-selfcontained.zip'
    $expectedHash = '268D71789F82858D1EDBD47D7AA9F85AE971AB6120A62FAEC89906973E374259'
    $downloadUrl = "https://github.com/rockyroos/wrms-releases/releases/download/v$version/$asset"

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'WRMS requires Windows x64. Open the 64-bit Windows PowerShell or PowerShell 7 app.'
    }
    $Destination = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            @(Get-ChildItem -LiteralPath $Destination -Force).Count -gt 0) {
            throw "The installation folder must be empty: $Destination. Your existing files have not been changed. Use -InstallPath to select a different folder."
        }
    }

    function Find-WRMSPowerShell {
        $probeCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
            'if ($PSVersionTable.PSVersion.Major -ge 7 -and [Environment]::Is64BitProcess) { "WRMS_PWSH_OK" } else { exit 1 }'
        ))
        $candidates = @(
            Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }
        )
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
        foreach ($candidate in ($candidates | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            try {
                $probe = & $candidate -NoLogo -NoProfile -NonInteractive -EncodedCommand $probeCommand 2>$null
                if ($LASTEXITCODE -eq 0 -and $probe -contains 'WRMS_PWSH_OK') { return $candidate }
            } catch { }
        }
        return $null
    }

    $pwshPath = Find-WRMSPowerShell
    if (-not $pwshPath) {
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $winget) {
            throw 'PowerShell 7 is required and WinGet is unavailable. Install PowerShell 7 from https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows and run this command again.'
        }
        Write-Host 'Installing PowerShell 7 from Microsoft through WinGet. Review any installer or permission prompts.'
        & $winget.Source install --id Microsoft.PowerShell --exact --source winget --architecture x64
        if ($LASTEXITCODE -ne 0) { throw "PowerShell installation did not complete (WinGet exit $LASTEXITCODE). WRMS has not been installed." }
        # Newly installed applications may not be visible on this process's PATH.
        $savedPath = $env:PATH
        try {
            $env:PATH = $savedPath + ';' + [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
            $pwshPath = Find-WRMSPowerShell
        } finally { $env:PATH = $savedPath }
        if (-not $pwshPath) { throw 'PowerShell 7 was installed but could not be started. Reopen your terminal and run the WRMS command again.' }
    }

    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $work = Join-Path $tempRoot ('WRMS-bootstrap-' + [guid]::NewGuid().ToString('N'))
    $savedProtocol = [Net.ServicePointManager]::SecurityProtocol
    $savedPath = $env:PATH
    try {
        New-Item -ItemType Directory -Path $work | Out-Null
        # Enable TLS 1.2 for older Windows PowerShell configurations, for this process only.
        [Net.ServicePointManager]::SecurityProtocol = $savedProtocol -bor [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $work $asset
        Write-Host "Downloading WRMS v$version (self-contained)..."
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $zip
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'Download checksum mismatch. Installation stopped before extracting or running anything.'
        }
        Unblock-File -LiteralPath $zip
        $package = Join-Path $work 'package'
        Expand-Archive -LiteralPath $zip -DestinationPath $package
        # The GUI and release installer resolve pwsh by name. This PATH change is
        # inherited by child processes only; the user's stored PATH is unchanged.
        $env:PATH = (Split-Path $pwshPath -Parent) + ';' + $savedPath
        & $pwshPath -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $package 'Install-WRMS.ps1') -SourcePath $package -InstallPath $Destination
        if ($LASTEXITCODE -ne 0) { throw "WRMS installation failed (exit $LASTEXITCODE). See the error above." }
        $executable = Join-Path $Destination 'WRMS.Configurator.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'The installed WRMS executable is missing.' }
        Write-Host "WRMS v$version is ready: $executable"
        if (-not $SkipLaunch) { Start-Process -FilePath $executable -WorkingDirectory $Destination }
    } finally {
        $env:PATH = $savedPath
        [Net.ServicePointManager]::SecurityProtocol = $savedProtocol
        # Remove only this invocation's verified temporary directory, never the
        # installation folder. Leave unexpected links in place instead of following them.
        if (Test-Path -LiteralPath $work) {
            $resolved = (Resolve-Path -LiteralPath $work).Path.TrimEnd('\')
            $links = @(Get-Item -LiteralPath $work -Force; Get-ChildItem -LiteralPath $work -Recurse -Force) |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
            if ($resolved -eq $work -and $resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and -not $links) {
                Remove-Item -LiteralPath $resolved -Recurse -Force
            } else {
                Write-Warning "Temporary files retained for manual review: $work"
            }
        }
    }
} $InstallPath ([bool]$NoLaunch)
