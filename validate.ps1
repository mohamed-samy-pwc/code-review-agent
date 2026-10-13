#Requires -Version 5.1
# =============================================================================
# validate.ps1 — Universal Project Validation Script v1.0.0
#
# Runs as the FIRST step in an automated code review agent pipeline.
# Hard gate: exits non-zero on any failure; pipeline must stop.
#
# Usage:  .\validate.ps1 [-Verbose] [-DryRun]
#
# Exit codes:
#   0  all gates PASS or SKIPPED  → pipeline may proceed to code review
#   1  one or more gates FAIL     → pipeline must stop
#   2  script error
#
# Platform: Windows (PowerShell 5.1+), macOS/Linux (pwsh 7+)
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$VerboseOutput
)

$VALIDATOR_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Color helpers (respect NO_COLOR env var)
# ---------------------------------------------------------------------------
function Write-GateLine {
    param([string]$Project, [string]$Lang, [string]$Gate, [string]$Status, [string]$Detail = '')
    $color = switch ($Status) {
        'PASS'    { 'Green'  }
        'FAIL'    { 'Red'    }
        'SKIPPED' { 'Yellow' }
        'RUNNING' { 'Cyan'   }
        default   { 'White'  }
    }
    Write-Host -NoNewline "[$Project/$Lang] $($Gate.PadRight(10)) "
    Write-Host -NoNewline -ForegroundColor $color $Status.PadRight(8)
    if ($Detail) { Write-Host "  $Detail" } else { Write-Host '' }
}

# ---------------------------------------------------------------------------
# Config (.validation.conf INI format — same file as validate.sh reads)
# ---------------------------------------------------------------------------
$CoverageThreshold = 80
$LangThresholds = @{}
$VerboseMode = $VerboseOutput.IsPresent

# Tool output is captured and parsed, so child tools must not emit ANSI colour
# even if the caller's environment forces it.
$env:FORCE_COLOR = '0'
$env:CLICOLOR_FORCE = '0'

# Thresholds must be integers 0-100; anything else is a script error (exit 2).
function ConvertTo-Threshold { param([string]$Key, [string]$Value)
    if ($Value -notmatch '^\d+$' -or [int]$Value -gt 100) {
        [Console]::Error.WriteLine("Invalid value for $Key in .validation.conf: `"$Value`" (expected integer 0-100)")
        exit 2
    }
    return [int]$Value
}

function Read-Conf {
    if (-not (Test-Path '.validation.conf')) { return }
    Get-Content '.validation.conf' | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = ($Matches[2] -replace '#.*$','').Trim()
            switch -Regex ($k) {
                '^COVERAGE_THRESHOLD$'      { $script:CoverageThreshold = ConvertTo-Threshold $k $v }
                '^VERBOSE$'                 { if ($v -eq 'true') { $script:VerboseMode = $true } }
                '^COVERAGE_THRESHOLD_(.+)$' {
                    $suffix = $Matches[1]
                    $threshold = ConvertTo-Threshold $k $v
                    if ($suffix -notmatch '^[A-Za-z0-9_]+$') {
                        [Console]::Error.WriteLine("Invalid config key: $k")
                        exit 2
                    }
                    $script:LangThresholds[$suffix.ToLower()] = $threshold
                }
            }
        }
    }
}
Read-Conf

function Get-Threshold { param([string]$Lang)
    if ($LangThresholds.ContainsKey($Lang)) { return $LangThresholds[$Lang] }
    return $CoverageThreshold
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$InvocationDir = (Get-Location).Path
$LogDir        = Join-Path $InvocationDir 'validation-logs'
$ReportFile    = Join-Path $InvocationDir 'validation-report.json'
$WorkDir       = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

if (-not $DryRun) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# Cleanup on exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
if (-not $env:NO_COLOR) { Write-Host -ForegroundColor Cyan "╔══════════════════════════════════════════════════╗" }
else                    { Write-Host "╔══════════════════════════════════════════════════╗" }
Write-Host "║  Validator v$VALIDATOR_VERSION — Code Review Pipeline Gate  ║"
if (-not $env:NO_COLOR) { Write-Host -ForegroundColor Cyan "╚══════════════════════════════════════════════════╝" }
else                    { Write-Host "╚══════════════════════════════════════════════════╝" }
Write-Host "Scanning: $InvocationDir"

# ---------------------------------------------------------------------------
# Gate runner — owns timing, status classification, Sidecar Log writing,
# dry-run and verbose handling, and the Hard Gate rule that a Project with no
# test files fails its test Gate (ADR-0001).
#
# Language Recipes are functions `Recipe-<lang> <request> <dir>` answering
# detect, has_tests, build, test, lint and coverage. A recipe never writes
# files, never times itself and never prints status lines; it reports an
# outcome through Invoke-GateRun, Set-GateSkip or Set-GatePass (or
# Invoke-GateExec + Complete-Gate when a Gate runs more than one command).
# `coverage` returns the line-coverage percentage, or nothing if unparseable.
# ---------------------------------------------------------------------------
$script:Gate = $null
function New-GateState {
    $script:Gate = [pscustomobject]@{
        Status = 'SKIPPED'; Reason = ''; ExitCode = $null; LogFile = $null
        Last = $null; CovContent = $null; CovUnsupported = $false
        Detail = ''; LineCovPct = $null; Threshold = $null
        Proj = ''; Lang = ''; Name = ''
    }
}

function Set-GatePass { $script:Gate.Status = 'PASS'; $script:Gate.Reason = ''; $script:Gate.ExitCode = 0 }
function Set-GateSkip { param([string]$Reason)
    $script:Gate.Status = 'SKIPPED'; $script:Gate.Reason = $Reason; $script:Gate.ExitCode = $null
}

# Run one tool (dry-run prints it instead); the result is kept for Complete-Gate.
function Invoke-GateExec { param([string]$Dir, [string]$Exe, [string[]]$ToolArgs)
    $script:Gate.Last = Invoke-Tool $Dir $ToolArgs $Exe
}

# Classify the last Invoke-GateExec: PASS on exit 0, otherwise FAIL with the
# given reason ({exit} is replaced by the exit code) and a Sidecar Log.
function Complete-Gate { param([string]$FailReason)
    $r = $script:Gate.Last
    if ($r.ExitCode -eq 0) { Set-GatePass; return }
    $script:Gate.Status   = 'FAIL'
    $script:Gate.ExitCode = $r.ExitCode
    $script:Gate.Reason   = $FailReason.Replace('{exit}', [string]$r.ExitCode)
    $script:Gate.LogFile  = Save-Sidecar $script:Gate.Proj $script:Gate.Lang $script:Gate.Name $r.Output
}

# Run steps in order, stopping at the first failure ('and', like a && b) or the
# first success ('or', like a || b). Outputs are concatenated.
function New-GateStep { param([string]$Exe, [string[]]$ToolArgs) return [pscustomobject]@{ Exe = $Exe; ToolArgs = $ToolArgs } }
function Invoke-GateSeq { param([string]$Dir, [string]$Mode, [object[]]$Steps)
    $out = ''; $last = $null
    foreach ($step in $Steps) {
        $last = Invoke-Tool $Dir $step.ToolArgs $step.Exe
        $out += $last.Output
        if ($Mode -eq 'and' -and $last.ExitCode -ne 0) { break }
        if ($Mode -eq 'or'  -and $last.ExitCode -eq 0) { break }
    }
    $script:Gate.Last = @{ ExitCode = $last.ExitCode; Output = $out }
}

# The Language has no coverage reader.
function Set-GateCoverageUnsupported { $script:Gate.CovUnsupported = $true }

function Invoke-GateRun { param([string]$FailReason, [string]$Dir, [string]$Exe, [string[]]$ToolArgs)
    Invoke-GateExec $Dir $Exe $ToolArgs
    Complete-Gate $FailReason
}

# Test Gate precondition (Hard Gate, ADR-0001): no test files is a FAIL.
function Set-GateNoTests {
    $script:Gate.Status   = 'FAIL'
    $script:Gate.ExitCode = 1
    $script:Gate.Reason   = 'No test files detected — a project must have tests to be reviewable'
    $script:Gate.LogFile  = Save-Sidecar $script:Gate.Proj $script:Gate.Lang $script:Gate.Name $script:Gate.Reason
    $script:Gate.Detail   = $script:Gate.Reason
}

# Coverage Gate: parse the output captured by the test Gate (no re-run) and
# compare line coverage with the Language's threshold.
function Set-GateCoverage { param([string]$Dir)
    $projectDir = $script:Gate.Proj; $lang = $script:Gate.Lang
    $thr = Get-Threshold $lang
    $script:Gate.Threshold = $thr
    $script:Gate.ExitCode  = $null
    if ($DryRun) {
        Write-Host '[DRY RUN] coverage parse (no re-run)'
        Set-GateSkip 'dry-run mode'; $script:Gate.Detail = $script:Gate.Reason; return
    }
    $covFile = Join-Path $WorkDir "COV_${projectDir}_${lang}.txt"
    if (-not (Test-Path $covFile)) {
        Set-GateSkip 'no coverage data (test gate skipped or failed)'; $script:Gate.Detail = $script:Gate.Reason; return
    }
    $covContent = Get-Content $covFile -Raw
    $script:Gate.CovContent = $covContent
    $lpct = & "Recipe-$lang" 'coverage' $Dir
    if ($script:Gate.CovUnsupported) {
        Set-GateSkip "coverage parsing not implemented for $lang"; $script:Gate.Detail = $script:Gate.Reason; return
    }
    $script:Gate.LineCovPct = $lpct
    if ($null -eq $lpct) {
        $hint = & "Recipe-$lang" 'coverage_hint' $Dir
        Set-GateSkip $(if ($hint) { "coverage output unparseable ($hint)" } else { 'coverage output unparseable' })
        Set-Content (Join-Path $LogDir "${projectDir}-${lang}-coverage-raw.log") $covContent -Encoding UTF8
        $script:Gate.LogFile = "validation-logs/${projectDir}-${lang}-coverage-raw.log"
    } elseif ($lpct -ge $thr) {
        $script:Gate.Status = 'PASS'; $script:Gate.Reason = ''
    } else {
        $script:Gate.Status  = 'FAIL'
        $script:Gate.Reason  = "${lpct}% < ${thr}% threshold"
        $script:Gate.LogFile = Save-Sidecar $projectDir $lang 'coverage' $script:Gate.Reason
    }
}

function Invoke-Gate { param([string]$Name, $P)
    $projectDir = $P.Dir; $abs = $P.AbsDir; $lang = $P.Lang
    Write-GateLine $projectDir $lang $Name 'RUNNING'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    New-GateState
    $script:Gate.Proj = $projectDir; $script:Gate.Lang = $lang; $script:Gate.Name = $Name
    if ($Name -eq 'build') { $script:Gate.Reason = 'no build command applies' }

    if ($Name -eq 'test') { Set-Content -Path (Join-Path $WorkDir "TESTSTART_${projectDir}_${lang}") -Value '' }

    if ($Name -eq 'coverage') {
        Set-GateCoverage $abs
    } elseif ($Name -eq 'test' -and -not (& "Recipe-$lang" 'has_tests' $abs)) {
        Set-GateNoTests
    } else {
        & "Recipe-$lang" $Name $abs
        # Coverage is parsed later from the test Gate's captured output.
        if ($Name -eq 'test' -and $script:Gate.Last -and -not $DryRun) {
            $covFile = Join-Path $WorkDir "COV_${projectDir}_${lang}.txt"
            Set-Content -Path $covFile -Value $script:Gate.Last.Output -Encoding UTF8
        }
    }

    $sw.Stop()
    $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    $detail = if ($script:Gate.Detail) { $script:Gate.Detail }
              elseif ($script:Gate.LineCovPct) { "($($script:Gate.LineCovPct)% vs $($script:Gate.Threshold)%, ${secs}s)" }
              else { "(${secs}s)" }
    Write-GateLine $projectDir $lang $Name $script:Gate.Status $detail
    Set-GateResult $projectDir $lang $Name $script:Gate.Status $script:Gate.Reason $script:Gate.ExitCode `
        $sw.Elapsed.TotalSeconds $script:Gate.LogFile $script:Gate.LineCovPct $script:Gate.Threshold
}

function Recipe-typescript { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect' { return (Test-Path "$Dir/package.json") }
        'has_tests' {
            $patterns = '*.test.js','*.test.ts','*.test.jsx','*.test.tsx','*.spec.js','*.spec.ts','*.spec.jsx','*.spec.tsx'
            foreach ($p in $patterns) {
                if (Get-ChildItem -Path $Dir -Filter $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } | Select-Object -First 1) { return $true }
            }
            return $false
        }
        'build' {
            if (-not (Find-Cmd 'npm')) { Set-GateSkip 'toolchain not installed (npm not found)'; return }
            $pkgJson = Get-Content "$Dir/package.json" -Raw | ConvertFrom-Json
            if ($pkgJson.scripts.build) {
                Invoke-GateRun 'npm run build failed (exit {exit})' $Dir 'npm' @('run','build')
            } elseif (Test-Path "$Dir/node_modules/.bin/tsc") {
                Invoke-GateRun 'tsc failed (exit {exit})' $Dir "$Dir/node_modules/.bin/tsc" @('--noEmit')
            } else { Set-GateSkip 'no build script and tsc not found' }
        }
        'test' {
            if (-not (Find-Cmd 'npm')) { Set-GateSkip 'toolchain not installed (npm not found)'; return }
            if ((Test-Path "$Dir/package.json") -and ((Get-Content "$Dir/package.json" -Raw) -match '"vitest"')) {
                # Vitest has none of Jest's flags; run the whole suite with its text reporter.
                Invoke-GateRun 'npm test failed (exit {exit})' $Dir 'npm' @('test','--','--coverage','--coverage.reporter=text')
            } elseif (-not ((Test-Path "$Dir/package.json") -and ((Get-Content "$Dir/package.json" -Raw) -match 'jest|react-scripts'))) {
                # Another runner (Mocha, Ava, Tap, node:test...): its own `npm test`, no Jest flags.
                # Coverage is read only if the script prints a coverage table (c8, nyc).
                Invoke-GateRun 'npm test failed (exit {exit})' $Dir 'npm' @('test')
            } else {
                # Jest: run with unit pattern; if no tests match, retry without pattern
                Invoke-GateExec $Dir 'npm' @('test','--','--coverage','--coverageReporters=text','--testPathPattern=(unit|spec)','--forceExit')
                if ($script:Gate.Last.Output -match 'Your test suite must contain at least one test|No tests found') {
                    Invoke-GateExec $Dir 'npm' @('test','--','--coverage','--coverageReporters=text','--forceExit')
                }
                Complete-Gate 'npm test failed (exit {exit})'
            }
        }
        'lint' {
            # Check for ESLint config before invoking
            $eslintConfigs = @('eslint.config.js','eslint.config.mjs','eslint.config.cjs','.eslintrc.js','.eslintrc.cjs','.eslintrc.yaml','.eslintrc.yml','.eslintrc.json')
            $hasConf = ($eslintConfigs | Where-Object { Test-Path "$Dir/$_" }) -or
                       ((Test-Path "$Dir/package.json") -and ((Get-Content "$Dir/package.json" -Raw) -match '"eslintConfig"'))
            if (-not $hasConf) { Set-GateSkip 'no ESLint config found'; return }
            $eslintBin = "$Dir/node_modules/.bin/eslint"
            if (-not (Test-Path $eslintBin)) { Set-GateSkip 'linter not installed (eslint not in node_modules/.bin)'; return }
            Invoke-GateRun 'eslint failed (exit {exit})' $Dir $eslintBin @('.')
        }
        'coverage' {
            $cleanCov = [regex]::Replace([string]$script:Gate.CovContent, '\x1b\[[0-9;]*m', '')
            if ($cleanCov -match 'All files\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
                return [double]$Matches[4]  # Lines column (4th)
            }
        }
    }
}

function Recipe-python { param([string]$Req, [string]$Dir)
    # detect runs before the helper functions below are defined, so only look up Python when needed.
    $py = $null
    if ($Req -in 'build','test','lint') { $py = Get-PythonPath }
    switch ($Req) {
        'detect' {
            return ((Test-Path "$Dir/pyproject.toml") -or (Test-Path "$Dir/setup.py") -or
                    (Test-Path "$Dir/setup.cfg")      -or (Test-Path "$Dir/requirements.txt"))
        }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include 'test_*.py','*_test.py' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if ($py -and (Test-PythonModule $py @('-c','import build'))) {
                Invoke-GateRun 'python build failed' $Dir $py @('-m','build')
            } elseif (Find-Cmd 'poetry') {
                Invoke-GateRun 'poetry build failed' $Dir 'poetry' @('build')
            } else { Set-GateSkip 'no build tool detected' }
        }
        'test' {
            if (-not $py) { Set-GateSkip 'toolchain not installed (python not found)'; return }
            Invoke-GateExec $Dir $py @('-m','pytest','-m','unit','--cov=src','--cov-report=term-missing','-q')
            if ($script:Gate.Last.ExitCode -eq 5) {
                Invoke-GateExec $Dir $py @('-m','pytest','--cov=src','--cov-report=term-missing','-q')
            }
            Complete-Gate 'pytest failed (exit {exit})'
        }
        'lint' {
            if (Get-Command 'ruff' -ErrorAction SilentlyContinue) {
                Invoke-GateRun 'ruff failed' $Dir 'ruff' @('check','.')
            } elseif ($py -and (Test-PythonModule $py @('-m','ruff','--version'))) {
                Invoke-GateRun 'ruff failed' $Dir $py @('-m','ruff','check','.')
            } elseif (Find-Cmd 'flake8') {
                Invoke-GateRun 'flake8 failed' $Dir 'flake8' @('.')
            } elseif ($py -and (Test-PythonModule $py @('-m','flake8','--version'))) {
                Invoke-GateRun 'flake8 failed' $Dir $py @('-m','flake8','.')
            } elseif (Find-Cmd 'pylint') {
                Invoke-GateRun 'pylint failed' $Dir 'pylint' @('src/')
            } else { Set-GateSkip 'linter not installed (ruff/flake8/pylint not found)' }
        }
        'coverage' {
            if ($script:Gate.CovContent -match '(?m)^TOTAL\s+\d+\s+\d+\s+([\d.]+)%') {
                return [double]$Matches[1]
            }
        }
    }
}

# True when any of the named files in $Dir mentions $Needle (a dependency or plugin name).
function Test-FileMentions { param([string]$Dir, [string[]]$Files, [string]$Needle)
    foreach ($f in $Files) {
        if ((Test-Path "$Dir/$f") -and ((Get-Content "$Dir/$f" -Raw) -match [regex]::Escape($Needle))) { return $true }
    }
    return $false
}

# True when a Gradle settings file includes subprojects.
function Test-GradleIncludes { param([string]$Dir)
    foreach ($f in 'settings.gradle','settings.gradle.kts') {
        if ((Test-Path "$Dir/$f") -and ((Get-Content "$Dir/$f" -Raw) -match '(?m)^\s*include')) { return $true }
    }
    return $false
}

# Line coverage from a JaCoCo XML report written by this run; nothing when there is none.
# The report-level LINE counter is the last one in the file, and the file may be a single line.
function Get-JacocoLinePct { param([string]$Dir)
    $xml = "$Dir/target/site/jacoco/jacoco.xml"
    if (Test-Path "$Dir/build/reports/jacoco/test/jacocoTestReport.xml") { $xml = "$Dir/build/reports/jacoco/test/jacocoTestReport.xml" }
    if (-not (Test-Path $xml)) { return }
    # Ignore a report left on disk by an earlier run: it must be newer than the start of the test Gate.
    $marker = Join-Path $WorkDir "TESTSTART_$($script:Gate.Proj)_$($script:Gate.Lang)"
    if ((Test-Path $marker) -and ((Get-Item $xml).LastWriteTimeUtc -lt (Get-Item $marker).LastWriteTimeUtc)) { return }
    $all = [regex]::Matches((Get-Content $xml -Raw), '<counter type="LINE" missed="(\d+)" covered="(\d+)"')
    if ($all.Count -gt 0) {
        $missed = [int]$all[$all.Count - 1].Groups[1].Value
        $covered = [int]$all[$all.Count - 1].Groups[2].Value
        if (($missed + $covered) -gt 0) { return [Math]::Round($covered / ($missed + $covered) * 100, 1, [MidpointRounding]::AwayFromZero) }
    }
}

# Gradle launcher for a Project: its wrapper, else a system `gradle` when the Project has a build file.
function Get-GradleLauncher { param([string]$Dir)
    if (Test-Path "$Dir/gradlew") { return "$Dir/gradlew" }
    if (((Test-Path "$Dir/build.gradle") -or (Test-Path "$Dir/build.gradle.kts")) -and (Find-Cmd 'gradle')) { return 'gradle' }
    return $null
}

# Test Gate shared by the JVM Languages (Java, Kotlin).
function Invoke-JvmTest { param([string]$Dir)
    if (Test-Path "$Dir/mvnw")        { Invoke-GateRun 'test failed' $Dir "$Dir/mvnw" @('test') }
    elseif ((Test-Path "$Dir/pom.xml") -and (Find-Cmd 'mvn'))           { Invoke-GateRun 'test failed' $Dir 'mvn' @('test') }
    elseif (Get-GradleLauncher $Dir)  { Invoke-GateRun 'test failed' $Dir (Get-GradleLauncher $Dir) @('test','--rerun') }
    else { Set-GateSkip 'toolchain not installed' }
}

function Recipe-java { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'workspace_root' { return (((Test-Path "$Dir/pom.xml") -and ((Get-Content "$Dir/pom.xml" -Raw) -match '<modules>')) -or (Test-GradleIncludes $Dir)) }
        'coverage_hint' { return 'configure the JaCoCo plugin to write an XML report' }
        'detect'    { return ((Test-Path "$Dir/pom.xml") -or (Test-Path "$Dir/build.gradle")) }
        'has_tests' { return (Test-Path "$Dir/src/test") }
        'build' {
            if (Test-Path "$Dir/mvnw")        { Invoke-GateRun 'mvnw failed' $Dir "$Dir/mvnw" @('package','-DskipTests') }
            elseif ((Test-Path "$Dir/pom.xml") -and (Find-Cmd 'mvn'))           { Invoke-GateRun 'mvn failed' $Dir 'mvn' @('package','-DskipTests') }
            elseif (Get-GradleLauncher $Dir)  { Invoke-GateRun 'gradlew assemble failed' $Dir (Get-GradleLauncher $Dir) @('assemble') }
            else { Set-GateSkip 'toolchain not installed' }
        }
        'test' { Invoke-JvmTest $Dir }
        'lint' {
            if (Test-Path "$Dir/mvnw")        { Invoke-GateRun 'checkstyle failed' $Dir "$Dir/mvnw" @('checkstyle:check') }
            elseif ((Test-Path "$Dir/pom.xml") -and (Find-Cmd 'mvn')) { Invoke-GateRun 'checkstyle failed' $Dir 'mvn' @('checkstyle:check') }
            elseif ((Get-GradleLauncher $Dir) -and (Test-FileMentions $Dir @('build.gradle','build.gradle.kts') 'checkstyle')) { Invoke-GateRun 'checkstyle failed' $Dir (Get-GradleLauncher $Dir) @('checkstyleMain') }
            else { Set-GateSkip 'linter not installed' }
        }
        'coverage' { return Get-JacocoLinePct $Dir }
    }
}

function Recipe-kotlin { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'workspace_root' { return (Test-GradleIncludes $Dir) }
        'coverage_hint' { return 'configure the JaCoCo plugin to write an XML report' }
        'detect' {
            if (Test-Path "$Dir/build.gradle.kts") { return $true }
            return ((Test-Path "$Dir/build.gradle") -and [bool](Get-ChildItem -Path $Dir -Filter '*.kt' -ErrorAction SilentlyContinue))
        }
        'has_tests' { return (Test-Path "$Dir/src/test") }
        'build' {
            if (Get-GradleLauncher $Dir) { Invoke-GateRun 'gradlew assemble failed' $Dir (Get-GradleLauncher $Dir) @('assemble') }
            else { Set-GateSkip 'toolchain not installed' }
        }
        'test' { Invoke-JvmTest $Dir }
        'lint' {
            if ((Get-GradleLauncher $Dir) -and (Test-FileMentions $Dir @('build.gradle','build.gradle.kts') 'ktlint')) { Invoke-GateRun 'ktlint failed' $Dir (Get-GradleLauncher $Dir) @('ktlintCheck') }
            else { Set-GateSkip 'linter not installed' }
        }
        'coverage' { return Get-JacocoLinePct $Dir }
    }
}

function Recipe-go { param([string]$Req, [string]$Dir)
    switch ($Req) {
        # go.mod is canonical — *.go files may appear in vendor/ of non-Go projects
        'workspace_root' { return (Test-Path "$Dir/go.work") }
        'detect'    { return (Test-Path "$Dir/go.mod") }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*_test.go' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if (Find-Cmd 'go') { Invoke-GateRun 'go build failed' $Dir 'go' @('build','./...') }
            else { Set-GateSkip 'toolchain not installed (go not found)' }
        }
        'test' {
            if (Find-Cmd 'go') {
                $covOut = Join-Path $WorkDir 'cov.out'
                Invoke-GateSeq $Dir 'and' @((New-GateStep 'go' @('test','-short',"-coverprofile=$covOut",'./...')),
                                            (New-GateStep 'go' @('tool','cover',"-func=$covOut")))
                Complete-Gate 'go test failed'
            } else { Set-GateSkip 'toolchain not installed (go not found)' }
        }
        'lint' {
            if (-not (Find-Cmd 'go')) { Set-GateSkip 'toolchain not installed (go not found)'; return }
            # go vet is always available when Go is installed
            if (Find-Cmd 'golangci-lint') { Invoke-GateRun 'golangci-lint failed' $Dir 'golangci-lint' @('run') }
            else { Invoke-GateRun 'go vet failed' $Dir 'go' @('vet','./...') }
        }
        'coverage' {
            if ($script:Gate.CovContent -match 'total:\s+\(statements\)\s+([\d.]+)%') { return [double]$Matches[1] }
        }
    }
}

function Recipe-rust { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'workspace_root' { return ((Test-Path "$Dir/Cargo.toml") -and ((Get-Content "$Dir/Cargo.toml" -Raw) -match '(?m)^\[workspace\]')) }
        'coverage_hint' { return 'install cargo-llvm-cov or cargo-tarpaulin' }
        'detect' { return (Test-Path "$Dir/Cargo.toml") }
        'has_tests' {
            if (Test-Path "$Dir/tests") { return $true }
            return $null -ne (Get-ChildItem -Path "$Dir/src" -Recurse -File -ErrorAction SilentlyContinue |
                Select-String -Pattern '\[cfg\(test\)\]' -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        'build' {
            if (Find-Cmd 'cargo') { Invoke-GateRun 'cargo build failed' $Dir 'cargo' @('build') }
            else { Set-GateSkip 'toolchain not installed (cargo not found)' }
        }
        'test' {
            if (Find-Cmd 'cargo') {
                # Tests run once; a coverage tool, when installed, measures that same run.
                & cargo llvm-cov --version *> $null; $llvmCov = ($LASTEXITCODE -eq 0)
                if ($llvmCov) { Invoke-GateRun 'cargo test failed' $Dir 'cargo' @('llvm-cov','--lib') }
                else {
                    & cargo tarpaulin --version *> $null; $tarpaulin = ($LASTEXITCODE -eq 0)
                    if ($tarpaulin) { Invoke-GateRun 'cargo test failed' $Dir 'cargo' @('tarpaulin','--lib','--out','Stdout') }
                    else { Invoke-GateRun 'cargo test failed' $Dir 'cargo' @('test','--lib') }
                }
            }
            else { Set-GateSkip 'toolchain not installed (cargo not found)' }
        }
        'lint' {
            if (-not (Find-Cmd 'cargo')) { Set-GateSkip 'toolchain not installed (cargo not found)' }
            else {
                & cargo clippy --version *> $null
                if ($LASTEXITCODE -ne 0) { Set-GateSkip 'linter not installed (cargo clippy not found)' }
                else { Invoke-GateRun 'clippy failed' $Dir 'cargo' @('clippy','--','-D','warnings') }
            }
        }
        'coverage' {
            # cargo-llvm-cov: "TOTAL regions missed cover% functions missed exec% lines missed cover% ..."
            $total = ([string]$script:Gate.CovContent -split "`r?`n" | Where-Object { $_ -match 'TOTAL' } | Select-Object -First 1)
            if ($total) {
                $f = $total.Trim() -split '\s+'
                $cell = if ($f.Count -ge 10) { $f[9] } else { $f[-1] }
                if ($cell -match '^([\d.]+)%$') { return [double]$Matches[1] }
            }
            if ($script:Gate.CovContent -match '([\d.]+)% coverage') { return [double]$Matches[1] }
        }
    }
}

function Recipe-dotnet { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'workspace_root' { return ([bool](Get-ChildItem -Path $Dir -Filter '*.sln' -ErrorAction SilentlyContinue) -or [bool](Get-ChildItem -Path $Dir -Filter '*.slnx' -ErrorAction SilentlyContinue)) }
        'detect' {
            return ([bool](Get-ChildItem -Path $Dir -Filter '*.csproj' -ErrorAction SilentlyContinue) -or
                    [bool](Get-ChildItem -Path $Dir -Filter '*.sln' -ErrorAction SilentlyContinue) -or
                    [bool](Get-ChildItem -Path $Dir -Filter '*.slnx' -ErrorAction SilentlyContinue) -or
                    (Test-Path "$Dir/global.json"))
        }
        'has_tests' {
            # By file name, or by a test attribute (xUnit [Fact]/[Theory], NUnit [Test], MSTest [TestMethod]).
            if ($null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*Tests.cs','*Test.cs' -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
            return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*.cs' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](obj|bin|node_modules)[\\/]' } |
                Select-String -Pattern '\[(Fact|Theory|Test|TestCase|TestMethod|DataTestMethod)\b' -List -ErrorAction SilentlyContinue |
                Select-Object -First 1)
        }
        'build' {
            if (Find-Cmd 'dotnet') {
                Invoke-GateSeq $Dir 'and' @((New-GateStep 'dotnet' @('restore')), (New-GateStep 'dotnet' @('build')))
                Complete-Gate 'dotnet build failed'
            } else { Set-GateSkip 'toolchain not installed (dotnet not found)' }
        }
        'test' {
            if (Find-Cmd 'dotnet') { Invoke-GateRun 'dotnet test failed' $Dir 'dotnet' @('test','--no-build','--collect:XPlat Code Coverage') }
            else { Set-GateSkip 'toolchain not installed (dotnet not found)' }
        }
        'lint' {
            if (Find-Cmd 'dotnet') { Invoke-GateRun 'dotnet format failed' $Dir 'dotnet' @('format','--verify-no-changes') }
            else { Set-GateSkip 'toolchain not installed (dotnet not found)' }
        }
        'coverage' {
            # Cobertura files written by coverlet; the test output lists their paths.
            # Sum covered and valid lines over all of them.
            $covered = 0; $valid = 0
            foreach ($m in [regex]::Matches([string]$script:Gate.CovContent, '\S*coverage\.cobertura\.xml')) {
                if (-not (Test-Path -LiteralPath $m.Value)) { continue }
                $root = Select-String -LiteralPath $m.Value -Pattern '<coverage ' -List | Select-Object -First 1
                if ($root -and $root.Line -match 'lines-covered="(\d+)"') {
                    $c = [int]$Matches[1]
                    if ($root.Line -match 'lines-valid="(\d+)"') { $covered += $c; $valid += [int]$Matches[1] }
                }
            }
            if ($valid -gt 0) { return [Math]::Round($covered / $valid * 100, 1, [MidpointRounding]::AwayFromZero) }
        }
    }
}

function Recipe-ruby { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect'    { return (Test-Path "$Dir/Gemfile") }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*_spec.rb','*_test.rb' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if ((Find-Cmd 'bundle') -and (Test-Path "$Dir/Rakefile") -and ((Get-Content "$Dir/Rakefile" -Raw) -match 'build')) {
                Invoke-GateRun 'rake build failed' $Dir 'bundle' @('exec','rake','build')
            } else { Set-GateSkip 'no build command detected' }
        }
        'test' {
            if (Find-Cmd 'bundle') {
                if ((Test-Path "$Dir/bin/rails") -and -not (Test-Path "$Dir/spec")) {
                    Invoke-GateRun 'rails test failed' $Dir 'bundle' @('exec','rails','test')
                } elseif (-not (Test-Path "$Dir/spec") -and (Test-Path "$Dir/test")) {
                    # Minitest without Rails
                    Invoke-GateRun 'minitest failed' $Dir 'bundle' @('exec','ruby','-Itest','-e',"Dir.glob('./test/**/*_test.rb').sort.each { |f| require f }")
                } else {
                    Invoke-GateExec $Dir 'bundle' @('exec','rspec','--tag','unit','spec/')
                    # RSpec exits 0 when no example carries the tag, so also fall back on "0 examples".
                    if ($script:Gate.Last.ExitCode -ne 0 -or $script:Gate.Last.Output -match '(^|[^0-9])0 examples,') {
                        Invoke-GateExec $Dir 'bundle' @('exec','rspec','spec/')
                    }
                    Complete-Gate 'rspec failed'
                }
            } else { Set-GateSkip 'toolchain not installed (bundle not found)' }
        }
        'lint' {
            if (-not (Find-Cmd 'bundle')) { Set-GateSkip 'linter not installed (bundle not found)' }
            elseif (-not (Test-FileMentions $Dir @('Gemfile','Gemfile.lock') 'rubocop')) { Set-GateSkip 'linter not installed (rubocop not in Gemfile)' }
            else { Invoke-GateRun 'rubocop failed' $Dir 'bundle' @('exec','rubocop') }
        }
        'coverage' {
            # SimpleCov prints "Line coverage: 2 / 2 (100.00%)", sometimes with ANSI colour.
            $clean = [regex]::Replace([string]$script:Gate.CovContent, '\x1b\[[0-9;]*m', '')
            $all = [regex]::Matches($clean, '(?i)line coverage:[^(]*\(([\d.]+)%\)')
            if ($all.Count -gt 0) { return [double]$all[$all.Count - 1].Groups[1].Value }
        }
    }
}

function Recipe-php { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'coverage_hint' { return 'install xdebug or pcov so PHPUnit can measure coverage' }
        'detect'    { return (Test-Path "$Dir/composer.json") }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*Test.php' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            # Dev dependencies stay: the test and lint Gates need phpunit and phpstan from vendor/.
            if (Find-Cmd 'composer') { Invoke-GateRun 'composer install failed' $Dir 'composer' @('install','--no-interaction') }
            else { Set-GateSkip 'toolchain not installed (composer not found)' }
        }
        'test' {
            if (Test-Path "$Dir/vendor/bin/phpunit") {
                Invoke-GateExec $Dir "$Dir/vendor/bin/phpunit" @('--coverage-text')
                # Without xdebug or pcov PHPUnit exits 1 even when every test passes; rerun without coverage.
                if ($script:Gate.Last.ExitCode -ne 0 -and $script:Gate.Last.Output -match 'No code coverage driver available') {
                    Invoke-GateExec $Dir "$Dir/vendor/bin/phpunit" @()
                }
                Complete-Gate 'phpunit failed'
            }
            else { Set-GateSkip 'toolchain not installed (phpunit not found)' }
        }
        'lint' {
            if (Test-Path "$Dir/vendor/bin/phpstan") { Invoke-GateRun 'phpstan failed' $Dir "$Dir/vendor/bin/phpstan" @('analyse') }
            else { Set-GateSkip 'linter not installed (phpstan/psalm not found)' }
        }
        'coverage' {
            if ($script:Gate.CovContent -match 'Lines:\s+([\d.]+)%') { return [double]$Matches[1] }
        }
    }
}

function Recipe-swift { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect' {
            return ((Test-Path "$Dir/Package.swift") -or
                    [bool](Get-ChildItem -Path $Dir -Filter '*.xcodeproj' -ErrorAction SilentlyContinue))
        }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*Tests.swift' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if (Find-Cmd 'swift') { Invoke-GateRun 'swift build failed' $Dir 'swift' @('build') }
            else { Set-GateSkip 'toolchain not installed (swift not found)' }
        }
        'test' {
            if (Find-Cmd 'swift') {
                Invoke-GateExec $Dir 'swift' @('test','--enable-code-coverage')
                # Ask SwiftPM where it wrote the coverage JSON; the path lands in the captured output.
                if ($script:Gate.Last.ExitCode -eq 0) {
                    $first = $script:Gate.Last
                    Invoke-GateSeq $Dir 'and' @((New-GateStep 'swift' @('test','--show-codecov-path')))
                    $script:Gate.Last = @{ ExitCode = $script:Gate.Last.ExitCode; Output = $first.Output + $script:Gate.Last.Output }
                }
                Complete-Gate 'swift test failed'
            }
            else { Set-GateSkip 'toolchain not installed (swift not found)' }
        }
        'lint' {
            if (Find-Cmd 'swiftlint') {
                # SwiftPM keeps generated code in .build/, which is not the Project's to lint.
                $paths = @()
                if (Test-Path "$Dir/Package.swift") { $paths = @('Sources','Tests') | Where-Object { Test-Path "$Dir/$_" } }
                Invoke-GateRun 'swiftlint failed' $Dir 'swiftlint' (@('lint') + $paths)
            }
            else { Set-GateSkip 'linter not installed (swiftlint not found)' }
        }
        'coverage' {
            # SwiftPM's coverage JSON: sum line counts over the package's own sources
            # (not Tests/ and not .build/).
            $jsonPath = ([string]$script:Gate.CovContent -split "`r?`n" | Where-Object { $_ -match '\.json\s*$' } | Select-Object -Last 1)
            if ($jsonPath) { $jsonPath = $jsonPath.Trim() }
            if ($jsonPath -and (Test-Path -LiteralPath $jsonPath)) {
                $files = (Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json).data[0].files |
                    Where-Object { $_.filename -notmatch '[\\/](Tests|\.build)[\\/]' }
                $count = ($files | ForEach-Object { $_.summary.lines.count } | Measure-Object -Sum).Sum
                $cov   = ($files | ForEach-Object { $_.summary.lines.covered } | Measure-Object -Sum).Sum
                if ($count -gt 0) { return [Math]::Round($cov / $count * 100, 1, [MidpointRounding]::AwayFromZero) }
            }
        }
    }
}

function Recipe-cpp { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect' {
            if (Test-Path "$Dir/CMakeLists.txt") { return $true }
            $cFiles = Get-ChildItem -Path $Dir -Filter '*.c' -ErrorAction SilentlyContinue
            $cppFiles = Get-ChildItem -Path $Dir -Filter '*.cpp' -ErrorAction SilentlyContinue
            return ((Test-Path "$Dir/Makefile") -and [bool]($cFiles -or $cppFiles))
        }
        'has_tests' {
            return ((Test-Path "$Dir/test") -or (Test-Path "$Dir/tests") -or
                    ($null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*_test.c','*_test.cpp' -ErrorAction SilentlyContinue | Select-Object -First 1)))
        }
        'build' {
            if ((Test-Path "$Dir/CMakeLists.txt") -and (Find-Cmd 'cmake')) {
                Invoke-GateSeq $Dir 'and' @((New-GateStep 'cmake' @('-B','build','-DCMAKE_BUILD_TYPE=Release')),
                                            (New-GateStep 'cmake' @('--build','build')))
                Complete-Gate 'cmake build failed'
            } elseif ((Test-Path "$Dir/Makefile") -and (Find-Cmd 'make')) {
                Invoke-GateRun 'make failed' $Dir 'make' @()
            } else { Set-GateSkip 'toolchain not installed' }
        }
        'test' {
            if ((Test-Path "$Dir/CMakeLists.txt") -or -not (Test-Path "$Dir/Makefile")) {
                if (Find-Cmd 'ctest') {
                    Invoke-GateRun 'ctest failed' $Dir 'ctest' @('--test-dir','build')
                } else { Set-GateSkip 'toolchain not installed (ctest not found)' }
            } elseif (((Get-Content "$Dir/Makefile" -Raw) -match '(?m)^test:') -and (Find-Cmd 'make')) {
                # Makefile project with a `test` target
                Invoke-GateRun 'make test failed' $Dir 'make' @('test')
            } else { Set-GateSkip 'no test command detected (no CMakeLists.txt, or no test target in Makefile)' }
        }
        'lint' {
            if (-not (Find-Cmd 'clang-tidy')) { Set-GateSkip 'linter not installed (clang-tidy not found)'; return }
            # Without a config clang-tidy exits with "no checks enabled", which is not a lint failure.
            if (-not (Test-Path "$Dir/.clang-tidy")) { Set-GateSkip 'no .clang-tidy config found'; return }
            $cfiles = @(Get-ChildItem -Path $Dir -Recurse -Depth 3 -File -Include '*.cpp','*.c' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/]build[\\/]' } | Select-Object -First 100 | ForEach-Object { $_.FullName })
            if ($cfiles.Count -gt 0) { Invoke-GateRun 'clang-tidy failed' $Dir 'clang-tidy' ($cfiles + '--') }
            else { Set-GateSkip 'no .c/.cpp source files found' }
        }
        'coverage' { Set-GateCoverageUnsupported }
    }
}

function Recipe-elixir { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect'    { return (Test-Path "$Dir/mix.exs") }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*_test.exs' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if (Find-Cmd 'mix') { Invoke-GateRun 'mix compile failed' $Dir 'mix' @('compile') }
            else { Set-GateSkip 'toolchain not installed (mix not found)' }
        }
        'test' {
            if (Find-Cmd 'mix') {
                Invoke-GateSeq $Dir 'or' @((New-GateStep 'mix' @('test','--cover','--only','unit')), (New-GateStep 'mix' @('test','--cover')))
                Complete-Gate 'mix test failed'
            } else { Set-GateSkip 'toolchain not installed (mix not found)' }
        }
        'lint' {
            if (-not (Find-Cmd 'mix')) { Set-GateSkip 'toolchain not installed (mix not found)' }
            elseif (-not (Test-FileMentions $Dir @('mix.exs') 'credo')) { Set-GateSkip 'linter not installed (credo not in mix.exs)' }
            else { Invoke-GateRun 'mix credo failed' $Dir 'mix' @('credo') }
        }
        'coverage' {
            $all = [regex]::Matches([string]$script:Gate.CovContent, '([\d.]+)% \| Total')
            if ($all.Count -gt 0) { return [double]$all[$all.Count - 1].Groups[1].Value }
        }
    }
}

function Recipe-scala { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect'    { return (Test-Path "$Dir/build.sbt") }
        'has_tests' { return (Test-Path "$Dir/src/test") }
        'build' {
            if (Find-Cmd 'sbt') { Invoke-GateRun 'sbt compile failed' $Dir 'sbt' @('compile') }
            else { Set-GateSkip 'toolchain not installed (sbt not found)' }
        }
        'test' {
            if (Find-Cmd 'sbt') {
                $scoverage = [bool](Get-ChildItem -Path "$Dir/project" -File -ErrorAction SilentlyContinue | Select-String -Pattern 'scoverage' -List -ErrorAction SilentlyContinue)
                if ($scoverage) {
                    # sbt-scoverage measures the same run; its report prints "Statement coverage.: NN.NN%".
                    Invoke-GateExec $Dir 'sbt' @('coverage','testOnly *Unit*','coverageReport')
                } else {
                    Invoke-GateExec $Dir 'sbt' @('testOnly *Unit*')
                }
                # sbt exits 0 when the pattern matches nothing, so also fall back on "No tests to run".
                if ($script:Gate.Last.ExitCode -ne 0 -or $script:Gate.Last.Output -match 'No tests to run') {
                    if ($scoverage) { Invoke-GateExec $Dir 'sbt' @('coverage','test','coverageReport') }
                    else { Invoke-GateExec $Dir 'sbt' @('test') }
                }
                Complete-Gate 'sbt test failed'
            } else { Set-GateSkip 'toolchain not installed (sbt not found)' }
        }
        'lint' {
            if (-not (Find-Cmd 'sbt')) { Set-GateSkip 'toolchain not installed (sbt not found)' }
            elseif (-not ((Test-FileMentions $Dir @('build.sbt') 'scalastyle') -or
                          (Get-ChildItem -Path "$Dir/project" -File -ErrorAction SilentlyContinue | Select-String -Pattern 'scalastyle' -List -ErrorAction SilentlyContinue))) {
                Set-GateSkip 'linter not installed (scalastyle plugin not configured)'
            }
            else { Invoke-GateRun 'scalastyle failed' $Dir 'sbt' @('scalastyle') }
        }
        'coverage' {
            # sbt-scoverage reports statement coverage (the closest it has to line coverage).
            $all = [regex]::Matches([string]$script:Gate.CovContent, 'Statement coverage[.]*:\s*([\d.]+)%')
            if ($all.Count -gt 0) { return [double]$all[$all.Count - 1].Groups[1].Value }
        }
        'coverage_hint' { return 'add the sbt-scoverage plugin to project/plugins.sbt' }
    }
}

# ---------------------------------------------------------------------------
# Language detection — file presence only
# ---------------------------------------------------------------------------
function Get-Lang { param([string]$Dir)
    # Detection order matters: the first Language whose signal is present wins.
    foreach ($l in 'typescript','python','kotlin','java','go','rust','dotnet','ruby','php','swift','cpp','elixir','scala') {
        if (& "Recipe-$l" 'detect' $Dir) { return $l }
    }
    return $null
}

# Scan root and depth-1 subdirs; no symlinks
$Projects = [System.Collections.Generic.List[hashtable]]::new()

$rootLang = Get-Lang $InvocationDir
if ($rootLang) { $Projects.Add(@{ Dir = 'root'; AbsDir = $InvocationDir; Lang = $rootLang }) }

# A workspace root (solution file, Maven modules, Cargo workspace, go.work, Gradle
# include) builds its own subprojects, so same-family subdirectories are not Projects.
$rootOwns = $false
if ($rootLang) { $rootOwns = [bool](& "Recipe-$rootLang" 'workspace_root' $InvocationDir) }
function Test-SameFamily { param([string]$A, [string]$B)
    if ($A -in 'java','kotlin' -and $B -in 'java','kotlin') { return $true }
    return $A -eq $B
}

Get-ChildItem -Path $InvocationDir -Directory | Where-Object { -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) } | ForEach-Object {
    $subLang = Get-Lang $_.FullName
    if ($rootOwns -and $subLang -and (Test-SameFamily $rootLang $subLang)) { return }
    if ($subLang) { $Projects.Add(@{ Dir = $_.Name; AbsDir = $_.FullName; Lang = $subLang }) }
}

if ($Projects.Count -eq 0) {
    Write-Error "No recognisable project found in $InvocationDir or its immediate subdirectories."
    exit 2
}

Write-Host "Detected project(s):"
$Projects | ForEach-Object { Write-Host "  $($_.Dir) [$($_.Lang)]" }
Write-Host ''

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------
$GateResults = @{}  # key: "proj|lang|gate" → Gate Result record ([pscustomobject])

function Set-GateResult {
    param([string]$Proj, [string]$Lang, [string]$Gate, [string]$Status,
          [string]$Reason = '', [object]$ExitCode = $null, [double]$Duration = 0,
          [object]$LogFile = $null, [object]$LineCovPct = $null,
          [object]$Threshold = $null, [object]$BranchCovPct = $null,
          [object]$FunctionCovPct = $null)
    # One immutable-by-convention Gate Result, written once; read only by
    # Write-ValidationReport and the summary table.
    $GateResults["$Proj|$Lang|$Gate"] = [pscustomobject]@{
        Status      = $Status
        Reason      = $Reason
        ExitCode    = $ExitCode
        Duration    = [Math]::Round($Duration, 1)
        LogFile     = $LogFile
        LineCovPct  = $LineCovPct
        BranchCovPct   = $BranchCovPct
        FunctionCovPct = $FunctionCovPct
        Threshold   = $Threshold
    }
}

function Invoke-Tool {
    param([string]$WorkingDir, [string[]]$ArgumentList, [string]$Exe)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($DryRun) {
        Write-Host "[DRY RUN] $Exe $($ArgumentList -join ' ')"
        return @{ ExitCode = 0; Output = ''; Duration = 0 }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Exe
    $psi.Arguments              = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.WorkingDirectory       = $WorkingDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $sw.Stop()
    $combined = $stdout + $stderr
    if ($VerboseMode) { Write-Host $combined }
    return @{ ExitCode = $proc.ExitCode; Output = $combined; Duration = $sw.Elapsed.TotalSeconds }
}

function Save-Sidecar {
    param([string]$Proj, [string]$Lang, [string]$Gate, [string]$Content)
    $name = "$Proj-$Lang-$Gate.log"
    $path = Join-Path $LogDir $name
    Set-Content -Path $path -Value $Content -Encoding UTF8
    return "validation-logs/$name"
}

function Find-Cmd { param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# Path of python3 (or python), or $null. PowerShell 5.1 compatible (no ?. / ??).
function Get-PythonPath {
    foreach ($n in 'python3','python') {
        $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
    }
    return $null
}

# True when `python -m <module> <args>` succeeds.
function Test-PythonModule { param([string]$Py, [string[]]$ModuleArgs)
    & $Py @ModuleArgs *>$null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# Run all gates
# ---------------------------------------------------------------------------
foreach ($proj in $Projects) {
    Write-Host "── [$($proj.Dir) / $($proj.Lang)] ──────────────────────────────────"
    Invoke-Gate 'build' $proj
    Invoke-Gate 'test'  $proj
    Invoke-Gate 'lint'  $proj
    Invoke-Gate 'coverage' $proj
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Totals — read from the Gate Results; used by the report and the summary
# ---------------------------------------------------------------------------
function Get-GateTotals {
    $t = [pscustomobject]@{ Projects = $Projects.Count; Gates = 0; Passed = 0; Failed = 0; Skipped = 0; OverallPass = $true }
    foreach ($key in $GateResults.Keys) {
        $t.Gates++
        switch ($GateResults[$key].Status) {
            'PASS'    { $t.Passed++ }
            'FAIL'    { $t.Failed++; $t.OverallPass = $false }
            'SKIPPED' { $t.Skipped++ }
        }
    }
    return $t
}
$totals = Get-GateTotals
$overallPass = $totals.OverallPass
$failed = $totals.Failed

# ---------------------------------------------------------------------------
# Validation Report writer — owns the pinned schema, field order and null
# handling (ADR-0002). Reads Gate Results and the totals.
# ---------------------------------------------------------------------------
function Write-ValidationReport {
    $ts = (Get-Date -AsUTC).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $projectsArr = $Projects | ForEach-Object {
        $projectDir = $_.Dir; $lang = $_.Lang
        $gates = [ordered]@{}
        foreach ($gate in @('build','test','lint','coverage')) {
            $r = $GateResults["$projectDir|$lang|$gate"]
            $gObj = [ordered]@{
                status           = $r.Status
                duration_seconds = $r.Duration
                exit_code        = $r.ExitCode
                reason           = if ($r.Reason) { $r.Reason } else { $null }
                log_file         = $r.LogFile
            }
            if ($gate -eq 'coverage') {
                $gObj['line_coverage_pct']     = $(if ($null -ne $r.LineCovPct -and $r.LineCovPct -eq [math]::Floor($r.LineCovPct)) { [int]$r.LineCovPct } else { $r.LineCovPct })
                $gObj['branch_coverage_pct']   = $r.BranchCovPct
                $gObj['function_coverage_pct'] = $r.FunctionCovPct
                $gObj['threshold_pct']         = $r.Threshold
            }
            $gates[$gate] = $gObj
        }
        [ordered]@{ project_dir = $projectDir; language = $lang; gates = $gates }
    }

    $report = [ordered]@{
        validator_version = $VALIDATOR_VERSION
        timestamp         = $ts
        invocation_dir    = $InvocationDir
        overall_pass      = $overallPass
        projects          = @($projectsArr)
        summary           = [ordered]@{
            total_projects = $totals.Projects
            total_gates_run = $totals.Gates
            passed  = $totals.Passed
            failed  = $totals.Failed
            skipped = $totals.Skipped
        }
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $ReportFile -Encoding UTF8
}

if (-not $DryRun) { Write-ValidationReport }

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '┌──────────────┬────────────┬───────────┬──────────┬────────────────────────────────────────────┐'
Write-Host ('│ {0,-12} │ {1,-10} │ {2,-9} │ {3,-8} │ {4,-42} │' -f 'Project','Language','Gate','Result','Detail')
Write-Host '├──────────────┼────────────┼───────────┼──────────┼────────────────────────────────────────────┤'

foreach ($proj in $Projects) {
    $projectDir = $proj.Dir; $lang = $proj.Lang
    foreach ($gate in @('build','test','lint','coverage')) {
        $r = $GateResults["$projectDir|$lang|$gate"]
        $detail = if ($r.Reason) { $r.Reason.Substring(0, [Math]::Min(42, $r.Reason.Length)) } else { '' }
        Write-Host ('│ {0,-12} │ {1,-10} │ {2,-9} │ {3,-8} │ {4,-42} │' -f $projectDir, $lang, $gate, $r.Status, $detail)
    }
}

Write-Host '└──────────────┴────────────┴───────────┴──────────┴────────────────────────────────────────────┘'
Write-Host ''

if ($overallPass) {
    if ($env:NO_COLOR) { Write-Host "Overall: PASS" }
    else { Write-Host -ForegroundColor Green "Overall: PASS" }
} else {
    if ($env:NO_COLOR) { Write-Host "Overall: FAIL — $failed gate(s) failed" }
    else { Write-Host -ForegroundColor Red "Overall: FAIL — $failed gate(s) failed" }
}
if (-not $DryRun) { Write-Host "Report:  $ReportFile" }
Write-Host ''

# Cleanup temp dir explicitly (EngineEvent may not fire in all PS versions)
Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue

exit $(if ($overallPass) { 0 } else { 1 })
