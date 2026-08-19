# Demo Navigation Script (PowerShell)
# Usage: .\demo.ps1 [list|next|prev|jump <number>|discard-changes|reset|run|add-step <slug> <message>]

param(
    [Parameter(Position=0)]
    [string]$Command,
    # Step number for 'jump', step slug for 'add-step'
    [Parameter(Position=1)]
    [string]$StepNumber,
    # Commit message for 'add-step'
    [Parameter(Position=2)]
    [string]$Message
)

$Root = git rev-parse --show-toplevel 2>$null
if (-not $Root) { $Root = "." }

# Optional per-project settings, see DEMO-CONTROLS.md. None of them are required.
#   DEMO_RUN_CMD      what '.\demo.ps1 run' starts
#   DEMO_AFTER_STEP   command that refreshes the app after the code changes
#   DEMO_MAIN_BRANCH  branch that 'reset' returns to (default: main)
# (demo.conf is a shell file; we read the simple KEY=value lines and ignore the rest.)
$Conf = @{}
$ConfPath = Join-Path $Root "demo.conf"
if (Test-Path $ConfPath) {
    foreach ($Line in (Get-Content $ConfPath)) {
        if ($Line -match '^\s*([A-Z_]+)\s*=\s*"?([^"#]*?)"?\s*$') {
            $Conf[$matches[1]] = $matches[2]
        }
    }
}

# Written by '.\demo.ps1 run'. Git ignores it, so step changes leave it alone.
$PidFile = Join-Path $Root ".demo-app.pid"

# Get all step tags sorted naturally
$Steps = @(git tag -l "step-*" | Sort-Object {
    if ($_ -match 'step-(\d+)') {
        [int]$matches[1]
    } else {
        0
    }
})

# Get current tag (if on a tagged commit)
$Current = git describe --tags --exact-match 2>$null
if ($LASTEXITCODE -ne 0) { $Current = "" }

# Function: Bail out if this repo has no step tags yet
function Require-Steps {
    if ($Steps.Count -eq 0) {
        Write-Host "[ERROR] No 'step-*' tags found in this repository" -ForegroundColor Red
        Write-Host "   Demo steps must be tagged 'step-NN-slug' (e.g. step-01-counter)."
        Write-Host "   See DEMO-CONTROLS.md for the naming convention and how to author a demo."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Refreshing the running app after a step change.
#
# Most dev servers watch the filesystem and reload themselves when the files
# change under them (Vite, Next, CRA, nodemon, dotnet watch), so for those
# projects everything below does nothing at all and nothing needs configuring.
#
# Flutter is the exception: 'flutter run' does not watch files. On macOS and
# Linux demo.sh signals it directly; Windows has no SIGUSR1, so here we can only
# remind you to press R. See DEMO-CONTROLS.md for a VS Code keybinding that
# automates it.
# ---------------------------------------------------------------------------

function Test-FlutterProject {
    $Pubspec = Join-Path $Root "pubspec.yaml"
    return (Test-Path $Pubspec) -and ((Get-Content $Pubspec -Raw) -match '(?m)^\s*flutter:')
}

# Called after every navigation command. Never fails, and stays silent on
# projects that refresh themselves.
function Notify-App {
    param([switch]$Manual)

    if ($Conf.ContainsKey("DEMO_AFTER_STEP") -and $Conf["DEMO_AFTER_STEP"]) {
        try { Invoke-Expression $Conf["DEMO_AFTER_STEP"] } catch { }
        return
    }

    if (Test-FlutterProject) {
        # Only worth saying when something is actually running, or when asked.
        $App = Get-Process dart -ErrorAction SilentlyContinue
        if ($App -or $Manual) {
            Write-Host "[INFO] Windows cannot signal the app: press R in the Flutter terminal to refresh it" -ForegroundColor Yellow
        }
    }
}

# Function: Start the app for this project
function Run-App {
    Set-Location $Root

    if ($Conf.ContainsKey("DEMO_RUN_CMD") -and $Conf["DEMO_RUN_CMD"]) {
        Write-Host "[RUN] $($Conf['DEMO_RUN_CMD'])" -ForegroundColor Cyan
        Invoke-Expression $Conf["DEMO_RUN_CMD"]
        return
    }

    if (Test-FlutterProject) {
        if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
            Write-Host "[ERROR] 'flutter' is not on your PATH" -ForegroundColor Red
            Write-Host "   Install Flutter, or set DEMO_RUN_CMD in demo.conf."
            exit 1
        }
        Write-Host "[RUN] flutter run --pid-file .demo-app.pid" -ForegroundColor Cyan
        flutter run --pid-file $PidFile
        return
    }

    Write-Host "[INFO] No run command configured for this project." -ForegroundColor Yellow
    Write-Host "   Set DEMO_RUN_CMD in demo.conf, or just start your app the usual way."
    Write-Host "   Step changes work either way; most dev servers reload themselves."
}

# Function: Discard all changes
function Discard-Changes {
    Write-Host "[DISCARD] Discarding all changes..." -ForegroundColor Yellow

    # Reset all tracked files to their last committed state
    git reset --hard HEAD 2>$null | Out-Null

    # Remove all untracked files and directories
    git clean -fd 2>$null | Out-Null

    Write-Host "[OK] All changes discarded" -ForegroundColor Green
}

# Function: Return to the demo's home branch (leaves detached HEAD)
#
# Almost always 'main'. The exception is a starter/solution repo, where 'main'
# holds the starter code WITHOUT this tooling and the demo lives on a branch of
# its own: checking out 'main' there would delete demo.ps1 and the buttons from
# under you mid-lecture. Those repos set DEMO_MAIN_BRANCH in demo.conf.
function Reset-ToMain {
    # Discard any changes before switching
    Discard-Changes

    $Branch = "main"
    if ($Conf.ContainsKey("DEMO_MAIN_BRANCH") -and $Conf["DEMO_MAIN_BRANCH"]) {
        $Branch = $Conf["DEMO_MAIN_BRANCH"]
    }

    git checkout $Branch 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[DONE] Back on the $Branch branch" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Could not checkout $Branch" -ForegroundColor Red
        exit 1
    }
}

# Function: List all available steps
function List-Steps {
    Require-Steps

    Write-Host "Available Demo Steps:" -ForegroundColor Cyan
    Write-Host "======================="

    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $Step = $Steps[$i]
        # Get commit message for this tag
        $Message = (git log -1 --pretty=%B $Step 2>$null | Select-Object -First 1)

        # Mark current step
        if ($Step -eq $Current) {
            Write-Host ">> $($i + 1). $Step - $Message" -ForegroundColor Green
        } else {
            Write-Host "   $($i + 1). $Step - $Message"
        }
    }

    Write-Host ""
    Write-Host "Total: $($Steps.Count) steps"

    if ($Current) {
        Write-Host "Current: $Current" -ForegroundColor Cyan
    } else {
        Write-Host "Current: Not on a step tag" -ForegroundColor Yellow
    }
}

# Function: Move to next step
function Next-Step {
    Require-Steps

    # Discard any changes before switching
    Discard-Changes

    # Find current step index
    $CurrentIndex = -1
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i] -eq $Current) {
            $CurrentIndex = $i
            break
        }
    }

    # If not on a tagged commit, start from the beginning
    if ($CurrentIndex -eq -1) {
        Write-Host "[INFO] Not on a step tag. Starting from $($Steps[0])..." -ForegroundColor Yellow
        git checkout $Steps[0] 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Moved to $($Steps[0])" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Could not checkout $($Steps[0])" -ForegroundColor Red
        }
        return
    }

    # Go to next step
    $NextIndex = $CurrentIndex + 1
    if ($NextIndex -lt $Steps.Count) {
        git checkout $Steps[$NextIndex] 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Moved to $($Steps[$NextIndex]) ($($NextIndex + 1)/$($Steps.Count))" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Could not checkout $($Steps[$NextIndex])" -ForegroundColor Red
        }
    } else {
        Write-Host "[DONE] Already at the last step: $Current" -ForegroundColor Yellow
        Write-Host "   Run `".\demo.ps1 reset`" to return to main branch"
    }
}

# Function: Move to previous step
function Prev-Step {
    Require-Steps

    # Discard any changes before switching
    Discard-Changes

    # Find current step index
    $CurrentIndex = -1
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i] -eq $Current) {
            $CurrentIndex = $i
            break
        }
    }

    # If not on a tagged commit, warn user
    if ($CurrentIndex -eq -1) {
        Write-Host "[INFO] Not on a step tag. Use `".\demo.ps1 list`" to see available steps." -ForegroundColor Yellow
        exit 1
    }

    # Go to previous step
    $PrevIndex = $CurrentIndex - 1
    if ($PrevIndex -ge 0) {
        git checkout $Steps[$PrevIndex] 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Moved to $($Steps[$PrevIndex]) ($($PrevIndex + 1)/$($Steps.Count))" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Could not checkout $($Steps[$PrevIndex])" -ForegroundColor Red
        }
    } else {
        Write-Host "[DONE] Already at the first step: $Current" -ForegroundColor Yellow
    }
}

# Function: Jump to a specific step number
function Jump-ToStep {
    param([string]$StepNum)

    Require-Steps

    if ([string]::IsNullOrEmpty($StepNum)) {
        Write-Host "[ERROR] Please provide a step number" -ForegroundColor Red
        Write-Host "Usage: .\demo.ps1 jump <number>"
        exit 1
    }

    # Discard any changes before switching
    Discard-Changes

    # Find the step matching step-{number}*
    $TargetStep = $Steps | Where-Object { $_ -eq "step-$StepNum" -or $_ -like "step-$StepNum-*" } | Select-Object -First 1

    if ([string]::IsNullOrEmpty($TargetStep)) {
        Write-Host "[ERROR] Step $StepNum not found" -ForegroundColor Red
        Write-Host "Run `".\demo.ps1 list`" to see available steps"
        exit 1
    }

    # Checkout the target step
    git checkout $TargetStep 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Jumped to $TargetStep" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Could not checkout $TargetStep" -ForegroundColor Red
        exit 1
    }
}

# Function: Commit the current work as the next demo step
function Add-Step {
    param([string]$Slug, [string]$CommitMessage)

    if ([string]::IsNullOrEmpty($Slug) -or [string]::IsNullOrEmpty($CommitMessage)) {
        Write-Host "[ERROR] Please provide a slug and a commit message" -ForegroundColor Red
        Write-Host "Usage: .\demo.ps1 add-step <slug> `"<commit message>`""
        Write-Host "Example: .\demo.ps1 add-step model `"Add the KaiEvent model`""
        exit 1
    }

    # The slug becomes part of a tag name, so keep it simple and predictable
    # (-cnotmatch, because -notmatch would let uppercase through)
    if ($Slug -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        Write-Host "[ERROR] Invalid slug '$Slug'" -ForegroundColor Red
        Write-Host "   Use lowercase letters, digits and hyphens only (e.g. 'favourite-button')"
        exit 1
    }

    # A commit made on a detached HEAD is destroyed by the next step change
    git symbolic-ref -q HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] You are on a step tag (detached HEAD), not a branch" -ForegroundColor Red
        Write-Host "   Run `".\demo.ps1 reset`" to get back to main, then try again."
        exit 1
    }

    # Work from the repo root so that 'git add' covers the whole project
    $Root = git rev-parse --show-toplevel
    Set-Location $Root

    if (-not (git status --porcelain)) {
        Write-Host "[ERROR] Nothing to commit, the working tree is clean" -ForegroundColor Red
        Write-Host "   Make the changes for this step first, then run add-step."
        exit 1
    }

    # Next number is the highest existing one plus one, so gaps never collide
    $Max = 0
    foreach ($Step in @(git tag -l "step-*")) {
        if ($Step -match '^step-0*(\d+)') {
            $Num = [int]$matches[1]
            if ($Num -gt $Max) { $Max = $Num }
        }
    }
    $Tag = "step-{0:d2}-{1}" -f ($Max + 1), $Slug

    git rev-parse -q --verify "refs/tags/$Tag" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[ERROR] Tag $Tag already exists" -ForegroundColor Red
        exit 1
    }

    git add -A
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Could not stage changes, nothing committed" -ForegroundColor Red
        exit 1
    }

    git commit -q -m $CommitMessage
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Commit failed, no tag created" -ForegroundColor Red
        exit 1
    }

    git tag $Tag
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Committed, but tagging failed" -ForegroundColor Red
        Write-Host "   Tag it yourself with: git tag $Tag"
        exit 1
    }

    $ShortSha = git rev-parse --short HEAD
    Write-Host "[OK] Added $Tag ($ShortSha)" -ForegroundColor Green
    Write-Host "   $CommitMessage"
    Write-Host "   Remember to add this step to the table in README.md"
}

# Main script logic
switch ("$Command".ToLower()) {
    "list" {
        List-Steps
    }
    "next" {
        try { Next-Step } finally { Notify-App }
    }
    "prev" {
        try { Prev-Step } finally { Notify-App }
    }
    "jump" {
        try { Jump-ToStep -StepNum $StepNumber } finally { Notify-App }
    }
    "discard-changes" {
        try { Discard-Changes } finally { Notify-App }
    }
    "reset" {
        try { Reset-ToMain } finally { Notify-App }
    }
    "main" {
        try { Reset-ToMain } finally { Notify-App }
    }
    "run" {
        Run-App
    }
    "reload" {
        Notify-App -Manual
    }
    "restart" {
        Notify-App -Manual
    }
    "add-step" {
        Add-Step -Slug $StepNumber -CommitMessage $Message
    }
    "update-all" {
        # Rewriting nine commits and re-pointing their tags is not something to
        # ship untested, and this script cannot be tested on the machine the
        # demos are authored on. DEMO-CONTROLS.md has the git commands.
        Write-Host "[INFO] 'update-all' is only implemented in demo.sh (macOS/Linux)." -ForegroundColor Yellow
        Write-Host "   See 'Changing something in every step' in DEMO-CONTROLS.md for"
        Write-Host "   the git commands to do the same thing by hand."
    }
    default {
        Write-Host "Usage: .\demo.ps1 [list|next|prev|jump <number>|discard-changes|reset|run|add-step <slug> <message>]" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  list            - Show all available demo steps"
        Write-Host "  next            - Move to the next step"
        Write-Host "  prev            - Move to the previous step"
        Write-Host "  jump <number>   - Jump to a specific step (e.g., `".\demo.ps1 jump 23`")"
        Write-Host "  discard-changes - Discard all changes (modifications, additions, deletions)"
        Write-Host "  reset           - Leave the demo and return to the main branch"
        Write-Host ""
        Write-Host "Running the app:"
        Write-Host "  run             - Start the app (Flutter projects need no setup)"
        Write-Host "  reload          - Refresh the running app by hand"
        Write-Host ""
        Write-Host "Authoring:"
        Write-Host "  update-all <message>      - Commit the current work into every step (demo.sh only)"
        Write-Host "  add-step <slug> <message> - Commit the current work as the next step and tag it"
        Write-Host "                              Example: .\demo.ps1 add-step model `"Add the KaiEvent model`""
        exit 1
    }
}
