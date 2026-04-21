param(
    [Parameter(Mandatory)]
    [string]$SynergySppIsoPath,

    [Parameter(Mandatory)]
    [string]$VmwareDepotZipPath,

    [string]$WorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-CanonicalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-Environment {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'This script requires PowerShell 7 or later.'
    }

    if (-not $IsWindows -and -not $IsLinux) {
        throw 'This script currently supports only Windows and Linux.'
    }

    if ($IsWindows) {
        if (-not (Get-Command -Name Mount-DiskImage -ErrorAction SilentlyContinue)) {
            throw 'Mount-DiskImage is not available on this system.'
        }

        if (-not (Get-Command -Name Dismount-DiskImage -ErrorAction SilentlyContinue)) {
            throw 'Dismount-DiskImage is not available on this system.'
        }
    }
    else {
        if (-not (Get-Command -Name mount -ErrorAction SilentlyContinue)) {
            throw 'mount command is not available on this Linux system.'
        }

        if (-not (Get-Command -Name umount -ErrorAction SilentlyContinue)) {
            throw 'umount command is not available on this Linux system.'
        }
    }
}

function Assert-ExistingFilePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description does not exist or is not a file: $Path"
    }
}

function Assert-FileExtension {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedExtension,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $actualExtension = [System.IO.Path]::GetExtension($Path)
    if (-not $actualExtension.Equals($ExpectedExtension, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must have extension '$ExpectedExtension': $Path"
    }
}

function Assert-ExistingDirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description does not exist or is not a directory: $Path"
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

    $configuredPythonPath = $configuredPythonPaths[0]
    $resolvedPythonCommand = $null

    if (Test-Path -LiteralPath $configuredPythonPath -PathType Leaf) {
        $resolvedPythonCommand = Resolve-CanonicalPath -Path $configuredPythonPath
    }
    else {
        $pythonCommand = Get-Command -Name $configuredPythonPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pythonCommand) {
            throw "PowerCLI PythonPath does not exist and is not resolvable as a command: $configuredPythonPath"
        }

        $resolvedPythonCommand = $pythonCommand.Source
    }

    if ($configuredPythonPaths.Count -gt 1) {
        Write-Host "Multiple configured PowerCLI PythonPath values were found. Using: $configuredPythonPath"
    }
    else {
        Write-Host "Verified PowerCLI PythonPath: $configuredPythonPath"
    }

    $requiredPythonPackages = [ordered]@{
        six       = 'six'
        psutil    = 'psutil'
        lxml      = 'lxml'
        pyopenssl = 'OpenSSL'
    }

    $missingPythonPackages = [System.Collections.Generic.List[string]]::new()
    foreach ($packageName in $requiredPythonPackages.Keys) {
        $moduleName = $requiredPythonPackages[$packageName]
        $importCheck = "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$moduleName') is not None else 1)"

        & $resolvedPythonCommand -c $importCheck 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $missingPythonPackages.Add($packageName)
        }
    }

    if ($missingPythonPackages.Count -gt 0) {
        $missingList = $missingPythonPackages -join ', '
        throw "Required Python packages are missing for PowerCLI: $missingList. Install them with: `"$resolvedPythonCommand`" -m pip install $missingList"
    }

    Write-Host 'Verified required Python packages: six, psutil, lxml, pyopenssl'
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        $joinedArguments = $Arguments -join ' '
        throw "Command failed: $Command $joinedArguments"
    }
}

function Mount-IsoImage {
    param(
        [Parameter(Mandatory)]
        [string]$IsoPath
    )

    if ($IsWindows) {
        Write-Host "Mounting ISO on Windows: $IsoPath"
        Mount-DiskImage -ImagePath $IsoPath | Out-Null

        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $driveLetter = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
            if ($driveLetter) {
                return [ordered]@{
                    RootPath   = "$driveLetter`:"
                    MountPoint = $null
                    IsoPath    = $IsoPath
                    Platform   = 'Windows'
                }
            }

            Start-Sleep -Milliseconds 250
        }

        throw 'The ISO was mounted, but no drive letter became available.'
    }

    $mountPoint = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("synergy-iso-{0}" -f [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $mountPoint | Out-Null

    $isRoot = ((id -u) -eq '0')
    Write-Host "Mounting ISO on Linux: $IsoPath -> $mountPoint"

    if ($isRoot) {
        Invoke-NativeCommand -Command 'mount' -Arguments @('-o', 'loop', '--', $IsoPath, $mountPoint)
    }
    else {
        if (-not (Get-Command -Name sudo -ErrorAction SilentlyContinue)) {
            throw 'Mounting ISO on Linux requires root privileges or sudo.'
        }

        Invoke-NativeCommand -Command 'sudo' -Arguments @('mount', '-o', 'loop', '--', $IsoPath, $mountPoint)
    }

    return [ordered]@{
        RootPath   = $mountPoint
        MountPoint = $mountPoint
        IsoPath    = $IsoPath
        Platform   = 'Linux'
    }
}

function Dismount-IsoImage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$MountInfo
    )

    if ($MountInfo.Platform -eq 'Windows') {
        if (Test-Path -LiteralPath $MountInfo.RootPath) {
            Write-Host "Dismounting ISO on Windows: $($MountInfo.IsoPath)"
            Dismount-DiskImage -ImagePath $MountInfo.IsoPath | Out-Null
        }

        return
    }

    if ($MountInfo.MountPoint -and (Test-Path -LiteralPath $MountInfo.MountPoint)) {
        $isRoot = ((id -u) -eq '0')
        Write-Host "Dismounting ISO on Linux: $($MountInfo.MountPoint)"

        if ($isRoot) {
            Invoke-NativeCommand -Command 'umount' -Arguments @('--', $MountInfo.MountPoint)
        }
        else {
            Invoke-NativeCommand -Command 'sudo' -Arguments @('umount', '--', $MountInfo.MountPoint)
        }

        Remove-Item -LiteralPath $MountInfo.MountPoint -Force
    }
}

function Prompt-SelectionFromList {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string[]]$Items
    )

    if ($Items.Count -eq 0) {
        throw "No selectable items were provided for: $Title"
    }

    Write-Host ''
    Write-Host $Title
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $itemNumber = $index + 1
        Write-Host ("[{0}] {1}" -f $itemNumber, $Items[$index])
    }

    while ($true) {
        $response = Read-Host "Enter selection number (1-$($Items.Count))"
        $selectionNumber = 0

        if ([int]::TryParse($response, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $Items.Count) {
            return $Items[$selectionNumber - 1]
        }

        Write-Host 'Invalid selection. Please try again.'
    }
}

function Select-ZipFromMountedIso {
    param(
        [Parameter(Mandatory)]
        [string]$MountedIsoRoot
    )

    $manifestDirectory = Join-Path -Path $MountedIsoRoot -ChildPath 'manifest/vmw'
    if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
        throw "The mounted ISO does not contain the expected directory: $manifestDirectory"
    }

    $zipFiles = @(
        Get-ChildItem -LiteralPath $manifestDirectory -Filter '*.zip' -File -Recurse |
            Select-Object -ExpandProperty FullName |
            Sort-Object
    )

    if ($zipFiles.Count -eq 0) {
        throw "No ZIP files were found under: $manifestDirectory"
    }

    if ($zipFiles.Count -eq 1) {
        Write-Host "Selected ZIP from mounted ISO: $($zipFiles[0])"
        return $zipFiles[0]
    }

    return Prompt-SelectionFromList -Title 'Select the ZIP file from manifest/vmw:' -Items $zipFiles
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

function Copy-ZipToWorkingDirectory {
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

    Write-Host "Copying $Description to working directory: $destinationZipPath"
    Copy-Item -LiteralPath $sourceFullPath -Destination $destinationZipPath
    return $destinationZipPath
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

    $selectedVersion = Prompt-SelectionFromList -Title 'Select the VMware base image version:' -Items $uniqueVersions
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

function Get-CloneImageProfileName {
    param(
        [Parameter(Mandatory)]
        [string]$SelectedBaseImageVersion
    )

    $matchingProfiles = @(
        Get-EsxImageProfile |
            Where-Object {
                $_.Name -like "*$SelectedBaseImageVersion*"
            } |
            Select-Object -ExpandProperty Name -Unique
    )

    if ($matchingProfiles.Count -eq 0) {
        throw "No image profile name was found for base image version: $SelectedBaseImageVersion"
    }

    if ($matchingProfiles.Count -eq 1) {
        return $matchingProfiles[0]
    }

    return Prompt-SelectionFromList -Title 'Select the source image profile to clone:' -Items $matchingProfiles
}

function Main {
    Assert-Environment
    Assert-PowerCliPythonConfiguration

    $resolvedIsoPath = Resolve-CanonicalPath -Path $SynergySppIsoPath
    $resolvedDepotZipPath = Resolve-CanonicalPath -Path $VmwareDepotZipPath

    Assert-FileExtension -Path $resolvedIsoPath -ExpectedExtension '.iso' -Description 'Synergy ISO file'
    Assert-FileExtension -Path $resolvedDepotZipPath -ExpectedExtension '.zip' -Description 'VMware depot ZIP file'

    Assert-ExistingFilePath -Path $resolvedIsoPath -Description 'Synergy ISO file'
    Assert-ExistingFilePath -Path $resolvedDepotZipPath -Description 'VMware depot ZIP file'

    $scriptDirectory = if ($PSScriptRoot) {
        $PSScriptRoot
    }
    else {
        Split-Path -Path $PSCommandPath -Parent
    }

    $workingDirectoryPath = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        Resolve-CanonicalPath -Path $scriptDirectory
    }
    else {
        Resolve-CanonicalPath -Path $WorkingDirectory
    }

    if (-not (Test-Path -LiteralPath $workingDirectoryPath)) {
        New-Item -ItemType Directory -Path $workingDirectoryPath | Out-Null
    }

    Assert-ExistingDirectoryPath -Path $workingDirectoryPath -Description 'Working directory'

    $mountInfo = $null

    try {
        $mountInfo = Mount-IsoImage -IsoPath $resolvedIsoPath
        Write-Host "Mounted ISO root: $($mountInfo.RootPath)"

        $selectedZipPath = Select-ZipFromMountedIso -MountedIsoRoot $mountInfo.RootPath
        Write-Host "Selected ZIP from mounted ISO: $selectedZipPath"

        Write-Host "Working directory: $workingDirectoryPath"
        $workingDepotZipPath = Copy-ZipToWorkingDirectory -SourceZipPath $resolvedDepotZipPath -WorkingDirectory $workingDirectoryPath -Description 'selected VMware depot ZIP file'
        $selectedBaseImageVersion = Get-SelectedDepotBaseImageVersion -DepotZipPath $workingDepotZipPath

        $copiedZipPath = Copy-SelectedZip -SourceZipPath $selectedZipPath -WorkingDirectory $workingDirectoryPath
        $extractedJsonPath = Expand-MetadataJson -OuterZipPath $copiedZipPath -WorkingDirectory $workingDirectoryPath
        $patchDefinitionPath = New-PatchDefinitionFile -ExtractedMetadataJsonPath $extractedJsonPath -BaseImageVersion $selectedBaseImageVersion -WorkingDirectory $workingDirectoryPath

        $hardwareSupportPackageVersion = Get-HardwareSupportPackageVersion -ManifestJsonPath $extractedJsonPath
        $newOfflineBundlePath = Join-Path -Path $workingDirectoryPath -ChildPath ("{0}-depot.zip" -f $hardwareSupportPackageVersion)

        Write-Host "Creating new ESXi offline bundle: $newOfflineBundlePath"
        New-OfflineBundle `
            -Depots ($workingDepotZipPath, $copiedZipPath) `
            -VendorName 'HPE' `
            -VendorCode 'HEP' `
            -SoftwareSpec $patchDefinitionPath `
            -Destination $newOfflineBundlePath

        Write-Host "Adding bundle to software depot: $newOfflineBundlePath"
        Add-EsxSoftwareDepot $newOfflineBundlePath | Out-Null

        Write-Host "Creating new image profile based on $selectedBaseImageVersion with HPE SSP patch"
        $cloneProfileName = Get-CloneImageProfileName -SelectedBaseImageVersion $selectedBaseImageVersion
        $baseImageBuild = $cloneProfileName.Split('.')[-1]
        $newImageProfile = "HPE-$hardwareSupportPackageVersion-$baseImageBuild"

        New-EsxImageProfile -CloneProfile $cloneProfileName -Name $newImageProfile -Vendor 'HPE' | Out-Null

        $newImageProfileIsoPath = Join-Path -Path $workingDirectoryPath -ChildPath ("{0}.iso" -f $newImageProfile)
        $newImageProfileBundlePath = Join-Path -Path $workingDirectoryPath -ChildPath ("{0}-depot.zip" -f $newImageProfile)

        Export-EsxImageProfile -ImageProfile $newImageProfile -ExportToIso -FilePath $newImageProfileIsoPath
        Export-EsxImageProfile -ImageProfile $newImageProfile -ExportToBundle -FilePath $newImageProfileBundlePath

        Write-Host ''
        Write-Host 'Completed successfully.'
        Write-Host "Depot ZIP: $workingDepotZipPath"
        Write-Host "Selected base image version: $selectedBaseImageVersion"
        Write-Host "Copied ZIP: $copiedZipPath"
        Write-Host "Extracted JSON: $extractedJsonPath"
        Write-Host "Patch definition JSON: $patchDefinitionPath"
        Write-Host "New offline bundle: $newOfflineBundlePath"
        Write-Host "Clone profile used: $cloneProfileName"
        Write-Host "New image profile name: $newImageProfile"
        Write-Host "New image profile ISO: $newImageProfileIsoPath"
        Write-Host "New image profile depot ZIP: $newImageProfileBundlePath"
    }
    finally {
        if ($mountInfo) {
            Dismount-IsoImage -MountInfo $mountInfo
        }
    }
}

Main
