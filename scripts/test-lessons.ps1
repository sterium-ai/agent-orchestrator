# Self-test for scripts/lessons.ps1. Exits 0 only if every check below passes.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lessons.ps1')

$lessonsPath = Join-Path $repoRoot 'docs\agent-prompts\lessons.md'

$results = @()

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')

    $script:results += [PSCustomObject]@{ Name = $Name; Passed = $Passed; Detail = $Detail }
    if ($Passed) {
        Write-Host "PASS: $Name"
    }
    else {
        Write-Host "FAIL: $Name $Detail"
    }
}

function Test-LessonSetsEqual {
    param($A, $B)

    foreach ($section in @('Active', 'Retired')) {
        $arrA = @($A.$section)
        $arrB = @($B.$section)
        if ($arrA.Count -ne $arrB.Count) { return $false }
        for ($i = 0; $i -lt $arrA.Count; $i++) {
            $ea = $arrA[$i]
            $eb = $arrB[$i]
            foreach ($field in @('id', 'date', 'rule', 'doInstead', 'check', 'checkOn', 'source', 'hits', 'lastSeen')) {
                $va = $ea.$field
                $vb = $eb.$field
                if ($null -eq $va) { $va = '' }
                if ($null -eq $vb) { $vb = '' }
                if ("$va" -ne "$vb") { return $false }
            }
        }
    }
    return $true
}

# --- seed file shape ---

$seed = Read-Lessons -Path $lessonsPath

# lessons.md is a living file: the loop appends learned entries after the six curated seeds,
# so the invariant is "the six seeds are present and pinned", not "exactly six entries".
$seedEntries = @($seed.Active | Where-Object { "$($_.source)" -eq 'seed' })
Add-Result -Name 'seed-file-active-count' -Passed (($seedEntries.Count -eq 6) -and (@($seedEntries | Where-Object { $_.pinned }).Count -eq 6)) `
    -Detail "(expected 6 pinned seed entries, found $($seedEntries.Count) seeds, $(@($seedEntries | Where-Object { $_.pinned }).Count) pinned; $($seed.Active.Count) active in total)"

Add-Result -Name 'seed-file-retired-empty' -Passed ($seed.Retired.Count -eq 0) `
    -Detail "(expected 0 retired entries, found $($seed.Retired.Count))"

$checkCount = @($seed.Active | Where-Object { $_.check }).Count
Add-Result -Name 'seed-file-check-field-count' -Passed ($checkCount -eq 2) `
    -Detail "(expected exactly 2 active entries with a check field, found $checkCount)"
$unwired = @($seed.Active | Where-Object { $_.check -and ($_.checkOn -notin @('acceptance', 'test-additions')) })
Add-Result -Name 'seed-file-every-check-names-its-input' -Passed ($unwired.Count -eq 0) `
    -Detail "(checks without check-on: $(($unwired | ForEach-Object { $_.id }) -join ', '))"

$l001 = $seed.Active | Where-Object { $_.id -eq 'L-001' } | Select-Object -First 1
$l001Sample = 'powershell -NoProfile -Command "if ($result -eq 1) { exit 1 }"'
$l001Match = $l001 -and $l001.check -and ($l001Sample -match $l001.check)
Add-Result -Name 'check-regex-l001-matches-nested-powershell' -Passed ([bool]$l001Match)
Add-Result -Name 'check-on-l001-is-acceptance' -Passed ($l001 -and $l001.checkOn -eq 'acceptance')

$l002 = $seed.Active | Where-Object { $_.id -eq 'L-002' } | Select-Object -First 1
$l002Sample = 'Start-WebServer -Port 8080'
$l002Match = $l002 -and $l002.check -and ($l002Sample -match $l002.check)
Add-Result -Name 'check-regex-l002-matches-a-fixed-port' -Passed ([bool]$l002Match)
Add-Result -Name 'check-regex-l002-matches-a-fixed-localhost-url' -Passed ([bool]($l002 -and ('fetch("http://localhost:3000/api")' -match $l002.check)))
Add-Result -Name 'check-regex-l002-ignores-a-port-variable' -Passed ([bool]($l002 -and ('Start-WebServer -Port $port' -notmatch $l002.check)))
Add-Result -Name 'check-on-l002-is-test-additions' -Passed ($l002 -and $l002.checkOn -eq 'test-additions')

# --- Get-LessonCheckFailures: mechanical lesson checks are testable without a worktree ---

$nestedCommandBody = @'
## Acceptance commands
```powershell
powershell -Command "$x = Get-Content fixture.txt"
```
'@
$testDiffWithFixedPort = @'
diff --git a/scripts/tests/test-web.ps1 b/scripts/tests/test-web.ps1
--- a/scripts/tests/test-web.ps1
+++ b/scripts/tests/test-web.ps1
@@ -1,0 +1,1 @@
+Start-WebServer -Port 8080
'@
$prodDiffWithFixedPort = @'
diff --git a/src/server.ps1 b/src/server.ps1
--- a/src/server.ps1
+++ b/src/server.ps1
@@ -1,0 +1,1 @@
+Start-WebServer -Port 8080
'@
$cleanBody = @'
## Acceptance commands
```powershell
Get-Content fixture.txt
```
'@
$cleanDiff = @'
diff --git a/scripts/tests/test-web.ps1 b/scripts/tests/test-web.ps1
--- a/scripts/tests/test-web.ps1
+++ b/scripts/tests/test-web.ps1
@@ -1,0 +1,1 @@
+Start-WebServer -Port $port
'@

$nestedFailures = @(Get-LessonCheckFailures -Lessons $seed -TaskBody $nestedCommandBody -DiffText '')
Add-Result -Name 'lesson-check-rejects-nested-powershell-before-reviewer' `
    -Passed (($nestedFailures.Count -gt 0) -and ($nestedFailures -join "`n" -match 'L-001') -and ($nestedFailures -join "`n" -match [regex]::Escape($l001.doInstead)))
Add-Result -Name 'acceptance-lesson-failure-is-tagged-task-body' `
    -Passed ($nestedFailures -join "`n" -match [regex]::Escape('(task-body)'))

$reviewerCalls = 0
function Invoke-FixtureReviewer {
    $script:reviewerCalls++
}
if ($nestedFailures.Count -eq 0) { Invoke-FixtureReviewer }
Add-Result -Name 'nested-powershell-does-not-invoke-reviewer' -Passed ($reviewerCalls -eq 0) `
    -Detail "(reviewer calls: $reviewerCalls)"

$portFailures = @(Get-LessonCheckFailures -Lessons $seed -TaskBody '' -DiffText $testDiffWithFixedPort)
Add-Result -Name 'lesson-check-rejects-fixed-port-in-new-test-file' `
    -Passed (($portFailures.Count -gt 0) -and ($portFailures -join "`n" -match 'L-002') -and ($portFailures -join "`n" -match [regex]::Escape($l002.doInstead)))
Add-Result -Name 'test-addition-lesson-failure-is-not-tagged-task-body' `
    -Passed ($portFailures -join "`n" -notmatch [regex]::Escape('(task-body)'))
$prodFailures = @(Get-LessonCheckFailures -Lessons $seed -TaskBody '' -DiffText $prodDiffWithFixedPort)
Add-Result -Name 'test-addition-lesson-ignores-non-test-files' -Passed ($prodFailures.Count -eq 0)

$cleanFailures = @(Get-LessonCheckFailures -Lessons $seed -TaskBody $cleanBody -DiffText $cleanDiff)
Add-Result -Name 'lesson-check-allows-clean-task-and-test-diff' -Passed ($cleanFailures.Count -eq 0) `
    -Detail "(failures: $($cleanFailures -join '; '))"

# A check with no check-on field is inert: it never runs against anything.
$inert = [PSCustomObject]@{ Active = @([PSCustomObject]@{ id = 'L-777'; date = '2026-09-20'; rule = 'r'; doInstead = 'd'; check = 'Get-Content'; checkOn = $null; source = 'fixture'; hits = 0; lastSeen = $null; pinned = $false }); Retired = @() }
Add-Result -Name 'lesson-check-without-check-on-is-inert' -Passed (@(Get-LessonCheckFailures -Lessons $inert -TaskBody $cleanBody -DiffText $cleanDiff).Count -eq 0)

# --- round-trip: parse, re-write, re-parse must produce identical parsed objects ---

$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("lessons-roundtrip-" + [guid]::NewGuid().ToString('N') + '.md')
try {
    Write-Lessons -Lessons $seed -Path $tempFile | Out-Null
    $roundTripped = Read-Lessons -Path $tempFile
    $roundTripOk = Test-LessonSetsEqual -A $seed -B $roundTripped
}
finally {
    if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force }
}
Add-Result -Name 'round-trip-parsed-objects-identical' -Passed $roundTripOk

# --- Test-RuleSimilarity ---

$ruleA = 'Never hardcode port 8080 when a test starts its own local server process.'
$ruleB = 'Never hardcode port 8080 when a new test starts its own local web server process instance.'
$ruleUnrelated = 'Never leave a TODO comment in committed production code without an owner.'

$simSame = Test-RuleSimilarity -RuleA $ruleA -RuleB $ruleB
$simSameScore = Test-RuleSimilarity -RuleA $ruleA -RuleB $ruleB -Score
Add-Result -Name 'similarity-same-mistake-above-threshold' -Passed ($simSame -eq $true) `
    -Detail "(score $simSameScore)"

$simDiff = Test-RuleSimilarity -RuleA $ruleA -RuleB $ruleUnrelated
$simDiffScore = Test-RuleSimilarity -RuleA $ruleA -RuleB $ruleUnrelated -Score
Add-Result -Name 'similarity-unrelated-below-threshold' -Passed ($simDiff -eq $false) `
    -Detail "(score $simDiffScore)"

# --- New-LessonId ---

$nextId = New-LessonId -Lessons $seed
$highest = (@($seed.Active) + @($seed.Retired) | ForEach-Object { [int]($_.id -replace '^L-', '') } | Measure-Object -Maximum).Maximum
$highest = [int]$highest
$expectedNext = 'L-{0:D3}' -f ($highest + 1)
Add-Result -Name 'new-lesson-id-sequential' -Passed ($nextId -eq $expectedNext) `
    -Detail "(expected $expectedNext, got $nextId)"

$withRetiredL007 = [PSCustomObject]@{
    Active  = $seed.Active
    Retired = @([PSCustomObject]@{
            id        = $expectedNext
            date      = '2026-09-16'
            rule      = 'A retired lesson that already used the next id.'
            doInstead = 'n/a'
            check     = $null
            source    = 'seed'
            hits      = 0
            lastSeen  = $null
        })
}
$nextIdAfterRetired = New-LessonId -Lessons $withRetiredL007
$expectedAfterRetired = 'L-{0:D3}' -f ($highest + 2)
Add-Result -Name 'new-lesson-id-skips-used-retired-id' -Passed ($nextIdAfterRetired -eq $expectedAfterRetired) `
    -Detail "(expected $expectedAfterRetired, got $nextIdAfterRetired)"

# --- finding ledger and automatic lesson outcomes ---

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lessons-findings-" + [guid]::NewGuid().ToString('N'))
$fixtureLedger = Join-Path $fixtureDir 'findings.jsonl'
$fixtureLessons = Join-Path $fixtureDir 'lessons.md'
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
try {
    $one = [PSCustomObject]@{ task = 101; pr = 501; round = 1; reviewer = 'claude'; file = 'a.ps1'; issue = 'first issue'; fix = 'Use the shared helper.'; rule = 'Never duplicate shared validation logic in scripts.' }
    $two = [PSCustomObject]@{ task = 102; pr = 502; round = 2; reviewer = 'claude'; file = 'b.ps1'; issue = 'second issue'; fix = 'Use the common validation helper instead.'; rule = 'Do not duplicate the shared validation logic within scripts.' }
    $three = [PSCustomObject]@{ task = 103; pr = 503; round = 3; reviewer = 'claude'; file = 'c.ps1'; issue = 'third issue'; fix = 'Use the common helper.'; rule = 'Avoid duplicating shared validation logic inside scripts.' }

    Add-Finding -Path $fixtureLedger -Finding $one -Date '2026-09-10' | Out-Null
    $fixture = [PSCustomObject]@{ Active = @(); Retired = @() }
    $prior = @(Get-Content $fixtureLedger | ForEach-Object { $_ | ConvertFrom-Json })
    $firstOutcome = Add-Or-BumpLesson -Lessons $fixture -Finding $two -PriorFindings $prior -Date '2026-09-11'
    if ($firstOutcome.Action -eq 'add') { Write-Lessons -Lessons $fixture -Path $fixtureLessons | Out-Null }
    Add-Finding -Path $fixtureLedger -Finding $two -Date '2026-09-11' | Out-Null
    Add-Result -Name 'equivalent-rules-create-one-lesson' -Passed (($fixture.Active.Count -eq 1) -and ($fixture.Active[0].source -match 'PR #501, round 1') -and ($fixture.Active[0].source -match 'PR #502, round 2'))

    $beforeText = Get-Content $fixtureLessons -Raw
    $bump = Add-Or-BumpLesson -Lessons $fixture -Finding $three -PriorFindings @($prior + $two) -Date '2026-09-12'
    Write-Lessons -Lessons $fixture -Path $fixtureLessons | Out-Null
    $afterText = Get-Content $fixtureLessons -Raw
    Add-Result -Name 'equivalent-rule-bumps-existing-lesson' -Passed (($bump.Action -eq 'bump') -and ($fixture.Active[0].hits -eq 1) -and ($fixture.Active[0].lastSeen -eq '2026-09-12') -and ($beforeText -notmatch 'last-seen: 2026-09-12') -and ($afterText -notmatch '### L-002'))

    $retiredRule = 'Never duplicate shared validation logic inside scripts.'
    $retired = [PSCustomObject]@{ id = 'L-009'; date = '2026-09-01'; rule = $retiredRule; doInstead = 'Use the helper.'; check = $null; source = 'fixture'; hits = 7; lastSeen = '2026-09-05' }
    $retiredLessons = [PSCustomObject]@{ Active = @(); Retired = @($retired) }
    $retiredOutcome = Add-Or-BumpLesson -Lessons $retiredLessons -Finding $three -PriorFindings @($one, $two) -Date '2026-09-13'
    Add-Result -Name 'retired-rule-does-nothing' -Passed (($retiredOutcome.Action -eq 'retired') -and ($retiredLessons.Active.Count -eq 0) -and ($retired.hits -eq 7) -and ($retired.lastSeen -eq '2026-09-05'))

    $jsonWithoutRule = '{"task":104,"pr":504,"round":4,"reviewer":"claude","file":"d.ps1","issue":"missing rule","fix":"Add the field"}' | ConvertFrom-Json
    $missing = Add-Finding -Path $fixtureLedger -Finding $jsonWithoutRule -Date '2026-09-14'
    $missingOutcome = Add-Or-BumpLesson -Lessons $fixture -Finding $jsonWithoutRule -PriorFindings @($one, $two, $three) -Date '2026-09-14'
    Add-Result -Name 'missing-rule-is-blank-and-never-matched' -Passed (($missing.rule -eq '') -and ($missingOutcome.Action -eq 'none') -and ($fixture.Active.Count -eq 1))
}
finally {
    if (Test-Path $fixtureDir) { Remove-Item -Path $fixtureDir -Recurse -Force }
}

# --- Build-LessonsSection: active-only rendering, retired entries excluded ---

$retiredEntry = [PSCustomObject]@{
    id        = 'L-900'
    date      = '2020-01-01'
    rule      = 'Retired rule text that must never appear in a rendered lessons section.'
    doInstead = 'Retired do-instead text that must never appear in a rendered lessons section.'
    check     = $null
    source    = 'fixture'
    hits      = 99
    lastSeen  = '2020-01-01'
}
$withRetired = [PSCustomObject]@{ Active = $seed.Active; Retired = @($retiredEntry) }
$sectionFixtureFile = Join-Path ([System.IO.Path]::GetTempPath()) ("lessons-section-" + [guid]::NewGuid().ToString('N') + '.md')
try {
    Write-Lessons -Lessons $withRetired -Path $sectionFixtureFile | Out-Null
    $sectionSeed = Read-Lessons -Path $sectionFixtureFile
    $section = Build-LessonsSection -Lessons $sectionSeed

    $missingIds = @($sectionSeed.Active | Where-Object { $section -notmatch [regex]::Escape($_.id) })
    Add-Result -Name 'lessons-section-contains-all-active-ids' -Passed ($missingIds.Count -eq 0) `
        -Detail "(missing: $(($missingIds | ForEach-Object { $_.id }) -join ', '))"

    # A very long rule can now be trimmed to fit MaxEntryChars, so this checks that each rule is
    # recognisably present, not that every character of it survived. The point of the check is
    # that no entry is silently dropped.
    $missingRules = @($sectionSeed.Active | Where-Object {
        $head = if ($_.rule.Length -gt 50) { $_.rule.Substring(0, 50) } else { $_.rule }
        $section -notmatch [regex]::Escape($head)
    })
    Add-Result -Name 'lessons-section-contains-all-active-rules' -Passed ($missingRules.Count -eq 0) `
        -Detail "(missing rule text for: $(($missingRules | ForEach-Object { $_.id }) -join ', '))"

    # The real file, rendered: every entry present and the whole section inside its budget. This
    # is the regression the MaxEntryChars fix is for -- one 1014-character entry once pushed the
    # section over MaxChars and evicted three other lessons from every agent prompt.
    $realSection = Build-LessonsSection -Lessons (Read-Lessons -Path $lessonsPath)
    $realLines = @([regex]::Matches($realSection, '(?m)^- \*\*L-\d+\*\*.*$'))
    $tooLong = @($realLines | Where-Object { $_.Value.Length -gt 420 })
    Add-Result -Name 'real-lessons-section-caps-every-entry' -Passed ($tooLong.Count -eq 0) `
        -Detail "(over 420 chars: $(($tooLong | ForEach-Object { $_.Value.Substring(0, 12) }) -join ', '))"
    Add-Result -Name 'real-lessons-section-renders-every-active-lesson' `
        -Passed ($realLines.Count -eq (Read-Lessons -Path $lessonsPath).Active.Count) `
        -Detail "(rendered $($realLines.Count) of $((Read-Lessons -Path $lessonsPath).Active.Count))"
    Add-Result -Name 'real-lessons-section-fits-the-budget' -Passed ($realSection.Length -le 6000) `
        -Detail "(rendered $($realSection.Length) chars)"

    Add-Result -Name 'lessons-section-excludes-retired-id' -Passed ($section -notmatch [regex]::Escape($retiredEntry.id))
    Add-Result -Name 'lessons-section-excludes-retired-rule' -Passed ($section -notmatch [regex]::Escape($retiredEntry.rule))
}
finally {
    if (Test-Path $sectionFixtureFile) { Remove-Item -Path $sectionFixtureFile -Force }
}

# --- Limit-LessonText / ConvertTo-LessonText: how a lesson is kept prompt-sized ---

Add-Result -Name 'limit-lesson-text-leaves-short-text-alone' `
    -Passed ((Limit-LessonText -Text 'short enough' -Max 50) -eq 'short enough')

$limited = Limit-LessonText -Text 'one two three four five six seven eight nine ten' -Max 20
Add-Result -Name 'limit-lesson-text-trims-at-a-word-boundary-with-an-ellipsis' `
    -Passed (($limited.Length -le 20) -and ($limited -match "$([char]0x2026)$") -and ($limited -notmatch ' $')) `
    -Detail "(got '$limited')"

$pasted = 'task-body: Replace the post-acquisition loop with the reusable check. This needs file outside owned paths: src/core/jobs/job_queue.js; needs file outside owned paths: src/core/scheduling/global_assignment.js. See PR #311 and issue #266.'
$general = ConvertTo-LessonText -Text $pasted -Max 200
Add-Result -Name 'convert-to-lesson-text-drops-the-task-body-prefix' -Passed ($general -notmatch '(?i)task-body:') -Detail "(got '$general')"
Add-Result -Name 'convert-to-lesson-text-drops-owned-path-noise' -Passed ($general -notmatch 'job_queue.js') -Detail "(got '$general')"
Add-Result -Name 'convert-to-lesson-text-drops-pr-and-issue-numbers' -Passed ($general -notmatch '#\d+') -Detail "(got '$general')"
Add-Result -Name 'convert-to-lesson-text-keeps-the-general-instruction' -Passed ($general -match 'reusable check') -Detail "(got '$general')"
Add-Result -Name 'convert-to-lesson-text-caps-length' -Passed ($general.Length -le 200) -Detail "(length $($general.Length))"
Add-Result -Name 'convert-to-lesson-text-is-empty-for-empty-input' -Passed ((ConvertTo-LessonText -Text '  ') -eq '')

# --- a newly born lesson is general and prompt-sized, not a pasted review comment ---

$verboseFixDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lessons-verbose-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verboseFixDir -Force | Out-Null
$verboseLedger = Join-Path $verboseFixDir 'findings.jsonl'
try {
    $longFix = 'task-body: ' + ('Change the widget in src/core/widget.js and then also update every caller so the contract still holds. ' * 4) + ' See PR #999.'
    $vOne = [PSCustomObject]@{ task = 201; pr = 601; round = 1; reviewer = 'codex'; file = 'x.js'; issue = 'first'; fix = $longFix; rule = 'Never leave a widget contract half-updated across its callers.' }
    $vTwo = [PSCustomObject]@{ task = 202; pr = 602; round = 1; reviewer = 'claude'; file = 'y.js'; issue = 'second'; fix = $longFix; rule = 'Do not leave the widget contract half updated across callers.' }
    Add-Finding -Path $verboseLedger -Finding $vOne -Date '2026-09-20' | Out-Null
    $vLessons = [PSCustomObject]@{ Active = @(); Retired = @() }
    $vPrior = @(Get-Content $verboseLedger | ForEach-Object { $_ | ConvertFrom-Json })
    $vOutcome = Add-Or-BumpLesson -Lessons $vLessons -Finding $vTwo -PriorFindings $vPrior -Date '2026-09-21'
    $born = $vOutcome.Entry
    Add-Result -Name 'new-lesson-is-created-from-two-matching-findings' -Passed ($vOutcome.Action -eq 'add')
    Add-Result -Name 'new-lesson-do-text-is-capped' -Passed ($born -and ($born.doInstead.Length -le 220)) `
        -Detail "(length $(if ($born) { $born.doInstead.Length } else { 'n/a' }))"
    Add-Result -Name 'new-lesson-do-text-has-no-task-body-prefix-or-pr-number' `
        -Passed ($born -and ($born.doInstead -notmatch '(?i)task-body:') -and ($born.doInstead -notmatch '#\d+'))
}
finally {
    if (Test-Path $verboseFixDir) { Remove-Item -Path $verboseFixDir -Recurse -Force }
}

# --- Build-LessonsSection: caps entries and characters; the file on disk is untouched ---

$capFixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lessons-cap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $capFixtureDir -Force | Out-Null
$capFixtureFile = Join-Path $capFixtureDir 'lessons.md'
try {
    $capActive = @()
    for ($i = 1; $i -le 60; $i++) {
        $capActive += [PSCustomObject]@{
            id        = ('L-{0:D3}' -f (100 + $i))
            date      = ('2026-01-{0:D2}' -f (($i % 28) + 1))
            rule      = "Rule number $i describing a hard constraint the author must follow at all times without exception."
            doInstead = "Do this instead for rule ${i}: take the safe, well-tested alternative path every single time it comes up."
            check     = $null
            source    = 'fixture'
            hits      = ($i % 5)
            lastSeen  = '2026-01-01'
        }
    }
    $capLessons = [PSCustomObject]@{ Active = $capActive; Retired = @() }
    Write-Lessons -Lessons $capLessons -Path $capFixtureFile | Out-Null

    $capSeed = Read-Lessons -Path $capFixtureFile
    Add-Result -Name 'lessons-section-cap-fixture-has-60-on-disk' -Passed ($capSeed.Active.Count -eq 60)

    $capSection = Build-LessonsSection -Lessons $capSeed
    $capEntryCount = @([regex]::Matches($capSection, '(?m)^- \*\*L-')).Count
    Add-Result -Name 'lessons-section-caps-entry-count' -Passed ($capEntryCount -le 40) `
        -Detail "(rendered $capEntryCount entries)"
    # 6000 is Build-LessonsSection's MaxChars: the outer stop for a file that has genuinely grown
    # too long. Per-entry trimming (MaxEntryChars) is what keeps one verbose lesson from getting
    # there on its own and evicting the others.
    Add-Result -Name 'lessons-section-caps-char-length' -Passed ($capSection.Length -le 6000) `
        -Detail "(rendered $($capSection.Length) chars)"

    # Drop priority is fewest hits then oldest date first, so the entry with hits=0 and the
    # earliest date among the hits=0 group must be the first one dropped.
    $lowestPriority = $capActive | Where-Object { $_.hits -eq 0 } | Sort-Object date | Select-Object -First 1
    Add-Result -Name 'lessons-section-drops-fewest-hits-oldest-first' -Passed ($capSection -notmatch [regex]::Escape($lowestPriority.id))

    $capReread = Read-Lessons -Path $capFixtureFile
    Add-Result -Name 'lessons-section-cap-does-not-touch-disk' -Passed ($capReread.Active.Count -eq 60)
}
finally {
    if (Test-Path $capFixtureDir) { Remove-Item -Path $capFixtureDir -Recurse -Force }
}

# --- agent-supervisor.ps1 wiring: LESSONS precedes the task/objective text in all three prompts ---
# Extracts Fill-Template and Get-LessonsSection from agent-supervisor.ps1 by AST, without
# dot-sourcing the whole script (its bottom half requires the GitHub CLI and enters a poll
# loop). This mirrors the technique test-supervisor.ps1 uses for the same reason. Deliberately
# run at this script's top-level scope (not inside a function): both extracted functions read
# the bare $root/$promptDir variables via their own lexical (top-level) scope chain, exactly as
# they do inside agent-supervisor.ps1 itself.

function Get-LessonsWiringFunctionSource {
    param([string]$Path, [string]$FunctionName)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    $found = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName },
        $true
    ) | Select-Object -First 1
    if (-not $found) { throw "Could not find function '$FunctionName' in $Path via AST parsing." }
    return $found.Extent.Text
}

try {
    $supervisorPath = Join-Path $PSScriptRoot 'agent-supervisor.ps1'
    . ([scriptblock]::Create((Get-LessonsWiringFunctionSource -Path $supervisorPath -FunctionName 'Fill-Template')))
    . ([scriptblock]::Create((Get-LessonsWiringFunctionSource -Path $supervisorPath -FunctionName 'Get-LessonsSection')))

    $root = $repoRoot
    $promptDir = Join-Path $repoRoot 'docs\agent-prompts'
    function Get-LessonsReadPath { return $lessonsPath }

    $wiredLessons = Get-LessonsSection
    Add-Result -Name 'get-lessons-section-returns-rendered-text' -Passed ($wiredLessons -match 'Lessons from past reviews')

    $plannerPrompt = Fill-Template "planner" @{ OBJECTIVE_NUMBER = 88; OBJECTIVE_TITLE = 'Fixture objective'; OBJECTIVE_BODY = 'Fixture objective body.'; LESSONS = $wiredLessons }
    $implementerPrompt = Fill-Template "implementer" @{ ISSUE_NUMBER = 99; REPOSITORY = 'org/repo'; BRANCH = 'agent/fixture'; ISSUE_BODY = 'Fixture task body.'; REVISION_SECTION = ''; LESSONS = $wiredLessons }
    $reviewerPrompt = Fill-Template "reviewer" @{ AUTHOR = 'claude'; BRANCH = 'agent/fixture'; ISSUE_NUMBER = 99; ISSUE_BODY = 'Fixture task body.'; HANDOFF = 'Fixture handoff.'; ACCEPTANCE = 'Fixture acceptance.'; PREVIOUS_ROUND = ''; LESSONS = $wiredLessons }

    $marker = 'Lessons from past reviews'

    $plannerIdx = $plannerPrompt.IndexOf($marker)
    $plannerHeadingIdx = $plannerPrompt.IndexOf('## Objective')
    Add-Result -Name 'planner-prompt-has-lessons-before-objective' -Passed (($plannerIdx -ge 0) -and ($plannerHeadingIdx -ge 0) -and ($plannerIdx -lt $plannerHeadingIdx))

    $implementerIdx = $implementerPrompt.IndexOf($marker)
    $implementerHeadingIdx = $implementerPrompt.IndexOf('## The task')
    Add-Result -Name 'implementer-prompt-has-lessons-before-task' -Passed (($implementerIdx -ge 0) -and ($implementerHeadingIdx -ge 0) -and ($implementerIdx -lt $implementerHeadingIdx))

    $reviewerIdx = $reviewerPrompt.IndexOf($marker)
    $reviewerHeadingIdx = $reviewerPrompt.IndexOf('The task the author was given')
    Add-Result -Name 'reviewer-prompt-has-lessons-before-task' -Passed (($reviewerIdx -ge 0) -and ($reviewerHeadingIdx -ge 0) -and ($reviewerIdx -lt $reviewerHeadingIdx))
}
catch {
    Add-Result -Name 'supervisor-prompt-wiring' -Passed $false -Detail "unexpected error: $($_.Exception.Message)"
}

# --- summary ---

$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) of $($results.Count) checks failed."
    exit 1
}

Write-Host "All $($results.Count) checks passed."
exit 0
