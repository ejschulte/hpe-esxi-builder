Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'build-hpe-proliant-esxiupdate-crossplatform.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors.Message -join [Environment]::NewLine)
}

# Load functions without running the script's prerequisite checks and Main call.
foreach ($statement in $scriptAst.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        Set-Item -Path "Function:\$($statement.Name)" -Value $statement.Body.GetScriptBlock()
    }
}

function Get-DepotBaseImages { param($DepotZipPath) }
function New-OfflineBundle { param($Depots, $VendorName, $VendorCode, $SoftwareSpec, $Destination) }
function Add-EsxSoftwareDepot { param($DepotUrl) }
function Remove-EsxSoftwareDepot { [CmdletBinding()] param($SoftwareDepot) }
function Get-EsxImageProfile { param($SoftwareDepot) }
function New-EsxImageProfile { param($CloneProfile, $Name, $Vendor) }
function Export-EsxImageProfile { param($ImageProfile, [switch]$ExportToIso, [switch]$ExportToBundle, $FilePath) }

function New-SppFixture {
    param(
        [string]$Directory,
        [string]$ComponentName,
        [string]$ComponentVersion
    )

    $manifestDirectory = Join-Path $Directory 'manifest\vmw'
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $metadataPath = Join-Path $Directory 'metadata.zip'
    $metadataArchive = [System.IO.Compression.ZipFile]::Open($metadataPath, 'Create')
    try {
        $entry = $metadataArchive.CreateEntry('manifests/spp.json')
        $writer = [System.IO.StreamWriter]::new($entry.Open())
        try {
            $writer.Write((@{
                components = @{
                    $ComponentName = @{ version = $ComponentVersion }
                    shared = @{ version = 'shared-version' }
                }
                hardwareSupportInfo = @{ package = @{ version = '2026.01' } }
            } | ConvertTo-Json -Depth 10))
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $metadataArchive.Dispose()
    }

    $payloadPath = Join-Path $manifestDirectory 'payload.zip'
    $payloadArchive = [System.IO.Compression.ZipFile]::Open($payloadPath, 'Create')
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($payloadArchive, $metadataPath, 'metadata.zip') | Out-Null
    }
    finally {
        $payloadArchive.Dispose()
    }
}

Describe 'Proliant SPP array processing' {
    BeforeEach {
        $fixtureDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
        $script:ProliantSppIsoPath = @(
            (Join-Path $fixtureDirectory 'first.iso')
            (Join-Path $fixtureDirectory 'second.iso')
        )
        $script:VmwareDepotZipPath = Join-Path $fixtureDirectory 'vmware.zip'
        $script:WorkingDirectory = Join-Path $fixtureDirectory 'output'
        $script:mountedRoots = @{}
        $script:bundleCalls = [System.Collections.Generic.List[object]]::new()
        $script:profileNames = [System.Collections.Generic.List[string]]::new()
        $script:exportPaths = [System.Collections.Generic.List[string]]::new()

        foreach ($index in 0..1) {
            New-Item -ItemType File -Path $script:ProliantSppIsoPath[$index] -Force | Out-Null
            $root = Join-Path $fixtureDirectory "mounted-$index"
            New-SppFixture -Directory $root -ComponentName "driver-$index" -ComponentVersion "version-$index"
            $script:mountedRoots[$script:ProliantSppIsoPath[$index]] = $root
        }
        New-Item -ItemType File -Path $script:VmwareDepotZipPath -Force | Out-Null

        Mock Assert-Environment {}
        Mock Assert-PowerCliPythonConfiguration {}
        Mock Write-Host {}
        Mock Get-DepotBaseImages { [pscustomobject]@{ Version = '8.0.3' } }
        Mock Mount-IsoImage {
            @{
                RootPath = $script:mountedRoots[$IsoPath]
                IsoPath = $IsoPath
                MountPoint = $null
                Platform = 'Windows'
            }
        }
        Mock Dismount-IsoImage {}
        Mock New-OfflineBundle {
            $spec = Get-Content -LiteralPath $SoftwareSpec -Raw | ConvertFrom-Json -AsHashtable
            $script:bundleCalls.Add([pscustomobject]@{
                Depots = $Depots
                Destination = $Destination
                SoftwareSpec = $SoftwareSpec
                Components = $spec.components
                BaseVersion = $spec.base_image.version
            })
            Set-Content -LiteralPath $Destination -Value 'offline bundle'
        }
        Mock Add-EsxSoftwareDepot { [pscustomobject]@{ DepotUrl = $DepotUrl } }
        Mock Remove-EsxSoftwareDepot {}
        Mock Get-EsxImageProfile {
            if (-not (Test-Path -LiteralPath $SoftwareDepot.DepotUrl -PathType Leaf)) {
                throw 'Expected the current offline bundle to be imported before selecting its profile.'
            }
            [pscustomobject]@{
                Name = 'ESXi-8.0.3-0.0.12345'
                DepotUrl = $SoftwareDepot.DepotUrl
            }
        }
        Mock New-EsxImageProfile { $script:profileNames.Add($Name) }
        Mock Export-EsxImageProfile {
            $script:exportPaths.Add($FilePath)
            Set-Content -LiteralPath $FilePath -Value $ImageProfile
        }
    }

    It 'builds one combined bundle from all SPPs before cloning once and exporting one ISO and one ZIP' {
        Mock Remove-EsxSoftwareDepot {
            $script:exportPaths.Count | Should Be 2
        }
        Main

        $script:bundleCalls.Count | Should Be 1
        $script:bundleCalls[0].Components.Count | Should Be 3
        $script:bundleCalls[0].Components['driver-0'].version | Should Be 'version-0'
        $script:bundleCalls[0].Components['driver-1'].version | Should Be 'version-1'
        $script:bundleCalls[0].Components.shared.version | Should Be 'shared-version'
        $script:bundleCalls[0].BaseVersion | Should Be '8.0.3'
        (Test-Path -LiteralPath $script:bundleCalls[0].Destination) | Should Be $true
        $script:bundleCalls[0].Depots.Count | Should Be 3
        $script:bundleCalls[0].Depots[0] | Should Be (Join-Path $script:WorkingDirectory 'vmware.zip')
        $script:bundleCalls[0].Depots[1] | Should Be (Join-Path $script:WorkingDirectory '001-first\payload.zip')
        $script:bundleCalls[0].Depots[2] | Should Be (Join-Path $script:WorkingDirectory '002-second\payload.zip')
        $script:bundleCalls[0].SoftwareSpec | Should Be (Join-Path $script:WorkingDirectory 'ProliantPatch-softwarespec.json')
        $script:bundleCalls[0].Destination | Should Be (Join-Path $script:WorkingDirectory 'ProliantPatch-combined-depot.zip')
        Assert-MockCalled New-OfflineBundle -Scope It -Times 1 -Exactly
        Assert-MockCalled Add-EsxSoftwareDepot -Scope It -Times 1 -Exactly
        Assert-MockCalled Add-EsxSoftwareDepot -Scope It -Times 1 -Exactly -ParameterFilter { $DepotUrl -eq $script:bundleCalls[0].Destination }
        $script:profileNames.Count | Should Be 1
        $script:exportPaths.Count | Should Be 2
        $script:exportPaths[0] | Should Be (Join-Path $script:WorkingDirectory 'HPE-Proliant-2026.01-12345-custom-ESXi.iso')
        $script:exportPaths[1] | Should Be (Join-Path $script:WorkingDirectory 'HPE-Proliant-2026.01-12345-custom-ESXi-depot.zip')
        foreach ($path in $script:exportPaths) {
            (Test-Path -LiteralPath $path) | Should Be $true
            (Split-Path $path -Parent) | Should Be $script:WorkingDirectory
        }
        Assert-MockCalled Get-EsxImageProfile -Scope It -Times 1 -Exactly
        Assert-MockCalled Get-EsxImageProfile -Scope It -Times 1 -Exactly -ParameterFilter { $SoftwareDepot.DepotUrl -eq $script:bundleCalls[0].Destination }
        Assert-MockCalled New-EsxImageProfile -Scope It -Times 1 -Exactly
        Assert-MockCalled New-EsxImageProfile -Scope It -Times 1 -Exactly -ParameterFilter { $CloneProfile.DepotUrl -eq $script:bundleCalls[0].Destination }
        Assert-MockCalled Export-EsxImageProfile -Scope It -Times 1 -Exactly -ParameterFilter { $ExportToIso }
        Assert-MockCalled Export-EsxImageProfile -Scope It -Times 1 -Exactly -ParameterFilter { $ExportToBundle }
        Assert-MockCalled Remove-EsxSoftwareDepot -Scope It -Times 1 -Exactly -ParameterFilter { $SoftwareDepot.DepotUrl -eq $script:bundleCalls[0].Destination }
        Assert-MockCalled Get-DepotBaseImages -Scope It -Times 1 -Exactly
        Assert-MockCalled Dismount-IsoImage -Scope It -Times 2 -Exactly
    }

    It 'disconnects the combined depot even when profile export fails' {
        Mock Export-EsxImageProfile { throw 'Profile export failed' }

        { Main } | Should Throw 'Profile export failed'

        Assert-MockCalled Remove-EsxSoftwareDepot -Scope It -Times 1 -Exactly -ParameterFilter { $SoftwareDepot.DepotUrl -eq $script:bundleCalls[0].Destination }
    }

    It 'supports a single ISO and refreshes stale copied payloads and extracted metadata' {
        $script:ProliantSppIsoPath = @($script:ProliantSppIsoPath[0])
        $isoDirectory = Join-Path $script:WorkingDirectory '001-first'
        New-Item -ItemType Directory -Path $isoDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $isoDirectory 'payload.zip') -Value 'stale payload'
        Set-Content -LiteralPath (Join-Path $isoDirectory 'spp.json') -Value '{}'

        Main

        $script:bundleCalls.Count | Should Be 1
        $script:bundleCalls[0].Components['driver-0'].version | Should Be 'version-0'
        $script:exportPaths.Count | Should Be 2
        Assert-MockCalled Add-EsxSoftwareDepot -Scope It -Times 1 -Exactly
        Assert-MockCalled Dismount-IsoImage -Scope It -Times 1 -Exactly
    }

    It 'resolves relative input and new output paths from the PowerShell location rather than the process directory' {
        $expectedWorkingDirectory = Join-Path $fixtureDirectory 'relative output'
        $script:ProliantSppIsoPath = @('.\first.iso', '.\second.iso')
        $script:VmwareDepotZipPath = '.\vmware.zip'
        $script:WorkingDirectory = '.\relative output'
        $originalProcessDirectory = [System.Environment]::CurrentDirectory

        Push-Location -LiteralPath $fixtureDirectory
        try {
            [System.Environment]::CurrentDirectory = Split-Path $scriptPath -Parent

            Main

            $script:bundleCalls.Count | Should Be 1
            $script:bundleCalls[0].Depots[0] | Should Be (Join-Path $expectedWorkingDirectory 'vmware.zip')
            $script:exportPaths.Count | Should Be 2
            foreach ($path in $script:exportPaths) {
                (Split-Path $path -Parent) | Should Be $expectedWorkingDirectory
                (Test-Path -LiteralPath $path) | Should Be $true
            }
            Assert-MockCalled Mount-IsoImage -Scope It -Times 2 -Exactly -ParameterFilter { $script:mountedRoots.ContainsKey($IsoPath) }
        }
        finally {
            [System.Environment]::CurrentDirectory = $originalProcessDirectory
            Pop-Location
        }
    }

    It 'validates all input ISOs before processing the first one' {
        $script:ProliantSppIsoPath[1] = Join-Path $TestDrive 'missing.iso'

        { Main } | Should Throw 'Proliant ISO file does not exist'

        Assert-MockCalled Mount-IsoImage -Scope It -Times 0 -Exactly
        Assert-MockCalled New-OfflineBundle -Scope It -Times 0 -Exactly
    }

    It 'reports conflicting component versions without cloning or exporting a profile' {
        $conflictingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-SppFixture -Directory $conflictingRoot -ComponentName 'driver-0' -ComponentVersion 'conflicting-version'
        $script:mountedRoots[$script:ProliantSppIsoPath[1]] = $conflictingRoot

        { Main } | Should Throw "Conflicting versions for component 'driver-0'"

        $script:bundleCalls.Count | Should Be 0
        Assert-MockCalled Add-EsxSoftwareDepot -Scope It -Times 0 -Exactly
        Assert-MockCalled Dismount-IsoImage -Scope It -Times 2 -Exactly
        Assert-MockCalled Get-EsxImageProfile -Scope It -Times 0 -Exactly
        Assert-MockCalled New-EsxImageProfile -Scope It -Times 0 -Exactly
        Assert-MockCalled Export-EsxImageProfile -Scope It -Times 0 -Exactly
    }

    It 'dismounts all ISOs before a combined bundle failure and stops before profile export' {
        Mock New-OfflineBundle { throw 'Bundle creation failed' }

        { Main } | Should Throw 'Bundle creation failed'

        Assert-MockCalled Mount-IsoImage -Scope It -Times 2 -Exactly
        Assert-MockCalled Dismount-IsoImage -Scope It -Times 2 -Exactly
        Assert-MockCalled New-OfflineBundle -Scope It -Times 1 -Exactly
        Assert-MockCalled Add-EsxSoftwareDepot -Scope It -Times 0 -Exactly
        Assert-MockCalled New-EsxImageProfile -Scope It -Times 0 -Exactly
        Assert-MockCalled Export-EsxImageProfile -Scope It -Times 0 -Exactly
    }
}
