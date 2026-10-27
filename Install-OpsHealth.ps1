# Run in Windows PowerShell ISE as Administrator.
# Change the task name and schedule here if needed.

$TaskName = 'OpsHealth-Daily'
$RunAt = '07:00'
$InstallDir = Join-Path $env:ProgramFiles 'OpsHealth'

$ErrorActionPreference = 'Stop'

# Confirm administrator privileges.
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)

if (-not $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'Open PowerShell ISE using Run as administrator.'
}

# Avoid replacing an existing task or installation.
if (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue) {
    throw "Task '$TaskName' already exists. Choose another task name."
}

if (Test-Path -LiteralPath $InstallDir) {
    throw "Folder '$InstallDir' already exists. Choose a new installation folder."
}

# Create a protected folder because the task will run as SYSTEM.
New-Item -Path $InstallDir -ItemType Directory | Out-Null

$Acl = [System.Security.AccessControl.DirectorySecurity]::new()
$Acl.SetAccessRuleProtection($true, $false)

$Administrators = [Security.Principal.SecurityIdentifier]::new(
    'S-1-5-32-544'
)
$Acl.SetOwner($Administrators)

foreach ($Sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($Sid),
        'FullControl',
        'ContainerInherit, ObjectInherit',
        'None',
        'Allow'
    )
    $Acl.AddAccessRule($Rule)
}

Set-Acl -LiteralPath $InstallDir -AclObject $Acl

$ScriptPath = Join-Path $InstallDir 'Get-ServerHealth.ps1'
$ReportDir = Join-Path $InstallDir 'Reports'

New-Item -Path $ReportDir -ItemType Directory | Out-Null

# Single quotes preserve variables for the saved script.
$ReportScript = @'
$ErrorActionPreference = 'Stop'

function Invoke-HealthCheck {
    param([scriptblock]$Action)

    try {
        [pscustomobject]@{
            Succeeded = $true
            Data      = @(& $Action)
            Error     = $null
        }
    }
    catch {
        [pscustomobject]@{
            Succeeded = $false
            Data      = @()
            Error     = $_.Exception.Message
        }
    }
}

try {
    $ReportDir = Join-Path $PSScriptRoot 'Reports'

    $Report = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        CollectedAt  = (Get-Date).ToString('o')
        Checks       = [ordered]@{}
    }

    $Report.Checks.OperatingSystem = Invoke-HealthCheck {
        $OS = Get-CimInstance -ClassName Win32_OperatingSystem

        [pscustomobject]@{
            OperatingSystem = $OS.Caption
            Version         = $OS.Version
            LastBoot        = $OS.LastBootUpTime
            UptimeHours     = [math]::Round(
                ((Get-Date) - $OS.LastBootUpTime).TotalHours, 1
            )
            TotalMemoryGB   = [math]::Round(
                $OS.TotalVisibleMemorySize / 1MB, 2
            )
            FreeMemoryGB    = [math]::Round(
                $OS.FreePhysicalMemory / 1MB, 2
            )
        }
    }

    $Report.Checks.Disks = Invoke-HealthCheck {
        Get-CimInstance -ClassName Win32_LogicalDisk `
            -Filter 'DriveType=3' |
        Where-Object { $_.Size -gt 0 } |
        ForEach-Object {
            $FreePercent = 100 * $_.FreeSpace / $_.Size

            [pscustomobject]@{
                Drive       = $_.DeviceID
                SizeGB      = [math]::Round($_.Size / 1GB, 2)
                FreeGB      = [math]::Round($_.FreeSpace / 1GB, 2)
                FreePercent = [math]::Round($FreePercent, 1)
                Below15Pct  = ($FreePercent -lt 15)
            }
        }
    }

    # These are review items: some automatic services stop normally.
    $Report.Checks.StoppedAutomaticServices = Invoke-HealthCheck {
        Get-CimInstance -ClassName Win32_Service `
            -Filter "StartMode='Auto' AND State<>'Running'" |
        Select-Object Name, DisplayName, State, StartMode
    }

    $Report.Checks.RecentSystemErrors = Invoke-HealthCheck {
        try {
            Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Level     = @(1, 2)
                StartTime = (Get-Date).AddHours(-24)
            } -MaxEvents 100 -ErrorAction Stop |
            Select-Object TimeCreated, Id, ProviderName,
                LevelDisplayName, Message
        }
        catch {
            # An empty event search is a successful check.
            if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                throw
            }
        }
    }

    $FileName = '{0}-{1}.json' -f (
        $env:COMPUTERNAME,
        (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    )

    $OutputPath = Join-Path $ReportDir $FileName

    $Report |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $OutputPath -Encoding UTF8

    Write-Output "Report saved: $OutputPath"

    $FailedChecks = @(
        $Report.Checks.Values |
        Where-Object { -not $_.Succeeded }
    )

    if ($FailedChecks.Count -gt 0) {
        throw 'Some checks failed. Review the Error fields in the report.'
    }

    exit 0
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
'@

Set-Content -LiteralPath $ScriptPath `
    -Value $ReportScript -Encoding UTF8

$PowerShellExe = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

# Test collection before registering the task.
& $PowerShellExe -NoProfile -NonInteractive -File $ScriptPath

if ($LASTEXITCODE -ne 0) {
    throw "Report test failed. Review the output and reports in '$ReportDir'."
}

$Action = New-ScheduledTaskAction `
    -Execute $PowerShellExe `
    -Argument ('-NoProfile -NonInteractive -File "{0}"' -f $ScriptPath) `
    -WorkingDirectory $InstallDir

$Trigger = New-ScheduledTaskTrigger -Daily -At $RunAt

$TaskPrincipal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath '\' `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $TaskPrincipal `
    -Settings $Settings `
    -Description 'Daily local Windows Server health report.' |
    Out-Null

Write-Host "Task created: $TaskName" -ForegroundColor Green
Write-Host "Daily schedule: $RunAt local time"
Write-Host "Reports: $ReportDir"
