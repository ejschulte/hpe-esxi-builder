# HPE ESXi Builder

This repository contains two PowerShell scripts for building patch bundles and ESXi ISO files that combine Synergy SPP artifacts with ESXi builds.

There are two scripts provided:
1. `build-hpe-synergy-esxiupdate-crossplatform.ps1` for both Windows and Linux
2. `build-hpe-synergy-esxiupdate.ps1` for Windows only

## Prerequisites
1. Python 3.7 or greater
2. Python packages
    - six
    - psutil
    - lxml
    - pyopenssl
3. VCF.PowerCLI (VMware.PowerCLI tested also but is deprecated)

### Setting up your environment

**Windows**
1. Install Python
2. Install Python packages
    - `pip install six psutil lxml pyopenssl`
3. Install VCF.PowerCLI
	- Launch PowerShell as Administrator and execute `Install-Module VCF.PowerCLI`
4. Find the path to your Python executable
    - Launch cmd.exe and execute the command `where python`
5. Set the PythonPath for VCF.PowerCLI
	- `Set-PowerCLIConfiguration -PythonPath c:\path\to\python -Scope User`
6. Verify PythonPath by executing
	- `Get-PowerCLIConfiguration | Select-Object -Property PythonPath`
7. Download the VMware depot file and Synergy SPP ISO from the appropriate sources.

**Linux**
Python is usually pre-installed on Linux distributions.

1. Install PowerShell
    - `sudo snap install powershell --classic`
2. Install VCF.PowerCLI
    - `pwsh -Command Install-Module VCF.PowerCLI`
3. ***Recommended*** Create a virtual environment. This may require a support package to be installed.  
    - `python3 -m venv .venv`
4. Activate your virtual environment
    - `source .venv/bin/activate`
5. Install the required packages
    - `pip install six psutil lxml pyopenssl`
6. Find the Python path
    - `which python`
7. Set the PythonPath for VCF.PowerCLI
	- `pwsh -Command Set-PowerCLIConfiguration -PythonPath /path/to/venv/python -Scope User`
8. Verify PythonPath by executing
	- `pwsh -Command Get-PowerCLIConfiguration | Select-Object -Property PythonPath`
9. Download the VMware depot file and Synergy SPP ISO from the appropriate sources.

## What do these scripts do?

Automates the creation of a patched ESXi image profile and exports artifacts from an HPE Synergy SPP ISO and a VMware depot ZIP.

In brief:

- Validates runtime prerequisites (PowerShell 7+, supported OS, mount tooling, PowerCLI module, configured Python path, and required Python packages).
- Validates and resolves input paths for the Synergy ISO, VMware depot ZIP, and working directory.
- Mounts the ISO (Windows or Linux), locates ZIP payloads under `manifest/vmw`, and lets you select one when multiple are available.
- Copies required ZIP files to the working directory and reads available VMware base image versions for selection.
- Extracts nested metadata from the selected HPE ZIP, reads hardware support package version info, and generates a software spec JSON patch file.
- Builds a new offline bundle via `New-OfflineBundle`, adds it to the software depot, clones an ESXi image profile, and names the new profile using HPE package/build metadata.
- Exports the new image profile to both ISO and offline bundle ZIP, prints output locations, and dismounts the ISO in cleanup.

## Cross-platform script usage

Run the script from PowerShell 7.

Parameters:

- `-SynergySppIsoPath` (mandatory): Path to the HPE Synergy SPP ISO file (`.iso`).
- `-VmwareDepotZipPath` (mandatory): Path to the VMware depot ZIP file (`.zip`).
- `-WorkingDirectory` (optional): Directory where intermediate and output files are written.

If `-WorkingDirectory` is not provided, the script uses the directory that contains `build-hpe-synergy-esxiupdate-crossplatform.ps1`.

### Examples

#### Windows Example

```powershell
pwsh ./build-hpe-synergy-esxiupdate-crossplatform.ps1 \
	-SynergySppIsoPath 'D:\ISOs\HPE_Synergy_SPP.iso' \
	-VmwareDepotZipPath 'D:\Depot\VMware-ESXi-depot.zip' \
	-WorkingDirectory 'D:\ESXi-Output'
```

#### Example Without WorkingDirectory

```powershell
pwsh ./build-hpe-synergy-esxiupdate-crossplatform.ps1 \
	-SynergySppIsoPath 'D:\ISOs\HPE_Synergy_SPP.iso' \
	-VmwareDepotZipPath 'D:\Depot\VMware-ESXi-depot.zip'
```

In this case, outputs are created in the script's folder.

#### Linux Example

```bash
pwsh ./build-hpe-synergy-esxiupdate-crossplatform.ps1 \
	-SynergySppIsoPath '/data/isos/HPE_Synergy_SPP.iso' \
	-VmwareDepotZipPath '/data/depot/VMware-ESXi-depot.zip' \
	-WorkingDirectory '/data/output'
```

The script may prompt you to select:

- A ZIP file from `manifest/vmw` inside the mounted ISO (if multiple are present)
- A VMware base image version (if multiple versions are available)

On success, it writes the generated offline bundle, profile ISO, and profile depot ZIP into the working directory and prints their paths.

## Windows-Only vs Cross-Platform Usage

User experience differences between `build-hpe-synergy-esxiupdate.ps1` and `build-hpe-synergy-esxiupdate-crossplatform.ps1`:

- Platform support:
    - Windows-only script runs only on Windows.
    - Cross-platform script runs on Windows and Linux.
- How inputs are provided:
    - Windows-only script is interactive with Windows file/folder dialogs. No input parameters.
    - Cross-platform script uses command-line parameters (`-SynergySppIsoPath`, `-VmwareDepotZipPath`, optional `-WorkingDirectory`).
- Interactivity style:
    - Windows-only script uses GUI dialogs plus a console choice prompt for base image version.
    - Cross-platform script uses console prompts only (ZIP selection and base image selection when multiple options exist).
- Working directory behavior:
    - Windows-only script always writes to the script directory.
    - Cross-platform script writes to `-WorkingDirectory` when provided; otherwise it also defaults to the script directory.
- Linux-specific behavior (cross-platform script):
    - Mount/umount operations may require root or `sudo`, so you can be prompted for elevation.

## Tested Environment

### Windows 11

**PowerShell**

| Property | Value |
| --- | --- |
| `PSVersion` | `7.6.0` |
| `PSEdition` | `Core` |
| `GitCommitId` | `7.6.0` |
| `OS` | `Microsoft Windows 10.0.26100` |
| `Platform` | `Win32NT` |
| `PSCompatibleVersions` | `1.0, 2.0, 3.0, 4.0, 5.0, 5.1, 6.0, 7.0` |
| `PSRemotingProtocolVersion` | `2.4` |
| `SerializationVersion` | `1.1.0.1` |
| `WSManStackVersion` | `3.0` |

VMware.PowerCLI 13.3.0.24145083

**Python** 3.12.10

**Python Packages**
| Package       | Version |
|---------------|---------|
| lxml          |   6.0.4 |
| psutil        |   7.2.2 |
| pyOpenSSL     |   26.0.0 |
| six           |   1.17.0 |

### Ubuntu Linux 24.04.1 LTS

**PowerShell**

| Property | Value |
| --- | --- |
| `PSVersion` | `7.6.0` |
| `PSEdition` | `Core` |
| `GitCommitId` | `7.6.0` |
| `OS` | `Ubuntu 24.04.1 LTS` |
| `Platform` | `Unix` |
| `PSCompatibleVersions` | `1.0, 2.0, 3.0, 4.0, 5.0, 5.1, 6.0, 7.0` |
| `PSRemotingProtocolVersion` | `2.4` |
| `SerializationVersion` | `1.1.0.1` |
| `WSManStackVersion` | `3.0` |

VCF.PowerCLI 9.0.0.24798382

**Python** 3.12.3

**Python Packages**
| Package       | Version |
|---------------|---------|
| lxml          |   6.1.0 |
| psutil        |   7.2.2 |
| pyOpenSSL     |   26.0.0 |
| six           |   1.17.0 |