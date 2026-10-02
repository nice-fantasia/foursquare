<#
.SYNOPSIS
    Runs the cached engineering checks for a Foursquare release candidate.

.DESCRIPTION
    Collects local environment evidence, validates Dart and Flutter sources,
    runs Flutter and server tests, builds a debug APK, and writes reproducible
    JSON/Markdown evidence under build\verification.

    The script never installs tools or packages. The destructive Android smoke
    test remains opt-in and retains the dedicated-AVD guard implemented by
    run_android_phase1_smoke.ps1.

.PARAMETER IncludeAndroidSmoke
    Runs the existing dedicated API 34 AVD smoke test after the cached checks.

.PARAMETER DeviceId
    Device ID passed to run_android_phase1_smoke.ps1 when smoke is enabled.

.PARAMETER AvdName
    Dedicated AVD name passed to run_android_phase1_smoke.ps1.

.PARAMETER Strict
    Treats a dirty Git worktree as a verification failure. The default records
    the worktree state as evidence without failing local engineering checks.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$IncludeAndroidSmoke,

    [Parameter(Mandatory = $false)]
    [string]$DeviceId = 'emulator-5554',

    [Parameter(Mandatory = $false)]
    [string]$AvdName = 'Foursquare_API_34_x86_64',

    [Parameter(Mandatory = $false)]
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-CommandLocation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    if ($command.Source) {
        return $command.Source
    }
    return $command.Path
}

function Add-LoopbackNoProxy {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$CurrentValue
    )

    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($CurrentValue, 'localhost', '127.0.0.1', '::1')) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        foreach ($part in $candidate.Split(',')) {
            $trimmed = $part.Trim()
            if ($trimmed -and -not $values.Contains($trimmed)) {
                [void]$values.Add($trimmed)
            }
        }
    }
    return $values -join ','
}

function Invoke-RecordedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $false)]
        [bool]$Required = $true
    )

    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $logPath = Join-Path $script:reportDirectory "$safeName.log"
    $lines = [System.Collections.Generic.List[string]]::new()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 1

    Write-Host "`n==> $Name"
    Push-Location $WorkingDirectory
    try {
        try {
            & $Command @Arguments 2>&1 | ForEach-Object {
                $line = $_.ToString()
                [void]$lines.Add($line)
                Write-Host $line
            }
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        } catch {
            [void]$lines.Add($_.Exception.Message)
            Write-Host $_.Exception.Message
            $exitCode = 1
        }
    } finally {
        Pop-Location
        $timer.Stop()
    }

    [System.IO.File]::WriteAllLines(
        $logPath,
        $lines,
        [System.Text.UTF8Encoding]::new($false)
    )

    $result = [pscustomobject][ordered]@{
        name = $Name
        command = (($Command, $Arguments) -join ' ').Trim()
        required = $Required
        success = ($exitCode -eq 0)
        exitCode = $exitCode
        durationMilliseconds = $timer.ElapsedMilliseconds
        logPath = $logPath
        testCounts = $null
        artifact = $null
    }
    [void]$script:steps.Add($result)
    return $result
}

function Get-FlutterTestCounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $passed = 0
    $failed = 0
    $skipped = 0
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ($null -eq $event) {
            continue
        }
        $typeProperty = $event.PSObject.Properties['type']
        $hiddenProperty = $event.PSObject.Properties['hidden']
        $skippedProperty = $event.PSObject.Properties['skipped']
        $resultProperty = $event.PSObject.Properties['result']
        if ($null -eq $typeProperty -or $typeProperty.Value -ne 'testDone') {
            continue
        }
        if ($null -ne $hiddenProperty -and [bool]$hiddenProperty.Value) {
            continue
        }
        if ($null -ne $skippedProperty -and [bool]$skippedProperty.Value) {
            $skipped++
        } elseif ($null -ne $resultProperty -and $resultProperty.Value -eq 'success') {
            $passed++
        } else {
            $failed++
        }
    }

    return [pscustomobject][ordered]@{
        passed = $passed
        failed = $failed
        skipped = $skipped
        total = $passed + $failed + $skipped
    }
}

function Get-NodeTestCounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $counts = [ordered]@{
        passed = 0
        failed = 0
        skipped = 0
        total = 0
    }
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        if ($line -match '^\s*# tests\s+(\d+)\s*$') {
            $counts.total = [int]$Matches[1]
        } elseif ($line -match '^\s*# pass\s+(\d+)\s*$') {
            $counts.passed = [int]$Matches[1]
        } elseif ($line -match '^\s*# fail\s+(\d+)\s*$') {
            $counts.failed = [int]$Matches[1]
        } elseif ($line -match '^\s*# skipped\s+(\d+)\s*$') {
            $counts.skipped = [int]$Matches[1]
        }
    }
    return [pscustomobject]$counts
}

function Get-RelativePathForReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootWithSeparator = $Root.TrimEnd('\') + '\'
    if ($Path.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($rootWithSeparator.Length)
    }
    return $Path
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$reportRoot = Join-Path $repositoryRoot 'build\verification'
$reportDirectory = Join-Path $reportRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
[void](New-Item -ItemType Directory -Path $reportDirectory -Force)

$steps = [System.Collections.Generic.List[object]]::new()
$originalNoProxy = $env:NO_PROXY
$effectiveNoProxy = Add-LoopbackNoProxy $originalNoProxy
$env:NO_PROXY = $effectiveNoProxy
$summaryWritten = $false
$summaryJsonPath = Join-Path $reportDirectory 'summary.json'
$summaryMarkdownPath = Join-Path $reportDirectory 'summary.md'
$artifactEvidence = $null
$flutterCounts = $null
$serverCounts = $null

try {
    $commandPaths = [ordered]@{}
    foreach ($commandName in @('git', 'dart', 'flutter', 'node', 'npm', 'java')) {
        $commandPaths[$commandName] = Get-CommandLocation $commandName
    }

    $gitVersion = Invoke-RecordedCommand `
        -Name 'diagnostic-git-version' `
        -Command 'git' `
        -Arguments @('--version') `
        -WorkingDirectory $repositoryRoot `
        -Required $false
    $flutterVersion = Invoke-RecordedCommand `
        -Name 'diagnostic-flutter-version' `
        -Command 'flutter' `
        -Arguments @('--version', '--machine') `
        -WorkingDirectory $repositoryRoot `
        -Required $false
    $dartVersion = Invoke-RecordedCommand `
        -Name 'diagnostic-dart-version' `
        -Command 'dart' `
        -Arguments @('--version') `
        -WorkingDirectory $repositoryRoot `
        -Required $false
    $nodeVersion = Invoke-RecordedCommand `
        -Name 'diagnostic-node-version' `
        -Command 'node' `
        -Arguments @('--version') `
        -WorkingDirectory $repositoryRoot `
        -Required $false
    $npmVersion = Invoke-RecordedCommand `
        -Name 'diagnostic-npm-version' `
        -Command 'npm' `
        -Arguments @('--version') `
        -WorkingDirectory $repositoryRoot `
        -Required $false
    $javaVersion = Invoke-RecordedCommand `
        -Name 'diagnostic-shell-java-version' `
        -Command 'java' `
        -Arguments @('-version') `
        -WorkingDirectory $repositoryRoot `
        -Required $false
    $flutterDoctor = Invoke-RecordedCommand `
        -Name 'diagnostic-flutter-doctor' `
        -Command 'flutter' `
        -Arguments @('doctor', '-v') `
        -WorkingDirectory $repositoryRoot `
        -Required $false

    $sdkRoot = $env:ANDROID_HOME
    $avdNames = @()
    $installedPlatforms = @()
    if (-not [string]::IsNullOrWhiteSpace($sdkRoot)) {
        $emulatorPath = Join-Path $sdkRoot 'emulator\emulator.exe'
        if (Test-Path -LiteralPath $emulatorPath) {
            $avdResult = Invoke-RecordedCommand `
                -Name 'diagnostic-android-avds' `
                -Command $emulatorPath `
                -Arguments @('-list-avds') `
                -WorkingDirectory $repositoryRoot `
                -Required $false
            $avdNames = @(
                Get-Content -LiteralPath $avdResult.logPath |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }

        $platformDirectory = Join-Path $sdkRoot 'platforms'
        if (Test-Path -LiteralPath $platformDirectory) {
            $installedPlatforms = @(
                Get-ChildItem -LiteralPath $platformDirectory -Directory |
                    Select-Object -ExpandProperty Name |
                    Sort-Object
            )
        }
    }

    $formatResult = Invoke-RecordedCommand `
        -Name 'dart-format-check' `
        -Command 'dart' `
        -Arguments @(
            'format',
            '--output=none',
            '--set-exit-if-changed',
            'lib',
            'test',
            'integration_test'
        ) `
        -WorkingDirectory $repositoryRoot

    $analyzeResult = Invoke-RecordedCommand `
        -Name 'flutter-analyze' `
        -Command 'flutter' `
        -Arguments @('analyze', '--no-pub') `
        -WorkingDirectory $repositoryRoot

    $flutterTestResult = Invoke-RecordedCommand `
        -Name 'flutter-tests' `
        -Command 'flutter' `
        -Arguments @('test', '--no-pub', '--machine') `
        -WorkingDirectory $repositoryRoot
    $flutterCounts = Get-FlutterTestCounts $flutterTestResult.logPath
    $flutterTestResult.testCounts = $flutterCounts

    $serverTestResult = Invoke-RecordedCommand `
        -Name 'server-tests-and-build' `
        -Command 'npm' `
        -Arguments @('test') `
        -WorkingDirectory (Join-Path $repositoryRoot 'server')
    $serverCounts = Get-NodeTestCounts $serverTestResult.logPath
    $serverTestResult.testCounts = $serverCounts

    $apkBuildResult = Invoke-RecordedCommand `
        -Name 'android-debug-apk' `
        -Command 'flutter' `
        -Arguments @('build', 'apk', '--debug', '--no-pub') `
        -WorkingDirectory $repositoryRoot

    $apkPath = Join-Path $repositoryRoot 'build\app\outputs\flutter-apk\app-debug.apk'
    if ($apkBuildResult.success -and (Test-Path -LiteralPath $apkPath)) {
        $apkFile = Get-Item -LiteralPath $apkPath
        $apkHash = Get-FileHash -LiteralPath $apkPath -Algorithm SHA256
        $artifactEvidence = [pscustomobject][ordered]@{
            path = $apkFile.FullName
            sizeBytes = $apkFile.Length
            sha256 = $apkHash.Hash
        }
        $apkBuildResult.artifact = $artifactEvidence
    } elseif ($apkBuildResult.success) {
        $apkBuildResult.success = $false
        $apkBuildResult.exitCode = 1
    }

    if ($IncludeAndroidSmoke) {
        $smokeResult = Invoke-RecordedCommand `
            -Name 'android-api34-smoke' `
            -Command (Join-Path $PSScriptRoot 'run_android_phase1_smoke.ps1') `
            -Arguments @('-DeviceId', $DeviceId, '-AvdName', $AvdName) `
            -WorkingDirectory $repositoryRoot
    }

    $commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
    $branch = (& git -C $repositoryRoot branch --show-current).Trim()
    $worktreeStatus = @(& git -C $repositoryRoot status --porcelain)
    $strictFailures = [System.Collections.Generic.List[string]]::new()
    if ($Strict -and $worktreeStatus.Count -gt 0) {
        [void]$strictFailures.Add('Git worktree is not clean.')
    }

    $requiredFailures = @(
        $steps | Where-Object { $_.required -and -not $_.success }
    )
    $success = $requiredFailures.Count -eq 0 -and $strictFailures.Count -eq 0

    $summary = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        repository = $repositoryRoot
        commit = $commit
        branch = $branch
        strict = [bool]$Strict
        includeAndroidSmoke = [bool]$IncludeAndroidSmoke
        success = $success
        workingTree = $worktreeStatus
        environment = [ordered]@{
            commandPaths = $commandPaths
            androidHome = $sdkRoot
            installedPlatforms = $installedPlatforms
            avdNames = $avdNames
            loopbackNoProxyApplied = @(
                'localhost',
                '127.0.0.1',
                '::1'
            ).Where({ $effectiveNoProxy.Split(',') -notcontains $_ }).Count -eq 0
            javaHome = $env:JAVA_HOME
            flutterDoctorLog = $flutterDoctor.logPath
        }
        testCounts = [ordered]@{
            flutter = $flutterCounts
            server = $serverCounts
        }
        artifact = $artifactEvidence
        strictFailures = $strictFailures
        steps = $steps
    }

    [System.IO.File]::WriteAllText(
        $summaryJsonPath,
        ($summary | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )

    $markdown = [System.Collections.Generic.List[string]]::new()
    [void]$markdown.Add('# Foursquare engineering verification')
    [void]$markdown.Add('')
    [void]$markdown.Add("- Generated (UTC): $($summary.generatedAtUtc)")
    [void]$markdown.Add("- Commit: ``$commit``")
    [void]$markdown.Add("- Branch: ``$branch``")
    [void]$markdown.Add("- Result: **$(if ($success) { 'PASS' } else { 'FAIL' })**")
    [void]$markdown.Add("- Android smoke: $(if ($IncludeAndroidSmoke) { 'included' } else { 'not requested' })")
    [void]$markdown.Add('')
    [void]$markdown.Add('## Steps')
    [void]$markdown.Add('')
    [void]$markdown.Add('| Step | Required | Result | Duration (ms) |')
    [void]$markdown.Add('|---|---:|---:|---:|')
    foreach ($step in $steps) {
        [void]$markdown.Add(
            "| $($step.name) | $($step.required) | $(if ($step.success) { 'PASS' } else { 'FAIL' }) | $($step.durationMilliseconds) |"
        )
    }
    [void]$markdown.Add('')
    [void]$markdown.Add('## Test counts')
    [void]$markdown.Add('')
    [void]$markdown.Add(
        "- Flutter: $($flutterCounts.passed) passed, $($flutterCounts.failed) failed, $($flutterCounts.skipped) skipped."
    )
    [void]$markdown.Add(
        "- Server: $($serverCounts.passed) passed, $($serverCounts.failed) failed, $($serverCounts.skipped) skipped."
    )
    if ($null -ne $artifactEvidence) {
        [void]$markdown.Add('')
        [void]$markdown.Add('## Debug APK')
        [void]$markdown.Add('')
        [void]$markdown.Add("- Path: ``$($artifactEvidence.path)``")
        [void]$markdown.Add("- Size: $($artifactEvidence.sizeBytes) bytes")
        [void]$markdown.Add("- SHA-256: ``$($artifactEvidence.sha256)``")
    }
    [System.IO.File]::WriteAllLines(
        $summaryMarkdownPath,
        $markdown,
        [System.Text.UTF8Encoding]::new($false)
    )
    $summaryWritten = $true

    Write-Host "`nVerification evidence:"
    Write-Host "  $summaryJsonPath"
    Write-Host "  $summaryMarkdownPath"

    if (-not $success) {
        $failedNames = @($requiredFailures | ForEach-Object { $_.name })
        $failureDetails = @($failedNames) + @($strictFailures)
        throw "Verification failed: $($failureDetails -join ', ')"
    }
} catch {
    $capturedFailure = $_
    if (-not $summaryWritten) {
        try {
            $failureSummary = [ordered]@{
                generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                repository = $repositoryRoot
                success = $false
                failureType = $capturedFailure.Exception.GetType().FullName
                steps = $steps
            }
            [System.IO.File]::WriteAllText(
                $summaryJsonPath,
                ($failureSummary | ConvertTo-Json -Depth 10),
                [System.Text.UTF8Encoding]::new($false)
            )
            [System.IO.File]::WriteAllLines(
                $summaryMarkdownPath,
                @(
                    '# Foursquare engineering verification',
                    '',
                    '- Result: **FAIL**',
                    "- Failure type: ``$($failureSummary.failureType)``",
                    '- See completed step logs in this directory.'
                ),
                [System.Text.UTF8Encoding]::new($false)
            )
        } catch {
            Write-Warning 'Unable to write minimal verification failure evidence.'
        }
    }
    throw $capturedFailure
} finally {
    $env:NO_PROXY = $originalNoProxy
}
