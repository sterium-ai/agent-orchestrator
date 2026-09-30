# Pure, dot-sourceable helpers for the lessons file (docs/agent-prompts/lessons.md by default). No dependency on
# agent-supervisor.ps1 or any other script's state.

function Read-Lessons {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = (Get-Content -Path $Path -Raw) -replace "`r`n", "`n"

    $sectionMatches = [regex]::Matches($raw, '(?m)^## (.+?)\s*$')
    $sections = @{}
    for ($i = 0; $i -lt $sectionMatches.Count; $i++) {
        $name = $sectionMatches[$i].Groups[1].Value
        $start = $sectionMatches[$i].Index + $sectionMatches[$i].Length
        $end = if ($i + 1 -lt $sectionMatches.Count) { $sectionMatches[$i + 1].Index } else { $raw.Length }
        $sections[$name] = $raw.Substring($start, $end - $start)
    }

    $result = [ordered]@{ Active = @(); Retired = @() }
    foreach ($name in @('Active', 'Retired')) {
        if (-not $sections.ContainsKey($name)) { continue }
        $body = $sections[$name]

        $entryMatches = [regex]::Matches($body, '(?m)^### (L-\d+)\s*\((\d{4}-\d{2}-\d{2})\)\s*$')
        $entries = @()
        for ($j = 0; $j -lt $entryMatches.Count; $j++) {
            $id = $entryMatches[$j].Groups[1].Value
            $date = $entryMatches[$j].Groups[2].Value
            $estart = $entryMatches[$j].Index + $entryMatches[$j].Length
            $eend = if ($j + 1 -lt $entryMatches.Count) { $entryMatches[$j + 1].Index } else { $body.Length }
            $block = $body.Substring($estart, $eend - $estart)

            $fields = @{}
            foreach ($fm in [regex]::Matches($block, '(?m)^- ([a-zA-Z-]+):\s?(.*?)\s*$')) {
                $fields[$fm.Groups[1].Value] = $fm.Groups[2].Value
            }

            $check = $null
            if ($fields.ContainsKey('check') -and $fields['check']) {
                $check = $fields['check'].Trim('`')
            }

            # Which input a check runs against: `acceptance` (the task's own acceptance block) or
            # `test-additions` (lines the diff adds to test files). A check without it is inert.
            $checkOn = $null
            if ($fields.ContainsKey('check-on') -and $fields['check-on']) {
                $checkOn = $fields['check-on'].Trim().ToLowerInvariant()
            }

            $hits = 0
            if ($fields.ContainsKey('hits') -and $fields['hits']) {
                $hits = [int]$fields['hits']
            }

            $lastSeen = $null
            if ($fields.ContainsKey('last-seen') -and $fields['last-seen']) {
                $lastSeen = $fields['last-seen']
            }

            # Pinned entries (the curated seeds) are never dropped from the rendered prompt
            # section when the cap is hit; learned entries compete for the remaining room.
            $pinned = $false
            if ($fields.ContainsKey('pinned') -and $fields['pinned'] -match '^(?i)true|yes|1$') {
                $pinned = $true
            }

            $entries += [PSCustomObject]@{
                id        = $id
                date      = $date
                rule      = $fields['rule']
                doInstead = $fields['do']
                check     = $check
                checkOn   = $checkOn
                source    = $fields['source']
                hits      = $hits
                lastSeen  = $lastSeen
                pinned    = $pinned
            }
        }
        $result[$name] = $entries
    }

    return [PSCustomObject]@{ Active = $result['Active']; Retired = $result['Retired'] }
}

function Format-LessonEntry {
    param(
        [Parameter(Mandatory = $true)]
        $Entry
    )

    $lines = @()
    $lines += "### $($Entry.id) ($($Entry.date))"
    $lines += "- rule: $($Entry.rule)"
    $lines += "- do: $($Entry.doInstead)"
    $lines += "- source: $($Entry.source)"
    if ($Entry.check) {
        $lines += "- check: ``$($Entry.check)``"
    }
    if ($Entry.PSObject.Properties['checkOn'] -and $Entry.checkOn) {
        $lines += "- check-on: $($Entry.checkOn)"
    }
    $lines += "- hits: $($Entry.hits)"
    if ($Entry.lastSeen) {
        $lines += "- last-seen: $($Entry.lastSeen)"
    }
    if ($Entry.PSObject.Properties['pinned'] -and $Entry.pinned) {
        $lines += "- pinned: true"
    }
    $lines += ""
    return $lines
}

function Get-LessonCheckFailures {
    param(
        [Parameter(Mandatory = $true)]
        $Lessons,

        [string]$TaskBody = '',

        [Alias('Diff')]
        [string]$DiffText = ''
    )

    # Checks are deliberately applied to the smallest relevant input.  In
    # particular, a check for a test-only mistake must not reject an unrelated
    # occurrence in the task prose or in a non-test file.
    $acceptance = ''
    if (-not [string]::IsNullOrWhiteSpace($TaskBody)) {
        $acceptanceMatch = [regex]::Match(
            $TaskBody,
            '(?ms)^##\s*Acceptance commands\s*\r?\n\s*```[^\r\n]*\r?\n(.*?)\r?\n\s*```'
        )
        if ($acceptanceMatch.Success) { $acceptance = $acceptanceMatch.Groups[1].Value }
    }

    $testAdditions = New-Object System.Text.StringBuilder
    $currentPath = ''
    foreach ($line in @($DiffText -split "\r?\n")) {
        $gitPath = [regex]::Match($line, '^diff --git a/(.+) b/(.+)$')
        if ($gitPath.Success) {
            $currentPath = $gitPath.Groups[2].Value
            continue
        }
        $newPath = [regex]::Match($line, '^\+\+\+ b/(.+)$')
        if ($newPath.Success) {
            $currentPath = $newPath.Groups[1].Value
            continue
        }
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++') -and
            $currentPath -match '(?i)(^|[/\\])(?:test|tests)(?:[/\\]|[-_.])|(?i)(^|[/\\])test[-_.]') {
            [void]$testAdditions.AppendLine($line.Substring(1))
        }
    }

    # A lesson's `check` only runs against the input its `check-on` field names: the task's own
    # acceptance block (`acceptance`), or the lines the diff adds to test files
    # (`test-additions`). A lesson that carries a check but no `check-on` is inert.
    $failures = @()
    foreach ($lesson in @($Lessons.Active)) {
        if ([string]::IsNullOrWhiteSpace([string]$lesson.check)) { continue }

        $target = if ($lesson.PSObject.Properties['checkOn']) { [string]$lesson.checkOn } else { '' }
        $isAcceptanceLesson = ($target -eq 'acceptance')
        $subject = if ($isAcceptanceLesson) { $acceptance }
            elseif ($target -eq 'test-additions') { $testAdditions.ToString() }
            else { '' }
        if (-not $subject -or $subject -notmatch [string]$lesson.check) { continue }

        # A check that fires on the task's own acceptance block is a defect of the issue text,
        # which the author cannot edit; the "(task-body)" tag lets the supervisor route it to
        # the owner (Get-FailureClass) instead of spending an author session on it.
        $tag = if ($isAcceptanceLesson) { ' (task-body)' } else { '' }
        $failures += "Lesson $($lesson.id)$($tag): $($lesson.doInstead)"
    }
    return $failures
}

function Write-Lessons {
    param(
        [Parameter(Mandatory = $true)]
        $Lessons,

        [string]$Path
    )

    $lines = @()
    $lines += '# Lessons'
    $lines += ''
    $lines += 'Lessons learned from past agent mistakes, matched against new findings to avoid repeating'
    $lines += 'them. See `scripts/lessons.ps1` for the reader/writer and the similarity check that decides'
    $lines += 'whether a new finding is the same mistake as an existing lesson.'
    $lines += ''
    $lines += '## Active'
    $lines += ''
    foreach ($entry in $Lessons.Active) {
        $lines += Format-LessonEntry -Entry $entry
    }
    $lines += '## Retired'
    $lines += ''
    foreach ($entry in $Lessons.Retired) {
        $lines += Format-LessonEntry -Entry $entry
    }

    $text = ($lines -join "`n").TrimEnd("`n") + "`n"

    if ($Path) {
        Set-Content -Path $Path -Value $text -NoNewline -Encoding utf8
    }

    return $text
}

function New-LessonId {
    param(
        [Parameter(Mandatory = $true)]
        $Lessons
    )

    $all = @($Lessons.Active) + @($Lessons.Retired)
    $max = 0
    foreach ($entry in $all) {
        if ($entry.id -match '^L-(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }

    return ('L-{0:D3}' -f ($max + 1))
}

function Test-RuleSimilarity {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RuleA,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RuleB,

        [double]$Threshold = 0.65,

        [switch]$Score
    )

    function Get-ActionVerb {
        param([string]$LowerText)

        $t = $LowerText.Trim()
        $t = [regex]::Replace($t, "^(never|always|avoid|stop|do not|don't|dont)\s+", '')
        $m = [regex]::Match($t, '^([a-z]+)')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }

    function Get-RuleTokens {
        param([string]$Text)

        function Normalize-RuleWord {
            param([string]$Word)

            # Keep the matcher tolerant of ordinary review-language variation
            # without attempting broad linguistic stemming.
            switch ($Word) {
                'duplicating' { return 'duplicate' }
                'duplicates'  { return 'duplicate' }
                'duplicated'  { return 'duplicate' }
                'inside'      { return 'within' }
                default       { return $Word }
            }
        }

        $lower = $Text.ToLowerInvariant()

        # Words that appear in almost every review sentence carry no signal; without this list
        # two unrelated rules that both say "the ... must not ... when ... file" looked alike.
        $stop = @('the','and','not','when','that','this','with','for','are','its','own','from','into','than','then',
                  'must','should','never','always','avoid','does','did','was','were','has','have','had','can','will',
                  'any','all','each','every','only','also','but','use','used','using','make','made','one','two',
                  'instead','rather','before','after','while','where','which','what','who','how','why','you','your',
                  'they','them','their','there','here','out','over','under','via','per','file','files','code',
                  'task','change','changes','author','reviewer','value','values')

        $files = @()
        foreach ($m in [regex]::Matches($lower, '[a-z0-9_\-./\\]+\.[a-z]{1,6}')) {
            $files += ($m.Value -replace '.*[\\/]', '')
        }

        # Strip matched path spans entirely so path components (e.g. "scripts", "ps1")
        # never leak into the Jaccard word set; file identity is tracked separately above.
        $withoutPaths = [regex]::Replace($lower, '[a-z0-9_\-./\\]+\.[a-z]{1,6}', ' ')

        $verb = Get-ActionVerb -LowerText $withoutPaths

        $clean = $withoutPaths -replace '[^a-z\s]', ' '
        $words = @($clean -split '\s+' |
            Where-Object { $_.Length -gt 2 -and ($stop -notcontains $_) } |
            ForEach-Object { Normalize-RuleWord -Word $_ } |
            Select-Object -Unique)

        return [PSCustomObject]@{ Words = $words; Files = $files; Verb = $verb }
    }

    if ([string]::IsNullOrWhiteSpace($RuleA) -or [string]::IsNullOrWhiteSpace($RuleB)) {
        if ($Score) { return 0.0 }
        return $false
    }
    $a = Get-RuleTokens -Text $RuleA
    $b = Get-RuleTokens -Text $RuleB

    $intersection = @($a.Words | Where-Object { $b.Words -contains $_ })
    $union = @(($a.Words + $b.Words) | Select-Object -Unique)
    $jaccard = if ($union.Count -gt 0) { $intersection.Count / $union.Count } else { 0.0 }

    # Naming the same file is weak evidence in this repository: nearly every supervisor finding
    # names agent-supervisor.ps1, so those two files earn no boost at all.
    $common = @('agent-supervisor.ps1', 'run-agent.ps1')
    $boost = 0.0
    if (@($a.Files | Where-Object { ($b.Files -contains $_) -and ($common -notcontains $_) }).Count -gt 0) { $boost += 0.1 }
    if ($a.Verb -and $a.Verb -eq $b.Verb) { $boost += 0.1 }

    $result = [Math]::Min(1.0, $jaccard + $boost)

    if ($Score) { return $result }
    return ($result -ge $Threshold)
}

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] $Finding,
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd')
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $record = [ordered]@{
        task     = [int]$Finding.task
        pr       = if ($null -eq $Finding.pr) { '' } else { [string]$Finding.pr }
        round    = [int]$Finding.round
        reviewer = [string]$Finding.reviewer
        file     = if ($null -eq $Finding.file) { '' } else { [string]$Finding.file }
        issue    = [string]$Finding.issue
        rule     = if ([string]::IsNullOrWhiteSpace([string]$Finding.rule)) { '' } else { ([string]$Finding.rule).Trim() }
        date     = $Date
    }
    Add-Content -Path $Path -Value ($record | ConvertTo-Json -Compress) -Encoding utf8
    return [PSCustomObject]$record
}

function Get-FindingMatches {
    param(
        [Parameter(Mandatory = $true)] [string]$Rule,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Findings,
        [double]$Threshold = 0.65
    )

    if ([string]::IsNullOrWhiteSpace($Rule)) { return @() }
    return @($Findings | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.rule) -and
        (Test-RuleSimilarity -RuleA $Rule -RuleB ([string]$_.rule) -Threshold $Threshold)
    })
}

function Add-Or-BumpLesson {
    param(
        [Parameter(Mandatory = $true)] $Lessons,
        [Parameter(Mandatory = $true)] $Finding,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$PriorFindings,
        [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
        [double]$Threshold = 0.65
    )

    # Both halves are generalised before anything else: the similarity check below then compares
    # rules rather than the review prose around them, and the entry is born prompt-sized.
    $rule = ConvertTo-LessonText -Text ([string]$Finding.rule) -Max 200
    if (-not $rule) { return [PSCustomObject]@{ Action = 'none'; Entry = $null } }

    $retired = @($Lessons.Retired | Where-Object {
        $_.rule -and (Test-RuleSimilarity -RuleA $rule -RuleB ([string]$_.rule) -Threshold $Threshold)
    })
    if ($retired.Count -gt 0) { return [PSCustomObject]@{ Action = 'retired'; Entry = $retired[0] } }

    $active = @($Lessons.Active | Where-Object {
        $_.rule -and (Test-RuleSimilarity -RuleA $rule -RuleB ([string]$_.rule) -Threshold $Threshold)
    })
    if ($active.Count -gt 0) {
        $entry = $active[0]
        $entry.hits = [int]$entry.hits + 1
        $entry.lastSeen = $Date
        return [PSCustomObject]@{ Action = 'bump'; Entry = $entry }
    }

    $matches = @(Get-FindingMatches -Rule $rule -Findings $PriorFindings -Threshold $Threshold)
    if ($matches.Count -eq 0) { return [PSCustomObject]@{ Action = 'none'; Entry = $null } }
    $first = $matches[0]
    $links = @($first, $Finding) | ForEach-Object {
        if ($_.pr) { "PR #$($_.pr), round $($_.round)" } else { "task #$($_.task), round $($_.round)" }
    }
    $entry = [PSCustomObject]@{
        id        = New-LessonId -Lessons $Lessons
        date      = $Date
        rule      = $rule
        doInstead = "Do this instead: $(ConvertTo-LessonText -Text ([string]$Finding.fix) -Max 200)"
        check     = $null
        checkOn   = $null
        source    = ($links -join '; ')
        hits      = 0
        lastSeen  = $Date
        pinned    = $false
    }
    $Lessons.Active += $entry
    return [PSCustomObject]@{ Action = 'add'; Entry = $entry }
}

# Shorten a lesson's text to Max characters at a word boundary. Used for the rendered prompt
# section (the file on disk always keeps the full text) and for the text a new lesson is born
# with. A trimmed string ends in an ellipsis so a reader can tell it was cut.
function Limit-LessonText {
    param([string]$Text, [int]$Max)
    $t = [string]$Text
    if ([string]::IsNullOrEmpty($t) -or $Max -le 1 -or $t.Length -le $Max) { return $t }
    $cut = $t.Substring(0, $Max - 1)
    $space = $cut.LastIndexOf(' ')
    if ($space -gt [int]($Max / 2)) { $cut = $cut.Substring(0, $space) }
    return ($cut.TrimEnd(' ', ',', ';', ':', '.', '-') + [char]0x2026)
}

# A reviewer's `fix` is written about one pull request: it names files, issue numbers and the exact
# lines to change. Pasted verbatim into a lesson it reads as a one-off review comment rather than a
# rule, and it eats the prompt budget every later session pays for. This strips the parts that only
# meant something in that review and caps what is left.
function ConvertTo-LessonText {
    param([string]$Text, [int]$Max = 200)
    $t = ([string]$Text).Trim()
    if (-not $t) { return '' }
    # "task-body:" is routing for the supervisor, not part of the rule.
    $t = [regex]::Replace($t, '(?i)^\s*task-body:\s*', '')
    # "This needs file outside owned paths: <path>; needs file outside owned paths: <path>." is a
    # statement about one diff; the rule it illustrates is already in the rule field.
    $t = [regex]::Replace($t, '(?i)\s*(?:this\s+)?needs\s+files?\s+outside\s+owned\s+paths\s*:[^.;]*[.;]?', ' ')
    # PR/issue/task numbers date a lesson to the review that produced it.
    $t = [regex]::Replace($t, '(?i)\s*\(?(?:PR|issue|task)?\s*#\d+\)?', ' ')
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    return (Limit-LessonText -Text $t -Max $Max)
}

# MaxEntryChars caps each entry: without it, a single verbose lesson (a rule of about 1,000
# characters of pasted investigation) pushes the rendered section past MaxChars on its own, the
# drop loop below then evicts every unpinned entry, and newer lessons never reach an agent
# prompt. Trimming the entry keeps every lesson visible for a fraction of the cost of dropping
# it; the full text stays in lessons.md for a person to read. MaxChars is the outer stop for a
# file that has genuinely grown too long, not the thing one bad entry trips.
function Build-LessonsSection {
    param(
        [Parameter(Mandatory = $true)] $Lessons,
        [int]$MaxEntries = 40,
        [int]$MaxChars = 6000,
        [int]$MaxEntryChars = 420
    )

    $header = '## Lessons from past reviews - hard rules'

    function Format-LessonsSectionText {
        param([string]$Header, [object[]]$Entries, [int]$EntryChars)

        if ($Entries.Count -eq 0) { return $Header }
        $lines = @($Header, '')
        foreach ($entry in $Entries) {
            $prefix = "- **$($entry.id)** rule: "
            $joiner = ' do this instead: '
            $rule = [string]$entry.rule
            $fix = [string]$entry.doInstead
            $line = "$prefix$rule$joiner$fix"
            if ($line.Length -gt $EntryChars) {
                # The rule is what an agent must recognise, so the "do this instead" half gives way
                # first; only a rule that leaves no usable room is trimmed as well.
                $room = $EntryChars - $prefix.Length - $rule.Length - $joiner.Length
                if ($room -lt 60) {
                    $rule = Limit-LessonText -Text $rule -Max ([Math]::Max(60, $EntryChars - $prefix.Length - $joiner.Length - 60))
                    $room = $EntryChars - $prefix.Length - $rule.Length - $joiner.Length
                }
                $line = "$prefix$rule$joiner$(Limit-LessonText -Text $fix -Max ([Math]::Max(20, $room)))"
            }
            $lines += $line
        }
        return ($lines -join "`n")
    }

    $active = @($Lessons.Active)

    # Drop priority when the rendered text is over cap: fewest hits first, oldest date first
    # among ties. This only trims the in-memory render below -- $Lessons and the file it came
    # from are never mutated.
    $dropOrder = @($active |
        Where-Object { -not ($_.PSObject.Properties['pinned'] -and $_.pinned) } |
        Sort-Object @{ Expression = { [int]$_.hits } }, @{ Expression = { $_.date } })

    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $active) { [void]$kept.Add($entry) }

    $text = Format-LessonsSectionText -Header $header -Entries $kept -EntryChars $MaxEntryChars
    $dropIndex = 0
    while ((($kept.Count -gt $MaxEntries) -or ($text.Length -gt $MaxChars)) -and ($dropIndex -lt $dropOrder.Count)) {
        [void]$kept.Remove($dropOrder[$dropIndex])
        $dropIndex++
        $text = Format-LessonsSectionText -Header $header -Entries $kept -EntryChars $MaxEntryChars
    }

    return $text
}
