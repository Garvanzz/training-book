[CmdletBinding()]
param()

$serviceName = 'training-book-postgresql-17'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`""
    )
    exit
}

Restart-Service -Name $serviceName -Force
Get-Service -Name $serviceName | Select-Object Name, Status, DisplayName
