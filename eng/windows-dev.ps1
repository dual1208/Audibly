[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Verify', 'Build', 'Package', 'Install', 'Update', 'Smoke', 'CI', 'Uninstall')]
    [string]$Action = 'Verify'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactRoot = Join-Path $repoRoot '.artifacts\windows-x64'
$packageRoot = Join-Path $artifactRoot 'msix'
$packageName = 'dual1208.AudiblyFork'
$certificateSubject = 'CN=dual1208'
$certificateFriendlyName = 'Codex Local App Package Signing'
$script:msbuild = $null
$script:bootstrapped = $false

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-MSBuild {
    if ($script:msbuild) { return $script:msbuild }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Installer (vswhere.exe) is required.' }
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Workload.ManagedDesktop -property installationPath
    if (-not $installation) { throw 'Install Visual Studio with .NET desktop development.' }
    $candidate = Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
    if (-not (Test-Path -LiteralPath $candidate)) { throw "MSBuild not found at $candidate" }
    $script:msbuild = $candidate
    return $candidate
}

function Get-WindowsSdkTool {
    param([Parameter(Mandatory)][string]$Name)
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem $sdkBin -Filter "$Name.exe" -File -Recurse |
        Where-Object FullName -match '\\x64\\' |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $tool) { throw "$Name.exe was not found in the Windows SDK." }
    return $tool.FullName
}

function Initialize-Environment {
    if ($script:bootstrapped) { return }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET SDK 8 or newer is required.' }
    $sdkMajors = & dotnet --list-sdks | ForEach-Object { [int]($_.Split('.')[0]) }
    if (-not ($sdkMajors | Where-Object { $_ -ge 8 })) { throw '.NET SDK 8 or newer is required.' }
    $msbuild = Get-MSBuild
    Push-Location $repoRoot
    try {
        Invoke-Checked $msbuild @('Audibly.sln', '/t:Restore', '/m', '/p:Configuration=Release', '/p:Platform=x64')
        $script:bootstrapped = $true
    }
    finally { Pop-Location }
}

function Invoke-Build {
    Initialize-Environment
    $msbuild = Get-MSBuild
    Push-Location $repoRoot
    try {
        Invoke-Checked $msbuild @(
            'Audibly.sln', '/m', '/p:Configuration=Release', '/p:Platform=x64',
            '/p:WindowsPackageType=None', '/p:AppxPackageSigningEnabled=false',
            '/p:GenerateAppxPackageOnBuild=false'
        )
    }
    finally { Pop-Location }
}

function Get-SigningCertificate {
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object {
            $_.Subject -eq $certificateSubject -and
            $_.FriendlyName -eq $certificateFriendlyName -and
            ($_.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }) -contains '1.3.6.1.5.5.7.3.3' -and
            $_.HasPrivateKey
        } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $certificate) {
        throw 'Run powershell/scripts/Ensure-LocalAppPackageSigningCertificate.ps1 in codex-admin first.'
    }
    $cerPath = Join-Path $artifactRoot 'Codex-Local-App-Package-Signing.cer'
    Export-Certificate -Cert $certificate -FilePath $cerPath -Force | Out-Null
    return $certificate
}

function Assert-DevelopmentCertificateTrusted {
    param([Parameter(Mandatory)]$Certificate)
    $trustedPath = "Cert:\LocalMachine\TrustedPeople\$($Certificate.Thumbprint)"
    if (-not (Test-Path -LiteralPath $trustedPath)) {
        $cerPath = Join-Path $artifactRoot 'Codex-Local-App-Package-Signing.cer'
        throw @"
The development signing certificate is not trusted for AppX deployment.
From an elevated PowerShell, trust only this exported certificate, then rerun Install:
  Import-Certificate -FilePath '$cerPath' -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
Rollback:
  Remove-Item -LiteralPath '$trustedPath'
"@
    }
}

function Invoke-Package {
    Initialize-Environment
    $msbuild = Get-MSBuild
    if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
    $certificate = Get-SigningCertificate
    $manifestPath = Join-Path $repoRoot 'Audibly.App\Package.appxmanifest'
    $originalManifest = Get-Content -LiteralPath $manifestPath -Raw
    $versionEpoch = [datetime]'2020-01-01T00:00:00Z'
    $now = [datetime]::UtcNow
    [xml]$manifest = $originalManifest
    $baseVersion = [version]$manifest.Package.Identity.Version
    $packageVersion = "$($baseVersion.Major).$($baseVersion.Minor).$([int]($now - $versionEpoch).TotalDays).$([int]$now.TimeOfDay.TotalSeconds % 65535)"
    [xml]$buildManifest = $originalManifest
    $buildManifest.Package.Identity.Version = $packageVersion
    $buildManifest.Save($manifestPath)
    Push-Location $repoRoot
    try {
        Invoke-Checked $msbuild @(
            'Audibly.App\Audibly.App.csproj', '/t:Rebuild', '/m',
            '/p:Configuration=Release', '/p:Platform=x64', '/p:RuntimeIdentifier=win-x64',
            '/p:AppxPackageSigningEnabled=true', '/p:GenerateAppxPackageOnBuild=true',
            "/p:AppxPackageVersion=$packageVersion",
            "/p:PackageCertificateThumbprint=$($certificate.Thumbprint)", '/p:AppxBundle=Never',
            '/p:UapAppxPackageBuildMode=SideloadOnly', "/p:AppxPackageDir=$packageRoot\",
            '/p:PublishProfile='
        )
        $builtPackage = Get-ChildItem $packageRoot -Filter '*.msix' -File -Recurse |
            Where-Object { $_.FullName -notmatch '\\Dependencies\\' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $builtPackage) { throw "No MSIX package was produced beneath $packageRoot" }
        $msixPath = Join-Path $artifactRoot "Audibly-Fork-$packageVersion-windows-x64.msix"
        Copy-Item -LiteralPath $builtPackage.FullName -Destination $msixPath -Force
        $signTool = Get-WindowsSdkTool 'SignTool'
        Invoke-Checked $signTool @('verify', '/pa', '/v', $msixPath)
        Get-Item $msixPath, (Join-Path $artifactRoot 'Codex-Local-App-Package-Signing.cer') |
            Select-Object Name, Length, LastWriteTime
    }
    finally {
        Pop-Location
        Set-Content -LiteralPath $manifestPath -Value $originalManifest -Encoding utf8NoBOM -NoNewline
    }
}

function Get-LatestForkPackage {
    $package = Get-ChildItem $artifactRoot -Filter 'Audibly-Fork-*-windows-x64.msix' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $package) { throw "No fork MSIX exists beneath $artifactRoot" }
    return $package
}

function Install-Fork {
    Invoke-Package
    $msixPath = (Get-LatestForkPackage).FullName
    $certificate = Get-SigningCertificate
    Assert-DevelopmentCertificateTrusted -Certificate $certificate
    Add-AppxPackage -Path $msixPath -ForceApplicationShutdown -ForceUpdateFromAnyVersion
    $installed = Get-AppxPackage -Name $packageName
    if (-not $installed) { throw 'Fork package installation validation failed.' }
    Write-Output "Installed/updated $($installed.PackageFullName)"
}

function Uninstall-Fork {
    Get-AppxPackage -Name $packageName | Remove-AppxPackage
    Write-Output 'Removed the exact Audibly Fork package identity. The shared signing certificate remains installed.'
}

function Invoke-Smoke {
    $package = Get-AppxPackage -Name $packageName
    if (-not $package) { throw "Package $packageName is not installed." }
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $application = @($manifest.Package.Applications.Application)[0]
    $aumid = "$($package.PackageFamilyName)!$($application.Id)"
    $processName = [IO.Path]::GetFileNameWithoutExtension([string]$application.Executable)
    $before = @(Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Start-Process explorer.exe "shell:AppsFolder\$aumid"
    Start-Sleep -Seconds 10
    $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { throw "Packaged launch failed: $aumid ($processName)" }
    $new = @($running | Where-Object { $_.Id -notin $before })
    foreach ($process in $new) { $null = $process.CloseMainWindow() }
    Write-Output "Launch smoke passed for $aumid; process $processName remained healthy for 10 seconds."
}

switch ($Action) {
    'Bootstrap' { Initialize-Environment }
    'Verify' { Invoke-Build }
    'Build' { Invoke-Build }
    'Package' { Invoke-Package }
    { $_ -in @('Install', 'Update') } { Install-Fork }
    'Smoke' { Invoke-Smoke }
    'CI' { Invoke-Build; Install-Fork; Invoke-Smoke }
    'Uninstall' { Uninstall-Fork }
}
