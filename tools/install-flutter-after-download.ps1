$ErrorActionPreference = 'Stop'

$archive = 'D:\tmp\flutter_windows_3.44.8-stable.zip'
$expectedLength = 1901326708
$expectedSha256 = '095C108A08E0377D8A6501FED65AEB288908A070ED3F135E525DC6431C7686E4'
$installRoot = 'D:\tools'
$flutterRoot = Join-Path $installRoot 'flutter'
$doctorOutput = 'D:\tmp\flutter_doctor.txt'
$deadline = [DateTime]::UtcNow.AddHours(2)

while ((-not (Test-Path -LiteralPath $archive)) -or ((Get-Item -LiteralPath $archive).Length -lt $expectedLength)) {
    if ([DateTime]::UtcNow -gt $deadline) {
        throw 'Timed out waiting for the Flutter SDK archive.'
    }
    Start-Sleep -Seconds 30
}

$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($hash -ne $expectedSha256) {
    throw "Flutter SDK SHA-256 mismatch. Expected $expectedSha256, got $hash."
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot 'bin\flutter.bat'))) {
    Expand-Archive -LiteralPath $archive -DestinationPath $installRoot -Force
}

$flutterBin = Join-Path $flutterRoot 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @($userPath -split ';' | Where-Object { $_ })
if ($pathParts -notcontains $flutterBin) {
    [Environment]::SetEnvironmentVariable('Path', (($pathParts + $flutterBin) -join ';'), 'User')
}

& (Join-Path $flutterBin 'flutter.bat') config --enable-windows-desktop
& (Join-Path $flutterBin 'flutter.bat') doctor -v | Tee-Object -FilePath $doctorOutput
