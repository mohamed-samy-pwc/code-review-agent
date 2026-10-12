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
function Write-Status {
    param([string]$Status, [string]$Message)
    if ($env:NO_COLOR) {
        Write-Host "$Status  $Message"
        return
    }
    $color = switch ($Status) {
        'PASS'    { 'Green'  }
        'FAIL'    { 'Red'    }
        'SKIPPED' { 'Yellow' }
        'RUNNING' { 'Cyan'   }
        default   { 'White'  }
    }
    Write-Host -NoNewline "  "
    Write-Host -NoNewline -ForegroundColor $color $Status
    Write-Host "  $Message"
}

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
                '^COVERAGE_THRESHOLD_(.+)$' { $lang = $Matches[1].ToLower(); $script:LangThresholds[$lang] = ConvertTo-Threshold $k $v }
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
        Last = $null; CovContent = $null; CovUnsupported = $false; NoCoverage = $false
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

# The test run left no coverage output to parse later.
function Set-GateNoCoverage { $script:Gate.NoCoverage = $true }
# The Language has no coverage reader.
function Set-GateCoverageUnsupported { $script:Gate.CovUnsupported = $true }

function Invoke-GateRun { param([string]$FailReason, [string]$Dir, [string]$Exe, [string[]]$ToolArgs)
    Invoke-GateExec $Dir $Exe $ToolArgs
    Complete-Gate $FailReason
}

function Invoke-Gate { param([string]$Name, $P)
    $pd = $P.Dir; $abs = $P.AbsDir; $lang = $P.Lang
    Write-GateLine $pd $lang $Name 'RUNNING'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    New-GateState
    $script:Gate.Proj = $pd; $script:Gate.Lang = $lang; $script:Gate.Name = $Name
    if ($Name -eq 'build') { $script:Gate.Reason = 'no build command applies' }

    if ($Name -eq 'test' -and -not (& "Recipe-$lang" 'has_tests' $abs)) {
        $rs = 'No test files detected — a project must have tests to be reviewable'
        $lf = Save-Sidecar $pd $lang 'test' $rs
        $sw.Stop()
        Write-GateLine $pd $lang 'test' 'FAIL' $rs
        Set-GateResult $pd $lang 'test' 'FAIL' $rs 1 $sw.Elapsed.TotalSeconds $lf
        return
    }

    & "Recipe-$lang" $Name $abs

    # Coverage is parsed later from the test Gate's captured output.
    if ($Name -eq 'test' -and $script:Gate.Last -and -not $script:Gate.NoCoverage -and -not $DryRun) {
        $covFile = Join-Path $WorkDir "COV_${pd}_${lang}.txt"
        Set-Content -Path $covFile -Value $script:Gate.Last.Output -Encoding UTF8
    }

    $sw.Stop()
    Write-GateLine $pd $lang $Name $script:Gate.Status "($([Math]::Round($sw.Elapsed.TotalSeconds,1))s)"
    Set-GateResult $pd $lang $Name $script:Gate.Status $script:Gate.Reason $script:Gate.ExitCode $sw.Elapsed.TotalSeconds $script:Gate.LogFile
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
            Invoke-GateExec $Dir 'npm' @('test','--','--coverage','--coverageReporters=text','--testPathPattern=(unit|spec)','--forceExit')
            # Fallback if no tests matched pattern
            if ($script:Gate.Last.Output -match 'Your test suite must contain at least one test|No tests found') {
                Invoke-GateExec $Dir 'npm' @('test','--','--coverage','--coverageReporters=text','--forceExit')
            }
            Complete-Gate 'npm test failed (exit {exit})'
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
            if ($script:Gate.CovContent -match 'All files\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
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

# Line coverage from a JaCoCo XML report (Java, Kotlin); nothing when absent.
function Get-JacocoLinePct { param([string]$Dir)
    $xml = "$Dir/target/site/jacoco/jacoco.xml"
    if (Test-Path "$Dir/build/reports/jacoco/test/jacocoTestReport.xml") { $xml = "$Dir/build/reports/jacoco/test/jacocoTestReport.xml" }
    if (-not (Test-Path $xml)) { return }
    $line = Select-String -Path $xml -Pattern 'type="LINE"' | Select-Object -Last 1
    if ($line -and $line.Line -match '.*missed="(\d+)"') {
        $missed = [int]$Matches[1]
        if ($line.Line -match '.*covered="(\d+)"') {
            $total = $missed + [int]$Matches[1]
            if ($total -gt 0) { return [Math]::Round([int]$Matches[1] / $total * 100, 1, [MidpointRounding]::AwayFromZero) }
        }
    }
}

# Test Gate shared by the JVM Languages (Java, Kotlin).
function Invoke-JvmTest { param([string]$Dir)
    if (Test-Path "$Dir/mvnw")        { Invoke-GateRun 'test failed' $Dir "$Dir/mvnw" @('test') }
    elseif (Find-Cmd 'mvn')           { Invoke-GateRun 'test failed' $Dir 'mvn' @('test') }
    elseif (Test-Path "$Dir/gradlew") { Invoke-GateRun 'test failed' $Dir "$Dir/gradlew" @('test') }
    else { Set-GateSkip 'toolchain not installed' }
}

function Recipe-java { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect'    { return ((Test-Path "$Dir/pom.xml") -or (Test-Path "$Dir/build.gradle")) }
        'has_tests' { return (Test-Path "$Dir/src/test") }
        'build' {
            if (Test-Path "$Dir/mvnw")        { Invoke-GateRun 'mvnw failed' $Dir "$Dir/mvnw" @('package','-DskipTests') }
            elseif (Find-Cmd 'mvn')           { Invoke-GateRun 'mvn failed' $Dir 'mvn' @('package','-DskipTests') }
            elseif (Test-Path "$Dir/gradlew") { Invoke-GateRun 'gradlew assemble failed' $Dir "$Dir/gradlew" @('assemble') }
            else { Set-GateSkip 'toolchain not installed' }
        }
        'test' { Invoke-JvmTest $Dir }
        'lint' {
            if (Test-Path "$Dir/mvnw")        { Invoke-GateRun 'checkstyle failed' $Dir "$Dir/mvnw" @('checkstyle:check') }
            elseif (Test-Path "$Dir/gradlew") { Invoke-GateRun 'checkstyle failed' $Dir "$Dir/gradlew" @('checkstyleMain') }
            else { Set-GateSkip 'linter not installed' }
        }
        'coverage' { return Get-JacocoLinePct $Dir }
    }
}

function Recipe-kotlin { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect' {
            if (Test-Path "$Dir/build.gradle.kts") { return $true }
            return ((Test-Path "$Dir/build.gradle") -and [bool](Get-ChildItem -Path $Dir -Filter '*.kt' -ErrorAction SilentlyContinue))
        }
        'has_tests' { return (Test-Path "$Dir/src/test") }
        'build' {
            if (Test-Path "$Dir/gradlew") { Invoke-GateRun 'gradlew assemble failed' $Dir "$Dir/gradlew" @('assemble') }
            else { Set-GateSkip 'toolchain not installed' }
        }
        'test' { Invoke-JvmTest $Dir }
        'lint' {
            if (Test-Path "$Dir/gradlew") { Invoke-GateRun 'ktlint failed' $Dir "$Dir/gradlew" @('ktlintCheck') }
            else { Set-GateSkip 'linter not installed' }
        }
        'coverage' { return Get-JacocoLinePct $Dir }
    }
}

function Recipe-go { param([string]$Req, [string]$Dir)
    switch ($Req) {
        # go.mod is canonical — *.go files may appear in vendor/ of non-Go projects
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
            if (Find-Cmd 'cargo') { Invoke-GateRun 'cargo test failed' $Dir 'cargo' @('test','--lib') }
            else { Set-GateSkip 'toolchain not installed (cargo not found)' }
        }
        'lint' {
            if (Find-Cmd 'cargo') { Invoke-GateRun 'clippy failed' $Dir 'cargo' @('clippy','--','-D','warnings') }
            else { Set-GateSkip 'toolchain not installed (cargo not found)' }
        }
        'coverage' {
            if ($script:Gate.CovContent -match 'TOTAL\s+.*\s+([\d.]+)%') { return [double]$Matches[1] }
            if ($script:Gate.CovContent -match '([\d.]+)% coverage') { return [double]$Matches[1] }
        }
    }
}

function Recipe-dotnet { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect' {
            return ([bool](Get-ChildItem -Path $Dir -Filter '*.csproj' -ErrorAction SilentlyContinue) -or
                    [bool](Get-ChildItem -Path $Dir -Filter '*.sln' -ErrorAction SilentlyContinue) -or
                    (Test-Path "$Dir/global.json"))
        }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*Tests.cs','*Test.cs' -ErrorAction SilentlyContinue | Select-Object -First 1) }
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
        'coverage' { Set-GateCoverageUnsupported }
    }
}

function Recipe-ruby { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect'    { return (Test-Path "$Dir/Gemfile") }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*_spec.rb','*_test.rb' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if ((Find-Cmd 'bundle') -and (Test-Path "$Dir/Rakefile") -and ((Get-Content "$Dir/Rakefile" -Raw) -match 'build')) {
                Invoke-GateRun 'rake build failed' $Dir 'bundle' @('exec','rake','build')
            } else { Set-GateSkip 'no build step detected' }
        }
        'test' {
            if (Find-Cmd 'bundle') {
                Invoke-GateSeq $Dir 'or' @((New-GateStep 'bundle' @('exec','rspec','--tag','unit','spec/')),
                                           (New-GateStep 'bundle' @('exec','rspec','spec/')))
                Complete-Gate 'rspec failed'
            } else { Set-GateSkip 'toolchain not installed (bundle not found)' }
        }
        'lint' {
            if (Find-Cmd 'bundle') { Invoke-GateRun 'rubocop failed' $Dir 'bundle' @('exec','rubocop') }
            else { Set-GateSkip 'linter not installed (bundle not found)' }
        }
        'coverage' { Set-GateCoverageUnsupported }
    }
}

function Recipe-php { param([string]$Req, [string]$Dir)
    switch ($Req) {
        'detect'    { return (Test-Path "$Dir/composer.json") }
        'has_tests' { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*Test.php' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'build' {
            if (Find-Cmd 'composer') { Invoke-GateRun 'composer install failed' $Dir 'composer' @('install','--no-dev') }
            else { Set-GateSkip 'toolchain not installed (composer not found)' }
        }
        'test' {
            if (Test-Path "$Dir/vendor/bin/phpunit") { Invoke-GateRun 'phpunit failed' $Dir "$Dir/vendor/bin/phpunit" @('--coverage-text') }
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
            if (Find-Cmd 'swift') { Invoke-GateRun 'swift test failed' $Dir 'swift' @('test','--enable-code-coverage') }
            else { Set-GateSkip 'toolchain not installed (swift not found)' }
        }
        'lint' {
            if (Find-Cmd 'swiftlint') { Invoke-GateRun 'swiftlint failed' $Dir 'swiftlint' @() }
            else { Set-GateSkip 'linter not installed (swiftlint not found)' }
        }
        'coverage' { Set-GateCoverageUnsupported }
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
            if (Find-Cmd 'ctest') {
                Set-GateNoCoverage
                Invoke-GateRun 'ctest failed' $Dir 'ctest' @('--test-dir','build')
            } else { Set-GateSkip 'toolchain not installed (ctest not found)' }
        }
        'lint' {
            if (-not (Find-Cmd 'clang-tidy')) { Set-GateSkip 'linter not installed (clang-tidy not found)'; return }
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
                Invoke-GateSeq $Dir 'or' @((New-GateStep 'mix' @('test','--only','unit')), (New-GateStep 'mix' @('test')))
                Complete-Gate 'mix test failed'
            } else { Set-GateSkip 'toolchain not installed (mix not found)' }
        }
        'lint' {
            if (Find-Cmd 'mix') { Invoke-GateRun 'mix credo failed' $Dir 'mix' @('credo') }
            else { Set-GateSkip 'toolchain not installed (mix not found)' }
        }
        'coverage' {
            if ($script:Gate.CovContent -match '([\d.]+)% \| Total') { return [double]$Matches[1] }
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
                Invoke-GateSeq $Dir 'or' @((New-GateStep 'sbt' @('testOnly *Unit*')), (New-GateStep 'sbt' @('test')))
                Complete-Gate 'sbt test failed'
            } else { Set-GateSkip 'toolchain not installed (sbt not found)' }
        }
        'lint' {
            if (Find-Cmd 'sbt') { Invoke-GateRun 'scalastyle failed' $Dir 'sbt' @('scalastyle') }
            else { Set-GateSkip 'toolchain not installed (sbt not found)' }
        }
        'coverage' { Set-GateCoverageUnsupported }
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

Get-ChildItem -Path $InvocationDir -Directory | Where-Object { -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) } | ForEach-Object {
    $subLang = Get-Lang $_.FullName
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
          [object]$Threshold = $null)
    # One immutable-by-convention Gate Result, written once; read only by
    # Write-ValidationReport and the summary table.
    $GateResults["$Proj|$Lang|$Gate"] = [pscustomobject]@{
        Status      = $Status
        Reason      = $Reason
        ExitCode    = $ExitCode
        Duration    = [Math]::Round($Duration, 1)
        LogFile     = $LogFile
        LineCovPct  = $LineCovPct
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
# Coverage Gate (parses the output captured by the test Gate — no re-run)
# ---------------------------------------------------------------------------
function Invoke-CoverageGate { param($P)
    $pd = $P.Dir; $abs = $P.AbsDir; $lang = $P.Lang
    Write-GateLine $pd $lang 'coverage' 'RUNNING'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = 'SKIPPED'; $rs = ''; $ex = $null; $lf = $null; $lpct = $null
    $thr = Get-Threshold $lang

    if ($DryRun) {
        Write-Host '[DRY RUN] coverage parse (no re-run)'
        $sw.Stop(); Write-GateLine $pd $lang 'coverage' 'SKIPPED' 'dry-run mode'
        Set-GateResult $pd $lang 'coverage' 'SKIPPED' 'dry-run mode' $null $sw.Elapsed.TotalSeconds $null $null $thr
        return
    }

    $covFile = Join-Path $WorkDir "COV_${pd}_${lang}.txt"
    if (-not (Test-Path $covFile)) {
        $st='SKIPPED'; $rs='no coverage data (test gate skipped or failed)'
        $sw.Stop(); Write-GateLine $pd $lang 'coverage' $st $rs
        Set-GateResult $pd $lang 'coverage' $st $rs $null $sw.Elapsed.TotalSeconds $null $null $thr
        return
    }

    $covContent = Get-Content $covFile -Raw

    # Parse line coverage with the Language Recipe
    New-GateState
    $script:Gate.CovContent = $covContent
    $lpct = & "Recipe-$lang" 'coverage' $abs
    if ($script:Gate.CovUnsupported) {
        $st='SKIPPED'; $rs="coverage parsing not implemented for $lang"
        $sw.Stop(); Write-GateLine $pd $lang 'coverage' $st $rs
        Set-GateResult $pd $lang 'coverage' $st $rs $null $sw.Elapsed.TotalSeconds $null $null $thr
        return
    }

    if ($null -eq $lpct) {
        $st='SKIPPED'; $rs='coverage output unparseable'
        $rawLog = Join-Path $LogDir "${pd}-${lang}-coverage-raw.log"
        Set-Content $rawLog $covContent -Encoding UTF8
        $lf = "validation-logs/${pd}-${lang}-coverage-raw.log"
    } elseif ($lpct -ge $thr) {
        $st='PASS'; $rs=''
    } else {
        $st='FAIL'; $rs="${lpct}% < ${thr}% threshold"
        $lf = Save-Sidecar $pd $lang 'coverage' $rs
    }

    $sw.Stop()
    $detail = if ($lpct) { "(${lpct}% vs ${thr}%, $([Math]::Round($sw.Elapsed.TotalSeconds,1))s)" } else { "($([Math]::Round($sw.Elapsed.TotalSeconds,1))s)" }
    Write-GateLine $pd $lang 'coverage' $st $detail
    Set-GateResult $pd $lang 'coverage' $st $rs $ex $sw.Elapsed.TotalSeconds $lf $lpct $thr
}

# ---------------------------------------------------------------------------
# Run all gates
# ---------------------------------------------------------------------------
foreach ($proj in $Projects) {
    Write-Host "── [$($proj.Dir) / $($proj.Lang)] ──────────────────────────────────"
    Invoke-Gate 'build' $proj
    Invoke-Gate 'test'  $proj
    Invoke-Gate 'lint'  $proj
    Invoke-CoverageGate $proj
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Compute overall result
# ---------------------------------------------------------------------------
$overallPass = $true
$totalProjects = $Projects.Count
$totalGates = 0; $passed = 0; $failed = 0; $skipped = 0

foreach ($key in $GateResults.Keys) {
    $totalGates++
    switch ($GateResults[$key].Status) {
        'PASS'    { $passed++ }
        'FAIL'    { $failed++; $overallPass = $false }
        'SKIPPED' { $skipped++ }
    }
}

# ---------------------------------------------------------------------------
# Validation Report writer — owns the pinned schema, field order and null
# handling (ADR-0002). Reads Gate Results; totals are computed above.
# ---------------------------------------------------------------------------
function Write-ValidationReport {
    $ts = (Get-Date -AsUTC).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $projectsArr = $Projects | ForEach-Object {
        $pd = $_.Dir; $lang = $_.Lang
        $gates = [ordered]@{}
        foreach ($gate in @('build','test','lint','coverage')) {
            $r = $GateResults["$pd|$lang|$gate"]
            $gObj = [ordered]@{
                status           = $r.Status
                duration_seconds = $r.Duration
                exit_code        = $r.ExitCode
                reason           = if ($r.Reason) { $r.Reason } else { $null }
                log_file         = $r.LogFile
            }
            if ($gate -eq 'coverage') {
                $gObj['line_coverage_pct']     = $(if ($null -ne $r.LineCovPct -and $r.LineCovPct -eq [math]::Floor($r.LineCovPct)) { [int]$r.LineCovPct } else { $r.LineCovPct })
                $gObj['branch_coverage_pct']   = $null
                $gObj['function_coverage_pct'] = $null
                $gObj['threshold_pct']         = $r.Threshold
            }
            $gates[$gate] = $gObj
        }
        [ordered]@{ project_dir = $pd; language = $lang; gates = $gates }
    }

    $report = [ordered]@{
        validator_version = $VALIDATOR_VERSION
        timestamp         = $ts
        invocation_dir    = $InvocationDir
        overall_pass      = $overallPass
        projects          = @($projectsArr)
        summary           = [ordered]@{
            total_projects = $totalProjects
            total_gates_run = $totalGates
            passed  = $passed
            failed  = $failed
            skipped = $skipped
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
    $pd = $proj.Dir; $lang = $proj.Lang
    foreach ($gate in @('build','test','lint','coverage')) {
        $r = $GateResults["$pd|$lang|$gate"]
        $detail = if ($r.Reason) { $r.Reason.Substring(0, [Math]::Min(42, $r.Reason.Length)) } else { '' }
        Write-Host ('│ {0,-12} │ {1,-10} │ {2,-9} │ {3,-8} │ {4,-42} │' -f $pd, $lang, $gate, $r.Status, $detail)
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
