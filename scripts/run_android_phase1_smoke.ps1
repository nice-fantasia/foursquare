<#
.SYNOPSIS
    Runs the destructive Phase 1 Android smoke test on its dedicated AVD.

.DESCRIPTION
    Verifies that the selected adb target is the expected Android emulator and
    AVD before allowing the Flutter integration test to clear application data.

.PARAMETER DeviceId
    The adb/Flutter device ID for the already running dedicated AVD.

.PARAMETER AvdName
    The exact AVD name returned by ro.boot.qemu.avd_name.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$DeviceId = 'emulator-5554',

    [Parameter(Mandatory = $false)]
    [string]$AvdName = 'Foursquare_API_34_x86_64'
)

$ErrorActionPreference = 'Stop'

function Resolve-AdbPath {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($env:ANDROID_HOME) {
        $candidate = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'adb was not found in PATH or ANDROID_HOME.'
}

$adb = Resolve-AdbPath
$repositoryRoot = Split-Path -Parent $PSScriptRoot

$deviceState = (& $adb -s $DeviceId get-state 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $deviceState -ne 'device') {
    throw "Android device '$DeviceId' is not online."
}

$isEmulator = (& $adb -s $DeviceId shell getprop ro.kernel.qemu).Trim()
$actualAvdName = (& $adb -s $DeviceId shell getprop ro.boot.qemu.avd_name).Trim()
if ($isEmulator -ne '1' -or $actualAvdName -ne $AvdName) {
    throw "Refusing destructive smoke test: '$DeviceId' is '$actualAvdName' (qemu=$isEmulator), expected AVD '$AvdName'."
}

$originalNoProxy = $env:NO_PROXY
$env:NO_PROXY = (@($env:NO_PROXY, 'localhost', '127.0.0.1', '::1') |
    Where-Object { $_ } |
    ForEach-Object { $_.Trim(',') }) -join ','

Push-Location $repositoryRoot
try {
    & flutter test --no-pub integration_test/android_phase1_smoke_test.dart `
        -d $DeviceId `
        "--dart-define=ANDROID_SMOKE_DEVICE=$AvdName" `
        --timeout 10m `
        --reporter expanded
    if ($LASTEXITCODE -ne 0) {
        throw "Android Phase 1 smoke test failed with exit code $LASTEXITCODE."
    }
} finally {
    $env:NO_PROXY = $originalNoProxy
    Pop-Location
}
