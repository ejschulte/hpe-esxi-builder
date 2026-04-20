Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-Environment {
    if (-not $IsWindows) {
        throw 'This script can only run on Windows.'
    }

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'This script requires PowerShell 7 or later.'
    }

    if (-not (Get-Command -Name Mount-DiskImage -ErrorAction SilentlyContinue)) {
        throw 'Mount-DiskImage is not available on this system.'
    }

    if (-not (Get-Command -Name Dismount-DiskImage -ErrorAction SilentlyContinue)) {
        throw 'Dismount-DiskImage is not available on this system.'
    }
}

function Assert-PowerCliPythonConfiguration {
    $vcfPowerCliModule = Get-Module -ListAvailable -Name VCF.PowerCLI | Select-Object -First 1
    $vmwarePowerCliModule = Get-Module -ListAvailable -Name VMware.PowerCLI | Select-Object -First 1
    
    $moduleToLoad = $null
    if ($vcfPowerCliModule) {
        $moduleToLoad = 'VCF.PowerCLI'
    }
    elseif ($vmwarePowerCliModule) {
        $moduleToLoad = 'VMware.PowerCLI'
    }
    else {
        throw 'Neither VCF.PowerCLI nor VMware.PowerCLI module is installed. Install one of these modules before running this script.'
    }

    Write-Host "Loading $moduleToLoad module..."
    Import-Module -Name $moduleToLoad -ErrorAction Stop

    $powerCliConfiguration = Get-PowerCLIConfiguration
    $pythonPathProperties = $powerCliConfiguration | Select-Object -Property PythonPath

    $configuredPythonPaths = @(
        $pythonPathProperties |
            ForEach-Object { $_.PythonPath } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($configuredPythonPaths.Count -eq 0) {
        throw 'PowerCLI PythonPath is not configured. Set it using Set-PowerCLIConfiguration -PythonPath <path> before running this script.'
    }

    $pythonPath = $configuredPythonPaths[0]
    if (-not (Test-Path -LiteralPath $pythonPath)) {
        throw "PowerCLI PythonPath does not exist: $pythonPath"
    }

    if ($configuredPythonPaths.Count -gt 1) {
        Write-Host "Multiple configured PowerCLI PythonPath values were found. Using: $pythonPath"
    }
    else {
        Write-Host "Verified PowerCLI PythonPath: $pythonPath"
    }
}

function Show-OpenFileDialog {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Filter,

        [string]$InitialDirectory
    )

    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = $Title
        $dialog.Filter = $Filter
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        $dialog.RestoreDirectory = $true

        if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
            $dialog.InitialDirectory = $InitialDirectory
        }

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw 'Operation cancelled by user.'
        }

        return $dialog.FileName
    }
    finally {
        $dialog.Dispose()
    }
}

function Show-FolderBrowserDialog {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [string]$SelectedPath
    )

    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $false

        if ($SelectedPath -and (Test-Path -LiteralPath $SelectedPath -PathType Container)) {
            $dialog.SelectedPath = $SelectedPath
        }

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw 'Operation cancelled by user.'
        }

        return $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
}

function Resolve-CanonicalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Mount-IsoImage {
    param(
        [Parameter(Mandatory)]
        [string]$IsoPath
    )

    Write-Host "Mounting ISO: $IsoPath"
    Mount-DiskImage -ImagePath $IsoPath | Out-Null

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $driveLetter = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
        if ($driveLetter) {
            return "$driveLetter`:"
        }

        Start-Sleep -Milliseconds 250
    }

    throw 'The ISO was mounted, but no drive letter became available.'
}


function Copy-SelectedZip {
    param(
        [Parameter(Mandatory)]
        [string]$SourceZipPath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $destinationZipPath = Join-Path -Path $WorkingDirectory -ChildPath ([System.IO.Path]::GetFileName($SourceZipPath))
    if (Test-Path -LiteralPath $destinationZipPath) {
        Write-Host "Using existing copied ZIP file in working directory: $destinationZipPath"
        return $destinationZipPath
    }

    Write-Host "Copying ZIP to working directory: $destinationZipPath"
    Copy-Item -LiteralPath $SourceZipPath -Destination $destinationZipPath
    return $destinationZipPath
}

function Move-ZipToWorkingDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$SourceZipPath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $sourceFullPath = Resolve-CanonicalPath -Path $SourceZipPath
    $workingDirectoryFullPath = Resolve-CanonicalPath -Path $WorkingDirectory
    $destinationZipPath = Join-Path -Path $workingDirectoryFullPath -ChildPath ([System.IO.Path]::GetFileName($sourceFullPath))

    if ($sourceFullPath.Equals($destinationZipPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "$Description is already in the working directory: $destinationZipPath"
        return $destinationZipPath
    }

    if (Test-Path -LiteralPath $destinationZipPath) {
        Write-Host "Using existing $Description in working directory: $destinationZipPath"
        return $destinationZipPath
    }

    Write-Host "Moving $Description to working directory: $destinationZipPath"
    Move-Item -LiteralPath $sourceFullPath -Destination $destinationZipPath
    return $destinationZipPath
}

function Select-DepotZip {
    param(
        [Parameter(Mandatory)]
        [string]$InitialDirectory
    )

    return Show-OpenFileDialog -Title 'Select the VMware depot ZIP file' -Filter 'ZIP files (*.zip)|*.zip' -InitialDirectory $InitialDirectory
}

function Select-BaseImageVersion {
    param(
        [Parameter(Mandatory)]
        [string[]]$AvailableVersions
    )

    $uniqueVersions = @(
        $AvailableVersions |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($uniqueVersions.Count -eq 0) {
        throw 'No base image versions were returned by Get-DepotBaseImages.'
    }

    if ($uniqueVersions.Count -eq 1) {
        $selectedVersion = $uniqueVersions[0]
        Write-Host "Selected base image version: $selectedVersion"
        return $selectedVersion
    }

    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        for ($index = 0; $index -lt $uniqueVersions.Count; $index++) {
            $choiceNumber = $index + 1
            $version = $uniqueVersions[$index]
            [System.Management.Automation.Host.ChoiceDescription]::new("&$choiceNumber $version", "Use base image version $version")
        }
    )

    $selection = $Host.UI.PromptForChoice(
        'Base image version selection',
        'Select the VMware base image version to use.',
        $choices,
        0
    )

    $selectedVersion = $uniqueVersions[$selection]
    Write-Host "Selected base image version: $selectedVersion"
    return $selectedVersion
}

function Get-SelectedDepotBaseImageVersion {
    param(
        [Parameter(Mandatory)]
        [string]$DepotZipPath
    )

    Write-Host "Reading base image versions from depot ZIP: $DepotZipPath"
    $baseImageVersions = @((Get-DepotBaseImages $DepotZipPath).Version)
    return Select-BaseImageVersion -AvailableVersions $baseImageVersions
}

function New-PatchDefinitionFile {
    param(
        [Parameter(Mandatory)]
        [string]$ExtractedMetadataJsonPath,

        [Parameter(Mandatory)]
        [string]$BaseImageVersion,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $patchDefinitionPath = Join-Path -Path $WorkingDirectory -ChildPath 'SynergyPatch-softwarespec.json'

    $metadata = Get-Content -LiteralPath $ExtractedMetadataJsonPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $metadata.ContainsKey('components')) {
        throw "The extracted metadata JSON does not contain a components object: $ExtractedMetadataJsonPath"
    }

    $patchDefinition = [ordered]@{
        base_image = [ordered]@{
            version = $BaseImageVersion
        }
        components = $metadata.components
    }

    Write-Host "Writing patch definition file: $patchDefinitionPath"
    $patchDefinition | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $patchDefinitionPath -Encoding utf8
    return $patchDefinitionPath
}

function Get-HardwareSupportPackageVersion {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestJsonPath
    )

    $manifest = Get-Content -LiteralPath $ManifestJsonPath -Raw | ConvertFrom-Json -AsHashtable

    if (-not $manifest.ContainsKey('hardwareSupportInfo')) {
        throw "The metadata JSON does not contain hardwareSupportInfo: $ManifestJsonPath"
    }

    $hardwareSupportInfo = $manifest.hardwareSupportInfo
    if (-not ($hardwareSupportInfo -is [System.Collections.IDictionary]) -or -not $hardwareSupportInfo.Contains('package')) {
        throw "The metadata JSON does not contain hardwareSupportInfo.package: $ManifestJsonPath"
    }

    $package = $hardwareSupportInfo.package
    if (-not ($package -is [System.Collections.IDictionary]) -or -not $package.Contains('version')) {
        throw "The metadata JSON does not contain hardwareSupportInfo.package.version: $ManifestJsonPath"
    }

    $packageVersion = [string]$package.version
    if ([string]::IsNullOrWhiteSpace($packageVersion)) {
        throw "hardwareSupportInfo.package.version is empty in: $ManifestJsonPath"
    }

    return $packageVersion
}

function Get-RootMetadataZipEntry {
    param(
        [Parameter(Mandatory)]
        [System.IO.Compression.ZipArchive]$Archive
    )

    $entries = @(
        $Archive.Entries |
            Where-Object {
                $_.Name -like '*metadata.zip' -and
                $_.FullName -notmatch '[\\/].+[\\/]'
            }
    )

    $rootEntries = @(
        $entries |
            Where-Object {
                $_.FullName -eq $_.Name
            }
    )

    if ($rootEntries.Count -eq 0) {
        throw 'No root-level entry ending with metadata.zip was found in the selected ZIP file.'
    }

    if ($rootEntries.Count -gt 1) {
        $names = $rootEntries.FullName -join ', '
        throw "Multiple root-level metadata ZIP files were found: $names"
    }

    return $rootEntries[0]
}

function Expand-MetadataJson {
    param(
        [Parameter(Mandatory)]
        [string]$OuterZipPath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $temporaryMetadataZipPath = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ('metadata-{0}.zip' -f [System.Guid]::NewGuid().ToString('N'))
    )

    try {
        $outerArchive = [System.IO.Compression.ZipFile]::OpenRead($OuterZipPath)
        try {
            $metadataEntry = Get-RootMetadataZipEntry -Archive $outerArchive
            Write-Host "Extracting nested metadata archive: $($metadataEntry.FullName)"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($metadataEntry, $temporaryMetadataZipPath, $true)
        }
        finally {
            $outerArchive.Dispose()
        }

        $metadataArchive = [System.IO.Compression.ZipFile]::OpenRead($temporaryMetadataZipPath)
        try {
            $jsonEntries = @(
                $metadataArchive.Entries |
                    Where-Object {
                        $_.FullName -match '^(?i)manifests/.+\.json$'
                    }
            )

            if ($jsonEntries.Count -eq 0) {
                throw 'No JSON file was found under manifests/ in the metadata ZIP.'
            }

            if ($jsonEntries.Count -gt 1) {
                $names = $jsonEntries.FullName -join ', '
                throw "Multiple JSON files were found under manifests/: $names"
            }

            $jsonEntry = $jsonEntries[0]
            $destinationJsonPath = Join-Path -Path $WorkingDirectory -ChildPath ([System.IO.Path]::GetFileName($jsonEntry.Name))
            if (Test-Path -LiteralPath $destinationJsonPath) {
                Write-Host "Using existing extracted JSON file in working directory: $destinationJsonPath"
                return $destinationJsonPath
            }

            Write-Host "Extracting JSON to working directory: $destinationJsonPath"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($jsonEntry, $destinationJsonPath, $true)
            return $destinationJsonPath
        }
        finally {
            $metadataArchive.Dispose()
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryMetadataZipPath) {
            Remove-Item -LiteralPath $temporaryMetadataZipPath -Force
        }
    }
}

function Select-ZipFromMountedIso {
    param(
        [Parameter(Mandatory)]
        [string]$MountedIsoRoot
    )

    $manifestDirectory = Join-Path -Path $MountedIsoRoot -ChildPath 'manifest\vmw'
    if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
        throw "The mounted ISO does not contain the expected directory: $manifestDirectory"
    }

    $selectedZip = Show-OpenFileDialog -Title 'Select the ZIP file from manifest\vmw' -Filter 'ZIP files (*.zip)|*.zip' -InitialDirectory $manifestDirectory
    $manifestItem = Get-Item -LiteralPath $manifestDirectory
    $selectedItem = Get-Item -LiteralPath $selectedZip
    $selectedDirectory = $selectedItem.Directory
    $selectionIsUnderManifestDirectory = $false

    while ($selectedDirectory) {
        if ($selectedDirectory.FullName.Equals($manifestItem.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $selectionIsUnderManifestDirectory = $true
            break
        }

        $selectedDirectory = $selectedDirectory.Parent
    }

    if (-not $selectionIsUnderManifestDirectory) {
        throw "The selected ZIP must be inside $manifestDirectory"
    }

    return $selectedItem.FullName
}

function Main {
    Assert-Environment
    Assert-PowerCliPythonConfiguration

    $scriptDirectory = if ($PSScriptRoot) {
        $PSScriptRoot
    }
    else {
        Split-Path -Path $PSCommandPath -Parent
    }

    $scriptDirectory = Resolve-CanonicalPath -Path $scriptDirectory
    $depotZipPath = Select-DepotZip -InitialDirectory $scriptDirectory
    $isoPath = Show-OpenFileDialog -Title 'Select the Synergy SSP ISO file' -Filter 'ISO files (*.iso)|*.iso'
    $mountedIsoRoot = $null

    try {
        $mountedIsoRoot = Mount-IsoImage -IsoPath $isoPath
        Write-Host "Mounted ISO root: $mountedIsoRoot"

        $selectedZipPath = Select-ZipFromMountedIso -MountedIsoRoot $mountedIsoRoot
        Write-Host "Selected ZIP from mounted ISO: $selectedZipPath"

        $workingDirectory = $scriptDirectory
        Write-Host "Working directory: $workingDirectory"
        $workingDepotZipPath = Move-ZipToWorkingDirectory -SourceZipPath $depotZipPath -WorkingDirectory $workingDirectory -Description 'selected VMware depot ZIP file'
        $selectedBaseImageVersion = Get-SelectedDepotBaseImageVersion -DepotZipPath $workingDepotZipPath

        $copiedZipPath = Copy-SelectedZip -SourceZipPath $selectedZipPath -WorkingDirectory $workingDirectory
        $extractedJsonPath = Expand-MetadataJson -OuterZipPath $copiedZipPath -WorkingDirectory $workingDirectory
        $patchDefinitionPath = New-PatchDefinitionFile -ExtractedMetadataJsonPath $extractedJsonPath -BaseImageVersion $selectedBaseImageVersion -WorkingDirectory $workingDirectory

        $hardwareSupportPackageVersion = Get-HardwareSupportPackageVersion -ManifestJsonPath $extractedJsonPath
        $newOfflineBundlePath = Join-Path -Path $workingDirectory -ChildPath ("{0}-depot.zip" -f $hardwareSupportPackageVersion)

        Write-Host "Creating new ESXi offline bundle: $newOfflineBundlePath"
        New-OfflineBundle `
            -Depots ($workingDepotZipPath, $copiedZipPath) `
            -VendorName 'HPE' `
            -VendorCode 'HEP' `
            -SoftwareSpec $patchDefinitionPath `
            -Destination $newOfflineBundlePath

        Write-Host ''
        Write-Host 'Completed successfully.'
        Write-Host "Depot ZIP: $workingDepotZipPath"
        Write-Host "Selected base image version: $selectedBaseImageVersion"
        Write-Host "Copied ZIP: $copiedZipPath"
        Write-Host "Extracted JSON: $extractedJsonPath"
        Write-Host "Patch definition JSON: $patchDefinitionPath"
        Write-Host "New offline bundle: $newOfflineBundlePath"
    }
    finally {
        if ($mountedIsoRoot -and (Test-Path -LiteralPath $mountedIsoRoot)) {
            Write-Host "Dismounting ISO: $isoPath"
            Dismount-DiskImage -ImagePath $isoPath | Out-Null
        }
    }
}

Main