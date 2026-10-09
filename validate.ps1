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

function Read-Conf {
    if (-not (Test-Path '.validation.conf')) { return }
    Get-Content '.validation.conf' | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = ($Matches[2] -replace '#.*$','').Trim()
            switch -Regex ($k) {
                '^COVERAGE_THRESHOLD$'      { $script:CoverageThreshold = [int]$v }
                '^VERBOSE$'                 { if ($v -eq 'true') { $script:VerboseMode = $true } }
                '^COVERAGE_THRESHOLD_(.+)$' { $script:LangThresholds[$Matches[1].ToLower()] = [int]$v }
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
# Language detection — file presence only
# ---------------------------------------------------------------------------
function Get-Lang { param([string]$Dir)
    if (Test-Path "$Dir/package.json")     { return 'typescript' }
    if ((Test-Path "$Dir/pyproject.toml") -or (Test-Path "$Dir/setup.py") -or
        (Test-Path "$Dir/setup.cfg")      -or (Test-Path "$Dir/requirements.txt")) { return 'python' }
    if (Test-Path "$Dir/build.gradle.kts") { return 'kotlin' }
    $ktFiles = Get-ChildItem -Path $Dir -Filter '*.kt' -ErrorAction SilentlyContinue
    if ((Test-Path "$Dir/build.gradle") -and $ktFiles) { return 'kotlin' }
    if ((Test-Path "$Dir/pom.xml") -or (Test-Path "$Dir/build.gradle")) { return 'java' }
    if (Test-Path "$Dir/go.mod")           { return 'go' }
    if (Test-Path "$Dir/Cargo.toml")       { return 'rust' }
    $csproj = Get-ChildItem -Path $Dir -Filter '*.csproj' -ErrorAction SilentlyContinue
    $sln    = Get-ChildItem -Path $Dir -Filter '*.sln'    -ErrorAction SilentlyContinue
    if ($csproj -or $sln -or (Test-Path "$Dir/global.json")) { return 'dotnet' }
    if (Test-Path "$Dir/Gemfile")          { return 'ruby' }
    if (Test-Path "$Dir/composer.json")    { return 'php' }
    if ((Test-Path "$Dir/Package.swift") -or
        (Get-ChildItem -Path $Dir -Filter '*.xcodeproj' -ErrorAction SilentlyContinue)) { return 'swift' }
    if (Test-Path "$Dir/CMakeLists.txt")   { return 'cpp' }
    $cFiles = Get-ChildItem -Path $Dir -Filter '*.c'   -ErrorAction SilentlyContinue
    $cppFiles = Get-ChildItem -Path $Dir -Filter '*.cpp' -ErrorAction SilentlyContinue
    if ((Test-Path "$Dir/Makefile") -and ($cFiles -or $cppFiles)) { return 'cpp' }
    if (Test-Path "$Dir/mix.exs")          { return 'elixir' }
    if (Test-Path "$Dir/build.sbt")        { return 'scala' }
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
$GateResults = @{}  # key: "proj|lang|gate" → hashtable

function Set-GateResult {
    param([string]$Proj, [string]$Lang, [string]$Gate, [string]$Status,
          [string]$Reason = '', [object]$ExitCode = $null, [double]$Duration = 0,
          [string]$LogFile = $null, [object]$LineCovPct = $null,
          [object]$Threshold = $null)
    $GateResults["$Proj|$Lang|$Gate"] = @{
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
    $psi.Arguments              = $ArgumentList -join ' '
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

# ---------------------------------------------------------------------------
# Test file detection
# ---------------------------------------------------------------------------
function Test-HasTestFiles { param([string]$Dir, [string]$Lang)
    switch ($Lang) {
        'typescript' {
            $patterns = '*.test.js','*.test.ts','*.test.jsx','*.test.tsx','*.spec.js','*.spec.ts','*.spec.jsx','*.spec.tsx'
            foreach ($p in $patterns) {
                if (Get-ChildItem -Path $Dir -Filter $p -Recurse -Exclude 'node_modules' -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
            }
            return $false
        }
        'python'  { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include 'test_*.py','*_test.py' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'java','kotlin' { return Test-Path "$Dir/src/test" }
        'go'      { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*_test.go' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'rust'    { return (Test-Path "$Dir/tests") -or ($null -ne (Select-String -Path "$Dir/src/*.rs" -Pattern '\[cfg\(test\)\]' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        'dotnet'  { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*Tests.cs','*Test.cs' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'ruby'    { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*_spec.rb','*_test.rb' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'php'     { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*Test.php' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'swift'   { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*Tests.swift' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'cpp'     { return (Test-Path "$Dir/test") -or (Test-Path "$Dir/tests") -or ($null -ne (Get-ChildItem -Path $Dir -Recurse -Include '*_test.c','*_test.cpp' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        'elixir'  { return $null -ne (Get-ChildItem -Path $Dir -Recurse -Filter '*_test.exs' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        'scala'   { return Test-Path "$Dir/src/test" }
        default   { return $false }
    }
}

# ---------------------------------------------------------------------------
# Gate runners
# ---------------------------------------------------------------------------
function Invoke-BuildGate { param($P)
    $pd = $P.Dir; $abs = $P.AbsDir; $lang = $P.Lang
    Write-GateLine $pd $lang 'build' 'RUNNING'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = 'SKIPPED'; $rs = 'no build command applies'; $ex = $null; $lf = $null

    switch ($lang) {
        'typescript' {
            if (-not (Find-Cmd 'npm')) { $st='SKIPPED'; $rs='toolchain not installed (npm not found)'; break }
            $pkgJson = Get-Content "$abs/package.json" -Raw | ConvertFrom-Json
            if ($pkgJson.scripts.build) {
                $r = Invoke-Tool $abs @('run','build') 'npm'
                if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs="npm run build failed (exit $($r.ExitCode))"; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
            } elseif (Test-Path "$abs/node_modules/.bin/tsc") {
                $r = Invoke-Tool $abs @('--noEmit') "$abs/node_modules/.bin/tsc"
                if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs="tsc failed"; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
            } else { $st='SKIPPED'; $rs='no build script and tsc not found' }
        }
        'python' {
            $py = (Get-Command 'python3' -ErrorAction SilentlyContinue)?.Source ?? (Get-Command 'python' -ErrorAction SilentlyContinue)?.Source
            if ($py -and (& $py -c "import build" 2>$null; $?)) {
                $r = Invoke-Tool $abs @('-m','build') $py
                if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='python build failed'; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
            } elseif (Find-Cmd 'poetry') {
                $r = Invoke-Tool $abs @('build') 'poetry'
                if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='poetry build failed'; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
            } else { $st='SKIPPED'; $rs='no build tool detected' }
        }
        'go' {
            if (Find-Cmd 'go') {
                $r = Invoke-Tool $abs @('build','./...') 'go'
                if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='go build failed'; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
            } else { $st='SKIPPED'; $rs='toolchain not installed (go not found)' }
        }
        'rust' {
            if (Find-Cmd 'cargo') {
                $r = Invoke-Tool $abs @('build') 'cargo'
                if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='cargo build failed'; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
            } else { $st='SKIPPED'; $rs='toolchain not installed (cargo not found)' }
        }
        'dotnet' {
            if (Find-Cmd 'dotnet') {
                $r1 = Invoke-Tool $abs @('restore') 'dotnet'
                if ($r1.ExitCode -ne 0) {
                    $st='FAIL'; $ex=$r1.ExitCode; $rs='dotnet restore failed'; $lf=Save-Sidecar $pd $lang 'build' $r1.Output
                } else {
                    $r = Invoke-Tool $abs @('build') 'dotnet'
                    if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
                    else { $st='FAIL'; $ex=$r.ExitCode; $rs='dotnet build failed'; $lf=Save-Sidecar $pd $lang 'build' $r.Output }
                }
            } else { $st='SKIPPED'; $rs='toolchain not installed (dotnet not found)' }
        }
        default { $st='SKIPPED'; $rs='build not implemented for this language' }
    }

    $sw.Stop()
    Write-GateLine $pd $lang 'build' $st "($([Math]::Round($sw.Elapsed.TotalSeconds,1))s)"
    Set-GateResult $pd $lang 'build' $st $rs $ex $sw.Elapsed.TotalSeconds $lf
}

function Invoke-TestGate { param($P)
    $pd = $P.Dir; $abs = $P.AbsDir; $lang = $P.Lang
    Write-GateLine $pd $lang 'test' 'RUNNING'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = 'SKIPPED'; $rs = ''; $ex = $null; $lf = $null; $covOutput = $null

    # Hard FAIL if no test files
    if (-not (Test-HasTestFiles $abs $lang)) {
        $st = 'FAIL'; $ex = 1
        $rs = 'No test files detected — a project must have tests to be reviewable'
        $lf = Save-Sidecar $pd $lang 'test' $rs
        $sw.Stop()
        Write-GateLine $pd $lang 'test' $st $rs
        Set-GateResult $pd $lang 'test' $st $rs $ex $sw.Elapsed.TotalSeconds $lf
        return
    }

    switch ($lang) {
        'typescript' {
            if (-not (Find-Cmd 'npm')) { $st='SKIPPED'; $rs='toolchain not installed'; break }
            $r = Invoke-Tool $abs @('test','--','--coverage','--coverageReporters=text','--testPathPattern=(unit|spec)','--forceExit') 'npm'
            # Fallback if no tests matched pattern
            if ($r.Output -match 'Your test suite must contain at least one test|No tests found') {
                $r = Invoke-Tool $abs @('test','--','--coverage','--coverageReporters=text','--forceExit') 'npm'
            }
            $covOutput = $r.Output
            if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
            else { $st='FAIL'; $ex=$r.ExitCode; $rs="npm test failed (exit $($r.ExitCode))"; $lf=Save-Sidecar $pd $lang 'test' $r.Output }
        }
        'python' {
            $py = (Get-Command 'python3' -ErrorAction SilentlyContinue)?.Source ?? (Get-Command 'python' -ErrorAction SilentlyContinue)?.Source
            if (-not $py) { $st='SKIPPED'; $rs='python not found'; break }
            $r = Invoke-Tool $abs @('-m','pytest','-m','unit','--cov=src','--cov-report=term-missing','-q') $py
            if ($r.ExitCode -eq 5) {
                $r = Invoke-Tool $abs @('-m','pytest','--cov=src','--cov-report=term-missing','-q') $py
            }
            $covOutput = $r.Output
            if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
            else { $st='FAIL'; $ex=$r.ExitCode; $rs="pytest failed (exit $($r.ExitCode))"; $lf=Save-Sidecar $pd $lang 'test' $r.Output }
        }
        'go' {
            if (-not (Find-Cmd 'go')) { $st='SKIPPED'; $rs='toolchain not installed'; break }
            $covOut = Join-Path $WorkDir 'go_coverage.out'
            $r = Invoke-Tool $abs @('test','-short',"-coverprofile=$covOut",'./...') 'go'
            if ($r.ExitCode -eq 0) {
                $r2 = Invoke-Tool $abs @('tool','cover',"-func=$covOut") 'go'
                $covOutput = $r.Output + $r2.Output
                $st='PASS'; $rs=''; $ex=0
            } else { $st='FAIL'; $ex=$r.ExitCode; $rs='go test failed'; $lf=Save-Sidecar $pd $lang 'test' $r.Output }
        }
        'rust' {
            if (-not (Find-Cmd 'cargo')) { $st='SKIPPED'; $rs='toolchain not installed'; break }
            $r = Invoke-Tool $abs @('test','--lib') 'cargo'
            $covOutput = $r.Output
            if ($r.ExitCode -eq 0) { $st='PASS'; $rs=''; $ex=0 }
            else { $st='FAIL'; $ex=$r.ExitCode; $rs='cargo test failed'; $lf=Save-Sidecar $pd $lang 'test' $r.Output }
        }
        default { $st='SKIPPED'; $rs='test not implemented for this language' }
    }

    # Store coverage output for Gate 4
    if ($covOutput) {
        $covFile = Join-Path $WorkDir "COV_${pd}_${lang}.txt"
        Set-Content -Path $covFile -Value $covOutput -Encoding UTF8
    }

    $sw.Stop()
    Write-GateLine $pd $lang 'test' $st "($([Math]::Round($sw.Elapsed.TotalSeconds,1))s)"
    Set-GateResult $pd $lang 'test' $st $rs $ex $sw.Elapsed.TotalSeconds $lf
}

function Invoke-LintGate { param($P)
    $pd = $P.Dir; $abs = $P.AbsDir; $lang = $P.Lang
    Write-GateLine $pd $lang 'lint' 'RUNNING'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = 'SKIPPED'; $rs = ''; $ex = $null; $lf = $null

    switch ($lang) {
        'typescript' {
            # Check for ESLint config before invoking
            $eslintConfigs = @('eslint.config.js','eslint.config.mjs','eslint.config.cjs','.eslintrc.js','.eslintrc.cjs','.eslintrc.yaml','.eslintrc.yml','.eslintrc.json')
            $hasConf = ($eslintConfigs | Where-Object { Test-Path "$abs/$_" }) -or
                       ((Test-Path "$abs/package.json") -and ((Get-Content "$abs/package.json" -Raw) -match '"eslintConfig"'))
            if (-not $hasConf) { $st='SKIPPED'; $rs='no ESLint config found'; break }
            $eslintBin = "$abs/node_modules/.bin/eslint"
            if (-not (Test-Path $eslintBin)) { $st='SKIPPED'; $rs='linter not installed (eslint not in node_modules/.bin)'; break }
            $r = Invoke-Tool $abs @('.') $eslintBin
            if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
            else { $st='FAIL'; $ex=$r.ExitCode; $rs="eslint failed (exit $($r.ExitCode))"; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
        }
        'python' {
            $py = (Get-Command 'python3' -ErrorAction SilentlyContinue)?.Source ?? (Get-Command 'python' -ErrorAction SilentlyContinue)?.Source
            $ruff = Get-Command 'ruff' -ErrorAction SilentlyContinue
            if ($ruff) {
                $r = Invoke-Tool $abs @('check','.') 'ruff'
                if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='ruff failed'; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
            } elseif ($py -and (& $py -m ruff --version 2>$null; $?)) {
                $r = Invoke-Tool $abs @('-m','ruff','check','.') $py
                if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='ruff failed'; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
            } elseif (Find-Cmd 'flake8') {
                $r = Invoke-Tool $abs @('.') 'flake8'
                if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='flake8 failed'; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
            } else { $st='SKIPPED'; $rs='linter not installed (ruff/flake8/pylint not found)' }
        }
        'go' {
            if (-not (Find-Cmd 'go')) { $st='SKIPPED'; $rs='toolchain not installed'; break }
            $linter = if (Find-Cmd 'golangci-lint') { 'golangci-lint' } else { $null }
            if ($linter) {
                $r = Invoke-Tool $abs @('run') $linter
            } else {
                $r = Invoke-Tool $abs @('vet','./...') 'go'
            }
            if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
            else { $st='FAIL'; $ex=$r.ExitCode; $rs='lint failed'; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
        }
        'rust' {
            if (Find-Cmd 'cargo') {
                $r = Invoke-Tool $abs @('clippy','--','-D','warnings') 'cargo'
                if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='clippy failed'; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
            } else { $st='SKIPPED'; $rs='toolchain not installed' }
        }
        'dotnet' {
            if (Find-Cmd 'dotnet') {
                $r = Invoke-Tool $abs @('format','--verify-no-changes') 'dotnet'
                if ($r.ExitCode -eq 0) { $st='PASS'; $ex=0 }
                else { $st='FAIL'; $ex=$r.ExitCode; $rs='dotnet format failed'; $lf=Save-Sidecar $pd $lang 'lint' $r.Output }
            } else { $st='SKIPPED'; $rs='toolchain not installed' }
        }
        default { $st='SKIPPED'; $rs='lint not implemented for this language' }
    }

    $sw.Stop()
    Write-GateLine $pd $lang 'lint' $st "($([Math]::Round($sw.Elapsed.TotalSeconds,1))s)"
    Set-GateResult $pd $lang 'lint' $st $rs $ex $sw.Elapsed.TotalSeconds $lf
}

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

    # Parse line coverage
    switch ($lang) {
        'typescript' {
            if ($covContent -match 'All files\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)') {
                $lpct = [double]$Matches[4]  # Lines column (4th)
            }
        }
        'python' {
            if ($covContent -match '(?m)^TOTAL\s+\d+\s+\d+\s+([\d.]+)%') {
                $lpct = [double]$Matches[1]
            }
        }
        'go' {
            if ($covContent -match 'total:\s+\(statements\)\s+([\d.]+)%') {
                $lpct = [double]$Matches[1]
            }
        }
        'rust' {
            if ($covContent -match 'TOTAL\s+.*\s+([\d.]+)%') { $lpct = [double]$Matches[1] }
            elseif ($covContent -match '([\d.]+)% coverage') { $lpct = [double]$Matches[1] }
        }
        'php' {
            if ($covContent -match 'Lines:\s+([\d.]+)%') { $lpct = [double]$Matches[1] }
        }
        default {
            $st='SKIPPED'; $rs="coverage parsing not implemented for $lang"
            $sw.Stop(); Write-GateLine $pd $lang 'coverage' $st $rs
            Set-GateResult $pd $lang 'coverage' $st $rs $null $sw.Elapsed.TotalSeconds $null $null $thr
            return
        }
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
    Invoke-BuildGate $proj
    Invoke-TestGate  $proj
    Invoke-LintGate  $proj
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
# JSON report (uses ConvertTo-Json for correctness — ADR-0002)
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    $ts = (Get-Date -AsUTC).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $projectsArr = $Projects | ForEach-Object {
        $pd = $_.Dir; $lang = $_.Lang
        $gates = @{}
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
                $gObj['line_coverage_pct']     = $r.LineCovPct
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
