# MortalShell2TTS share-safe support bundle collector
# v0.9.260 Pass 183 - shared ModUI controller-consumer contract; support-bundle privacy/data scope is unchanged.
# v0.9.255 Pass 178 - shared MortalShell2ModUI Controller Settings/Calibration/Test; support-bundle privacy/data scope is unchanged.
# v0.9.161 Pass 84 - retains the fail-closed current-version release-readiness evidence index and share-safe privacy boundary while preserving metadata-only pronunciation-normalization counts. It intentionally
# excludes TTSConfig.ini, Azure key storage, command payloads, narrated text,
# voice catalogs, crash dumps, and arbitrary system/game files.

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ModRoot = $PSScriptRoot
$ExpectedVersion = '0.9.263'
$ModsRoot = Split-Path -Parent $ModRoot
$UE4SSRoot = Split-Path -Parent $ModsRoot
$ConfigPath = Join-Path $ModRoot 'TTSConfig.ini'
$EngineStatusPath = Join-Path $ModRoot 'tts_engine_status.txt'
$UE4SSLogPath = Join-Path $UE4SSRoot 'UE4SS.log'
$OutputPath = Join-Path $ModRoot ('MortalShell2TTS_Support_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
$WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('MortalShell2TTS_Support_' + [Guid]::NewGuid().ToString('N'))

function ConvertTo-SafeSupportText([string]$Message) {
    if ($null -eq $Message) { return '' }
    $safe = [string]$Message
    try {
        $replacements = @(
            @([string]$ModRoot, '<MOD_DIR>'),
            @([string](Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MortalShell2TTS'), '<TTS_DATA>'),
            @([string][Environment]::GetFolderPath('UserProfile'), '%USERPROFILE%'),
            @([string][Environment]::GetFolderPath('LocalApplicationData'), '%LOCALAPPDATA%'),
            @([string][IO.Path]::GetTempPath().TrimEnd('\'), '%TEMP%')
        )
        foreach ($entry in $replacements) {
            $from = [string]$entry[0]
            if (-not [string]::IsNullOrWhiteSpace($from)) {
                $safe = [Text.RegularExpressions.Regex]::Replace($safe, [Text.RegularExpressions.Regex]::Escape($from), [string]$entry[1], [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
        }
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)\b[A-Z]:\\Users\\[^\\\r\n]+', '%USERPROFILE%')
        $identityReplacements = @(
            @([string][Environment]::UserName, '<USER>'),
            @([string][Environment]::MachineName, '<COMPUTER>'),
            @([string][Environment]::UserDomainName, '<DOMAIN>')
        )
        foreach ($entry in $identityReplacements) {
            $from = [string]$entry[0]
            if (-not [string]::IsNullOrWhiteSpace($from) -and $from.Length -ge 3) {
                $pattern = '(?i)(?<![A-Za-z0-9_.-])' + [Text.RegularExpressions.Regex]::Escape($from) + '(?![A-Za-z0-9_.-])'
                $safe = [Text.RegularExpressions.Regex]::Replace($safe, $pattern, [string]$entry[1])
            }
        }
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Ocp-Apim-Subscription-Key\s*[:=]\s*)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Authorization\s*[:=]\s*Bearer\s+)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)((?:MORTALSHELL2TTS_AZURE_KEY|AZURE_SPEECH_KEY)\s*[:=]\s*)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Azure(?:Speech)?Key\s*[:=]\s*)(?!missing\b|present\b|dpapi\b|environment\b)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?is)<speak\b.*?</speak>', '<SSML_REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?is)<pitch\b.*?</pitch>', '<SAPI_XML_REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)([?&](?:sig|key|token|code)=)[^&\s]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(DPAPI(?:Blob)?\s*[:=]\s*)[A-Za-z0-9+/=_-]{24,}', '$1<REDACTED>')
    } catch {}
    return $safe
}

function Read-SharedText([string]$Path, [int64]$MaxBytes = 2097152) {
    $stream = $null
    $reader = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        if ($MaxBytes -gt 0 -and $stream.Length -gt $MaxBytes) {
            throw ('support input exceeded safety limit bytes=' + $stream.Length + ' limit=' + $MaxBytes)
        }
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $false)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}

function Write-SafeFile([string]$Name, [string]$Content) {
    $destination = Join-Path $WorkRoot $Name
    [IO.File]::WriteAllText($destination, (ConvertTo-SafeSupportText $Content), $Utf8NoBom)
}

function Read-SharedTailText([string]$Path, [int64]$MaxBytes) {
    $stream = $null
    $reader = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $start = [Math]::Max([int64]0, $stream.Length - [Math]::Max([int64]4096, $MaxBytes))
        if ($start -gt 0) {
            $null = $stream.Seek($start, [IO.SeekOrigin]::Begin)
        }
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536, $false)
        if ($start -gt 0) {
            # The seek can land inside a UTF-8 character or line. Discard the first
            # partial line so the staged log starts at a clean diagnostic boundary.
            $null = $reader.ReadLine()
        }
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}


function Get-SupportSecretPatterns {
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @(
        '(?i)Ocp-Apim-Subscription-Key\s*[:=]\s*(?!<REDACTED>)[^\s;,]+',
        '(?i)Authorization\s*[:=]\s*Bearer\s+(?!<REDACTED>)[^\s;,]+',
        '(?i)(?:MORTALSHELL2TTS_AZURE_KEY|AZURE_SPEECH_KEY)\s*[:=]\s*(?!<REDACTED>)[^\s;,]+',
        '(?i)Azure(?:Speech)?Key\s*[:=]\s*(?!missing\b|present\b|dpapi\b|environment\b|<REDACTED>)[^\s;,]+',
        '(?i)DPAPI(?:Blob)?\s*[:=]\s*(?!<REDACTED>)[A-Za-z0-9+/=_-]{24,}',
        '(?i)\b[A-Z]:\\Users\\[^\\\r\n]+',
        '(?is)<speak\b.*?</speak>',
        '(?is)<pitch\b.*?</pitch>'
    )) { $patterns.Add($pattern) }

    # Fail closed if the final staged/archive content still contains this
    # machine's bare account/computer/domain identity. This complements path
    # sanitization and protects exception text that mentions an identity without
    # a filesystem path.
    foreach ($identity in @([string][Environment]::UserName, [string][Environment]::MachineName, [string][Environment]::UserDomainName)) {
        if (-not [string]::IsNullOrWhiteSpace($identity) -and $identity.Length -ge 3) {
            $patterns.Add('(?i)(?<![A-Za-z0-9_.-])' + [Text.RegularExpressions.Regex]::Escape($identity) + '(?![A-Za-z0-9_.-])')
        }
    }
    return $patterns.ToArray()
}

function Assert-NoSupportSecrets {
    $patterns = @(Get-SupportSecretPatterns)
    foreach ($file in @(Get-ChildItem -LiteralPath $WorkRoot -File -ErrorAction SilentlyContinue)) {
        $text = ''
        try { $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) } catch { continue }
        foreach ($pattern in $patterns) {
            if ($text -match $pattern) {
                throw ('Privacy self-audit blocked support bundle because a possible secret remained in ' + $file.Name)
            }
        }
    }
}

function Assert-SafeSupportArchive([string]$ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = $null
    $totalBytes = [int64]0
    $patterns = @(Get-SupportSecretPatterns)
    $forbiddenNamePatterns = @(
        '(?i)^TTSConfig\.ini(?:\.bak|\.tmp)?$',
        '(?i)^tts_(?:command|sequence)\.txt',
        '(?i)^tts_helper_heartbeat\.txt$' ,
        '(?i)^tts_azure_request_.+\.json$',
        '(?i)^tts_(?:voices|azure_voices|outputs)\.txt$',
        '(?i)^AzureSpeechKey\.dat(?:\.bak)?$',
        '(?i)\.(?:dmp|mdmp)$'
    )
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        if ($archive.Entries.Count -lt 1 -or $archive.Entries.Count -gt 32) { throw ('unexpected support ZIP entry count=' + $archive.Entries.Count) }
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Name) -or [string]$entry.FullName -ne [string]$entry.Name) {
                throw ('support ZIP contains an unexpected directory/path entry: ' + [string]$entry.FullName)
            }
            foreach ($namePattern in $forbiddenNamePatterns) {
                if ([string]$entry.Name -match $namePattern) { throw ('support ZIP contains forbidden runtime/private file: ' + [string]$entry.Name) }
            }
            if ([int64]$entry.Length -gt 8MB) { throw ('support ZIP entry exceeded 8 MB safety cap: ' + [string]$entry.Name) }
            $totalBytes += [int64]$entry.Length
            if ($totalBytes -gt 24MB) { throw 'support ZIP uncompressed content exceeded 24 MB safety cap.' }

            $stream = $null
            $reader = $null
            try {
                $stream = $entry.Open()
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536, $false)
                $text = $reader.ReadToEnd()
                foreach ($pattern in $patterns) {
                    if ($text -match $pattern) { throw ('post-compression privacy audit found a possible secret in ' + [string]$entry.Name) }
                }
            } finally {
                if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
                elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
            }
        }
    } finally {
        if ($null -ne $archive) { try { $archive.Dispose() } catch {} }
    }
}

function Get-SHA256Hex([string]$Path) {
    $stream = $null
    $sha = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    } finally {
        if ($null -ne $sha) { try { $sha.Dispose() } catch {} }
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}

function Get-ReleaseIntegritySummary {
    $manifestPath = Join-Path $ModRoot 'MortalShell2TTS_ReleaseManifest.sha256'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('MortalShell2TTS release-integrity summary')
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $lines.Add('Status=MANIFEST-MISSING')
        return ($lines -join "`r`n")
    }
    $failures = New-Object System.Collections.Generic.List[string]
    $verified = 0
    try {
        foreach ($raw in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
            $line = ([string]$raw).Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $match = [Text.RegularExpressions.Regex]::Match($line, '^([0-9A-Fa-f]{64})\s+\*(.+)$')
            if (-not $match.Success) { $failures.Add('<malformed>'); continue }
            $expected = $match.Groups[1].Value.ToLowerInvariant()
            $relative = $match.Groups[2].Value.Replace('/', '\').Trim()
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) { $failures.Add('<invalid-path>'); continue }
            $full = [IO.Path]::GetFullPath((Join-Path $ModRoot $relative))
            $rootPrefix = [IO.Path]::GetFullPath($ModRoot).TrimEnd('\') + '\'
            if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { $failures.Add($relative + ':outside-root'); continue }
            $verified++
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $failures.Add($relative + ':missing'); continue }
            if ((Get-SHA256Hex $full) -ne $expected) { $failures.Add($relative + ':hash-mismatch') }
        }
    } catch { $failures.Add('<verification-error>') }
    if ($failures.Count -eq 0 -and $verified -gt 0) {
        $lines.Add('Status=PASS')
        $lines.Add('VerifiedFiles=' + $verified)
    } else {
        $lines.Add('Status=CHECK')
        $lines.Add('VerifiedFiles=' + $verified)
        $lines.Add('Failures=' + (@($failures | Select-Object -First 12) -join ','))
    }
    return ($lines -join "`r`n")
}

function Write-SupportManifest {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('MortalShell2TTS support bundle manifest')
    foreach ($file in @(Get-ChildItem -LiteralPath $WorkRoot -File | Sort-Object Name)) {
        if ($file.Name -eq 'manifest.txt') { continue }
        $hash = 'Unavailable'
        try { $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant() } catch {}
        $lines.Add(($file.Name + "`t" + $file.Length + " bytes`tSHA256=" + $hash))
    }
    Write-SafeFile 'manifest.txt' ($lines -join "`r`n")
}

function Get-AllowListedConfigSummary {
    $allowed = @(
        'ConfigSchema','Narration','ReadDelayMs','AnnouncePageNumber','PanelOpacity','PanelFontSize',
        'Voice','AzureVoice','Rate','Volume','Pitch','VoiceStyle','SpeechQueue','DuplicateTextSeconds','PronunciationCorrections',
        'Engine','AudioOutput','AzureRegion','MenuKeybind','ControllerMenuBind'
    )
    $allowedSet = @{}
    foreach ($name in $allowed) { $allowedSet[$name.ToLowerInvariant()] = $name }
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $lines.Add('TTSConfig.ini: not present')
        return ($lines -join "`r`n")
    }
    try {
        foreach ($raw in ((Read-SharedText $ConfigPath 1048576) -split '\r?\n')) {
            $line = ([string]$raw).Trim()
            if ($line -eq '' -or $line.StartsWith('[') -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
            $equals = $line.IndexOf('=')
            if ($equals -lt 1) { continue }
            $key = $line.Substring(0, $equals).Trim()
            $lookup = $key.ToLowerInvariant()
            if (-not $allowedSet.ContainsKey($lookup)) { continue }
            $value = $line.Substring($equals + 1).Trim()
            if ($value.Length -gt 1024) { $value = '<VALUE TOO LONG - OMITTED>' }
            $lines.Add(($allowedSet[$lookup] + '=' + $value))
        }
    } catch {
        $lines.Add('Config summary read failed: ' + $_.Exception.Message)
    }
    return ($lines -join "`r`n")
}

function Get-UE4SSSummary {
    $maxRelevantLines = 2500
    $lines = New-Object 'System.Collections.Generic.Queue[string]'
    $omitted = 0
    if (-not (Test-Path -LiteralPath $UE4SSLogPath)) {
        return 'UE4SS.log: not found'
    }

    $stream = $null
    $reader = $null
    try {
        # UE4SS.log can become very large during long debug sessions. Stream it
        # instead of ReadAllText/splitting the complete file into memory, and keep
        # only a bounded tail of lines relevant to UE4SS identity or this mod.
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($UE4SSLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536, $false)
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($line -match 'UE4SS\s*-\s*v' -or $line -match 'UE4SS Build Configuration:' -or $line -match 'Found EngineVersion:' -or $line -match '\[MortalShell2TTS\]') {
                if ($lines.Count -ge $maxRelevantLines) {
                    $null = $lines.Dequeue()
                    $omitted++
                }
                $lines.Enqueue([string]$line)
            }
        }
    } catch {
        return ('UE4SS summary read failed: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }

    $result = New-Object System.Collections.Generic.List[string]
    if ($omitted -gt 0) {
        $result.Add("... $omitted older relevant UE4SS lines omitted by support collector ...")
    }
    foreach ($line in $lines) { $result.Add([string]$line) }
    if ($result.Count -eq 0) { $result.Add('UE4SS.log contained no matching MortalShell2TTS/identity lines') }
    return ($result -join "`r`n")
}


function Get-CurrentVersionEvidenceScope([string]$Text, [string]$MarkerPattern, [string]$Kind, [string]$Expected) {
    # Runtime logs intentionally persist across game/helper sessions. For RC evidence,
    # only the final contiguous run of the currently installed version is trustworthy;
    # otherwise an old 0.9.x session could accidentally satisfy a new checklist gate.
    # Multiple same-version sessions are retained so restart-persistence, helper
    # replacement, and soak evidence can span legitimate current-candidate restarts.
    $lines = @(([string]$Text) -split "`r?`n")
    $markers = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [Text.RegularExpressions.Regex]::Match([string]$lines[$index], $MarkerPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $version = ''
            try { $version = [string]$match.Groups['version'].Value } catch {}
            if ([string]::IsNullOrWhiteSpace($version) -and $match.Groups.Count -gt 1) { $version = [string]$match.Groups[1].Value }
            $markers.Add([pscustomobject]@{ Index = [int]$index; Version = $version })
        }
    }

    if ($markers.Count -eq 0) {
        return [pscustomobject]@{ Text = ''; Scoped = $false; ObservedVersion = 'none'; MarkerCount = 0; Reason = ($Kind + '-version-marker-not-found') }
    }

    $latest = $markers[$markers.Count - 1]
    if ([string]$latest.Version -ne [string]$Expected) {
        return [pscustomobject]@{ Text = ''; Scoped = $false; ObservedVersion = [string]$latest.Version; MarkerCount = 0; Reason = ($Kind + '-latest-version-mismatch') }
    }

    $startIndex = [int]$latest.Index
    $currentMarkerCount = 1
    for ($markerIndex = $markers.Count - 2; $markerIndex -ge 0; $markerIndex--) {
        $candidate = $markers[$markerIndex]
        if ([string]$candidate.Version -ne [string]$Expected) { break }
        $startIndex = [int]$candidate.Index
        $currentMarkerCount++
    }

    $scoped = New-Object System.Collections.Generic.List[string]
    for ($index = $startIndex; $index -lt $lines.Count; $index++) { $scoped.Add([string]$lines[$index]) }
    return [pscustomobject]@{
        Text = ($scoped -join "`r`n")
        Scoped = $true
        ObservedVersion = [string]$Expected
        MarkerCount = [int]$currentMarkerCount
        Reason = 'current-version-contiguous-run'
    }
}


function Get-UIRuntimeHealthSummary([string]$RelevantText) {
    # This is deliberately derived only from the bounded, allow-listed UE4SS tail
    # that is already eligible for the support bundle. It never reads narration IPC,
    # config secrets, arbitrary game logs, or unbounded files. The counts make long
    # open/close/browser stress sessions easier to evaluate without asking users to
    # manually count hundreds of DIAG lines.
    $text = [string]$RelevantText
    $lines = @($text -split "`r?`n")
    $result = New-Object System.Collections.Generic.List[string]
    $result.Add('MortalShell2TTS bounded UI/runtime lifecycle summary')
    $result.Add('Source=allow-listed UE4SS/MortalShell2TTS relevant-line tail')
    $result.Add('SourceLines=' + $lines.Count)

    $patterns = [ordered]@{
        SessionBegin = 'event=session\.begin(?:\s|$)'
        SessionReady = 'event=session\.ready(?:\s|$)'
        SessionEnd = 'event=session\.end(?:\s|$)'
        SessionFailure = 'event=session\.failure(?:\s|$)'
        BrowserOpen = 'event=voice\.browser(?=.*\baction=open(?:\s|$))'
        BrowserClose = 'event=voice\.browser(?=.*\baction=close(?:\s|$))'
        BrowserCommit = 'event=voice\.browser(?=.*\baction=commit(?:\s|$))'
        BrowserPollError = 'event=voice\.browser(?=.*\baction=poll-error(?:\s|$))'
        RendererMain = 'event=renderer\.profile(?=.*\bprofile=main(?:\s|$))'
        RendererBrowser = 'event=renderer\.profile(?=.*\bprofile=browser(?:\s|$))'
        BindCapturePollError = 'event=input\.bindCapture(?=.*\bstatus=poll-error(?:\s|$))'
        DetailsAnalogPollError = 'event=input\.detailsAnalog(?=.*\bstatus=poll-error(?:\s|$))'
        CloseQuarantineArmed = 'event=close\.quarantine(?=.*\bstage=armed(?:\s|$))'
        CloseScheduleFailure = 'event=close\.quarantine(?=.*\bstage=schedule-failed(?:\s|$))'
        CloseFinalize = 'event=delay\.callback(?=.*\blabel=close-finalize(?:\s|$))(?=.*\bstage=exit(?:\s|$))'
        ReaderOpen = 'event=reader\.lifecycle(?=.*\baction=open(?:\s|$))'
        ReaderPage = 'event=reader\.lifecycle(?=.*\baction=page(?:\s|$))'
        ReaderClose = 'event=reader\.lifecycle(?=.*\baction=close(?:\s|$))'
        ConfigLoaded = 'event=config\.runtime(?=.*\baction=loaded(?:\s|$))'
        ConfigInitialized = 'event=config\.runtime(?=.*\baction=initialized(?:\s|$))'
        NativeInteractBlockApply = 'event=modalIsolation\.effectApply(?=.*\bkey=interact(?:\s|$))(?=.*\bstatus=ok(?:\s|$))'
        UserPauseAcquire = 'event=modalIsolation\.pause(?=.*\baction=acquire(?:\s|$))(?=.*\breason=user-option(?:\s|$))(?=.*\bstatus=ok(?:\s|$))'
        UserPauseRelease = 'event=modalIsolation\.pause(?=.*\baction=release(?:\s|$))(?=.*\breason=user-option(?:\s|$))(?=.*\bstatus=ok(?:\s|$))'
        PausePreferenceOn = 'event=modalIsolation\.pausePreference(?=.*\benabled=true(?:\s|$))'
        PausePreferenceOff = 'event=modalIsolation\.pausePreference(?=.*\benabled=false(?:\s|$))'
        TransitionAdmissionBlocked = 'event=admission\.state(?=.*\ballowed=false(?:\s|$))(?=.*\bblockers=[^\r\n]*CurrentTransitionWidget)'
    }

    $issueCount = 0
    foreach ($entry in $patterns.GetEnumerator()) {
        $count = [Text.RegularExpressions.Regex]::Matches($text, [string]$entry.Value, [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
        $result.Add(([string]$entry.Key + '=' + $count))
        if ([string]$entry.Key -in @('SessionFailure','BrowserPollError','BindCapturePollError','DetailsAnalogPollError','CloseScheduleFailure')) {
            $issueCount += $count
        }
    }

    $maxSession = 0
    $maxSequence = 0
    foreach ($line in $lines) {
        $sessionMatch = [Text.RegularExpressions.Regex]::Match([string]$line, '\bsession=(\d+)\b')
        if ($sessionMatch.Success) {
            $value = 0
            if ([int]::TryParse($sessionMatch.Groups[1].Value, [ref]$value) -and $value -gt $maxSession) { $maxSession = $value }
        }
        $sequenceMatch = [Text.RegularExpressions.Regex]::Match([string]$line, '\bseq=(\d+)\b')
        if ($sequenceMatch.Success) {
            $value = 0
            if ([int]::TryParse($sequenceMatch.Groups[1].Value, [ref]$value) -and $value -gt $maxSequence) { $maxSequence = $value }
        }
    }
    $result.Add('HighestDiagnosticSession=' + $maxSession)
    $result.Add('HighestDiagnosticSequence=' + $maxSequence)
    $result.Add('ObservedIssueCount=' + $issueCount)
    if ($issueCount -eq 0) {
        $result.Add('ObservedHealth=NO-KNOWN-UI-POLL-OR-SESSION-FAILURE-IN-BOUNDED-TAIL')
    } else {
        $result.Add('ObservedHealth=CHECK-BOUNDED-TAIL-ISSUES')
    }
    $result.Add('Note=Counts are diagnostic evidence only; an unmatched final open/close can be normal if collection occurs while a panel is still open or if older lines fell outside the bounded tail.')
    return ($result -join "`r`n")
}

function Get-HelperRuntimeHealthSummary([string]$HelperText, [int]$RotationFilesPresent) {
    # Derived only from already share-safe helper logs. No narration IPC, raw config,
    # credential store, or voice catalog is opened here. This provides auditable
    # session/queue/fallback/shutdown evidence without requiring manual log counting.
    $text = [string]$HelperText
    $result = New-Object System.Collections.Generic.List[string]
    $result.Add('MortalShell2TTS bounded helper runtime summary')
    $result.Add('Source=share-safe bounded helper log generations')
    $result.Add('RotationFilesPresent=' + [Math]::Max(0, $RotationFilesPresent))

    $patterns = [ordered]@{
        HelperStarts = 'helper started; mode='
        SupportSummaries = 'support summary helper='
        HeartbeatInitialized = 'helper heartbeat initialized ready=True'
        HeartbeatCleanup = 'helper heartbeat cleanup removed=True'
        SessionHealthRecords = 'session health(?:\s|$)'
        CleanShutdowns = 'helper shutdown cleanup complete mode='
        BoundOwnerEnded = 'bound game process ended; gamePid='
        FallbackOwnerEnded = 'game process ended; fallback helper exiting'
        BrowserPreviews = 'browser preview seq='
        VoiceTests = '(?m)^\[[^\]]+\]\s+test seq='
        SpeakStarts = '(?m)^\[[^\]]+\]\s+speak seq='
        QueueEnqueueLines = 'speech queued seq='
        QueueAdvanceLines = 'speech queue advancing seq='
        QueueFullDrops = 'speech queue full; dropped seq='
        IgnoreDrops = 'speech ignored while active seq='
        SapiFallbackLines = 'fallback.*SAPI|SAPI.*fallback'
        AudioFallbackLines = 'falling back to Windows System Default|audio.*fallback'
        CommandReadFailures = 'command read failed|command IPC.*failed'
        HeartbeatWriteFailures = 'helper heartbeat write failed'
        AzureChildFailures = 'Azure stream.*failed|Azure child.*failed'
        LocalSpeakFailures = 'local speak failed'
        PreviewFailures = 'browser preview failed'
        TestFailures = '(?m)^\[[^\]]+\]\s+test failed seq='
        QueueAdvanceFailures = 'speech queue advance failed'
    }
    $issueCount = 0
    foreach ($entry in $patterns.GetEnumerator()) {
        $count = [Text.RegularExpressions.Regex]::Matches($text, [string]$entry.Value, [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
        $result.Add(([string]$entry.Key + '=' + $count))
        if ([string]$entry.Key -in @('CommandReadFailures','HeartbeatWriteFailures','AzureChildFailures','LocalSpeakFailures','PreviewFailures','TestFailures','QueueAdvanceFailures')) {
            $issueCount += $count
        }
    }

    $statNames = @('commands','speakRequests','testRequests','previewRequests','stopCommands','configCommands','localStarts','azureStarts','queueEnqueued','queueAdvanced','queueDropped','ignoreDropped','sapiFallbacks','audioFallbacks','azureChildFailures','commandReadErrors','loopIterations','gameLivenessChecks','sequenceStampChecks','sequenceReads','sequenceFallbackReads','activeWaits','idleWaits')
    $totals = @{}
    foreach ($name in $statNames) { $totals[$name] = [int64]0 }
    $maxDuration = [int64]0
    $healthRecords = [Text.RegularExpressions.Regex]::Matches($text, '(?im)^\[[^\]]+\]\s+session health\s+([^\r\n]+)')
    foreach ($record in $healthRecords) {
        $body = [string]$record.Groups[1].Value
        $durationMatch = [Text.RegularExpressions.Regex]::Match($body, '(?:^|\s)durationSeconds=(\d+)')
        if ($durationMatch.Success) {
            $duration = [int64]0
            if ([int64]::TryParse($durationMatch.Groups[1].Value, [ref]$duration) -and $duration -gt $maxDuration) { $maxDuration = $duration }
        }
        foreach ($name in $statNames) {
            $match = [Text.RegularExpressions.Regex]::Match($body, '(?:^|\s)' + [Text.RegularExpressions.Regex]::Escape($name) + '=(\d+)')
            if ($match.Success) {
                $value = [int64]0
                if ([int64]::TryParse($match.Groups[1].Value, [ref]$value)) { $totals[$name] = [int64]$totals[$name] + $value }
            }
        }
    }
    $result.Add('LongestCleanSessionSeconds=' + $maxDuration)
    foreach ($name in $statNames) { $result.Add(('Aggregate.' + $name + '=' + [string]$totals[$name])) }

    $queueModes = New-Object System.Collections.Generic.List[string]
    foreach ($mode in @('interrupt','queue','ignore')) {
        if ([Text.RegularExpressions.Regex]::IsMatch($text, '(?i)\bqueue=' + $mode + '(?:\s|$)')) { $queueModes.Add($mode) }
    }
    $result.Add('ObservedQueueModes=' + $(if ($queueModes.Count -gt 0) { $queueModes -join ',' } else { 'none' }))

    $backendModes = New-Object System.Collections.Generic.List[string]
    foreach ($mode in @('system_speech','azure_stream','sapi')) {
        if ([Text.RegularExpressions.Regex]::IsMatch($text, '(?i)\b(?:engine|backend)=' + [Text.RegularExpressions.Regex]::Escape($mode) + '(?:\s|$)')) { $backendModes.Add($mode) }
    }
    $result.Add('ObservedBackends=' + $(if ($backendModes.Count -gt 0) { $backendModes -join ',' } else { 'none' }))

    $starts = [Text.RegularExpressions.Regex]::Matches($text, 'helper started; mode=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $shutdowns = [Text.RegularExpressions.Regex]::Matches($text, 'helper shutdown cleanup complete mode=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $heartbeatCleanup = [Text.RegularExpressions.Regex]::Matches($text, 'helper heartbeat cleanup removed=True', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    if ($shutdowns -gt 0 -and $heartbeatCleanup -gt 0) { $result.Add('CleanShutdownEvidence=YES') } else { $result.Add('CleanShutdownEvidence=NOT-OBSERVED-IN-BOUNDED-LOGS') }
    $result.Add('ObservedIssueLikeCount=' + $issueCount)
    if ($issueCount -eq 0) { $result.Add('ObservedHealth=NO-KNOWN-HELPER-FAILURE-IN-BOUNDED-LOGS') }
    else { $result.Add('ObservedHealth=CHECK-HELPER-FAILURE-LINES') }
    $result.Add('Note=Failure-like counts are evidence, not automatic blame; deliberate bad-key/offline/fallback tests can intentionally create failure diagnostics.')
    $result.Add('Note=Start/shutdown counts can be incomplete if older lines rotated outside the bounded generations.')
    return ($result -join "`r`n")
}

function Get-RuntimeEvidenceSummary([string]$RelevantUE4SSText, [string]$HelperText, [bool]$UIVersionScoped, [bool]$HelperVersionScoped, [int]$UIMarkerCount, [int]$HelperMarkerCount, [string]$EvidenceVersion) {
    $uiText = [string]$RelevantUE4SSText
    $helper = [string]$HelperText
    $result = New-Object System.Collections.Generic.List[string]
    $result.Add('MortalShell2TTS runtime evidence summary')
    $result.Add('Scope=bounded share-safe logs only; this report does not prove tests that were not actually exercised')
    $result.Add('EvidenceExpectedVersion=' + [string]$EvidenceVersion)
    $result.Add('UIEvidenceScopedToExpectedVersion=' + $(if ($UIVersionScoped) { 'YES' } else { 'NO' }))
    $result.Add('HelperEvidenceScopedToExpectedVersion=' + $(if ($HelperVersionScoped) { 'YES' } else { 'NO' }))
    $result.Add('UIEvidenceCurrentVersionMarkers=' + [Math]::Max(0, $UIMarkerCount))
    $result.Add('HelperEvidenceCurrentVersionMarkers=' + [Math]::Max(0, $HelperMarkerCount))
    $result.Add('EvidenceCurrentVersionOnly=' + $(if ($UIVersionScoped -and $HelperVersionScoped) { 'YES' } else { 'NO' }))

    $counts = [ordered]@{
        ModUiDependencyReady = 'event=dependency\.modui(?=.*\bstatus=ready(?:\s|$))'
        ModUiHostRegistryPublished = 'event=dependency\.moduiHostRegistry(?=.*\bstatus=published(?:\s|$))'
        ModUiHostAcknowledged = 'event=dependency\.moduiHostAck(?=.*\bstatus=acknowledged(?:\s|$))'
        ModUiHostAckPending = 'event=dependency\.moduiHostAck(?=.*\bstatus=pending-core-continues(?:\s|$))'
        ModUiHostPhysicalReady = 'event=dependency\.moduiHostAck(?=.*\bphysicalHotkeyHost=true(?:\s|$))(?=.*\bstatus=acknowledged(?:\s|$))'
        ModUiHostControllerCaptureReady = 'event=dependency\.moduiHostAck(?=.*\bphysicalControllerCaptureHost=true(?:\s|$))(?=.*\bstatus=acknowledged(?:\s|$))'
        ControllerCaptureHostRequested = 'event=input\.bindCaptureHost(?=.*\bstatus=requested(?:\s|$))'
        ControllerCaptureDigitalHost = 'event=input\.bindCaptureDigital(?=.*\bsource=ModUIHost:[^\s]+)'
        ControllerCaptureHostFallback = 'event=input\.bindCaptureHost(?=.*\bstatus=consumer-fallback(?:\s|$))'
        ModUiHostOpenEvent = 'event=input\.openHostEvent(?=.*\bstatus=triggered(?:\s|$))'
        ModUiHostEventSuppressed = 'event=input\.hostEvent(?=.*\bstatus=consumed-suppressed(?:\s|$))'
        SettingsSessionBegin = 'event=session\.begin(?:\s|$)'
        SettingsSessionReady = 'event=session\.ready(?:\s|$)'
        SettingsSessionEnd = 'event=session\.end(?:\s|$)'
        SettingsSessionFailure = 'event=session\.failure(?:\s|$)'
        BrowserOpen = 'event=voice\.browser(?=.*\baction=open(?:\s|$))'
        BrowserClose = 'event=voice\.browser(?=.*\baction=close(?:\s|$))'
        BrowserCommit = 'event=voice\.browser(?=.*\baction=commit(?:\s|$))'
        BrowserPreview = 'event=voice\.browser(?=.*\baction=preview(?:\s|$))'
        VoiceProfileCapture = 'event=speech\.voiceProfile(?=.*\baction=capture(?:\s|$))'
        VoiceProfileApply = 'event=speech\.voiceProfile(?=.*\baction=apply(?:\s|$))'
        QueueSettingChanges = 'event=speech\.queueMode(?:\s|$)'
        DuplicateSettingChanges = 'event=speech\.duplicateSetting(?:\s|$)'
        DuplicateSuppressions = 'event=speech\.duplicate(?=.*\baction=suppressed(?:\s|$))'
        SpeechStop = 'event=speech\.stop(?:\s|$)'
        ReaderOpen = 'event=reader\.lifecycle(?=.*\baction=open(?:\s|$))'
        ReaderPageChange = 'event=reader\.lifecycle(?=.*\baction=page(?:\s|$))'
        ReaderClose = 'event=reader\.lifecycle(?=.*\baction=close(?:\s|$))'
        ConfigLoaded = 'event=config\.runtime(?=.*\baction=loaded(?:\s|$))'
        ConfigInitialized = 'event=config\.runtime(?=.*\baction=initialized(?:\s|$))'
        TransitionAdmissionBlocked = 'event=admission\.state(?=.*\ballowed=false(?:\s|$))(?=.*\bblockers=[^\r\n]*CurrentTransitionWidget)'
        BrowserPollError = 'event=voice\.browser(?=.*\baction=poll-error(?:\s|$))'
        CloseScheduleFailure = 'event=close\.quarantine(?=.*\bstage=schedule-failed(?:\s|$))'
    }
    foreach ($entry in $counts.GetEnumerator()) {
        $count = [Text.RegularExpressions.Regex]::Matches($uiText, [string]$entry.Value, [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
        $result.Add(([string]$entry.Key + '=' + $count))
    }

    # Config provenance contains source/schema only. It gives clean-install/upgrade
    # testing an objective marker without including TTSConfig.ini or voice values.
    $configSources = New-Object System.Collections.Generic.List[string]
    foreach ($source in @('current','backup','current-failsoft','defaults')) {
        if ([Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=config\.runtime(?=.*\baction=loaded(?:\s|$))(?=.*\bsource=' + [Text.RegularExpressions.Regex]::Escape($source) + '(?:\s|$))')) { $configSources.Add($source) }
    }
    $result.Add('ConfigSourcesObserved=' + $(if ($configSources.Count -gt 0) { $configSources -join ',' } else { 'none' }))
    $result.Add('CleanConfigDefaultObserved=' + $(if ($configSources -contains 'defaults') { 'YES' } else { 'NO' }))
    $result.Add('ConfigBackupRecoveryObserved=' + $(if ($configSources -contains 'backup') { 'YES' } else { 'NO' }))
    $result.Add('ConfigFailSoftObserved=' + $(if ($configSources -contains 'current-failsoft') { 'YES' } else { 'NO' }))
    $legacyMigration = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=config\.runtime(?=.*\baction=initialized(?:\s|$))(?=.*\bpreviousSchema=(?:1|2)(?:\s|$))(?=.*\bschema=3(?:\s|$))')
    $result.Add('LegacyConfigMigrationObserved=' + $(if ($legacyMigration) { 'YES' } else { 'NO' }))

    $readerOpens = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=reader\.lifecycle(?=.*\baction=open(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $readerCloses = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=reader\.lifecycle(?=.*\baction=close(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $transitionBlocks = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=admission\.state(?=.*\ballowed=false(?:\s|$))(?=.*\bblockers=[^\r\n]*CurrentTransitionWidget)', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $result.Add('LoreReaderOpenStressTarget50=' + [Math]::Min(50, $readerOpens) + '/50')
    $result.Add('LoreReaderOpenCloseObserved=' + $readerOpens + '/' + $readerCloses)
    $result.Add('TransitionAdmissionGuardObserved=' + $(if ($transitionBlocks -gt 0) { 'YES' } else { 'NO' }))

    $helperStarts = [Text.RegularExpressions.Regex]::Matches($helper, 'helper started; mode=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $helperShutdowns = [Text.RegularExpressions.Regex]::Matches($helper, 'helper shutdown cleanup complete mode=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $helperHealth = [Text.RegularExpressions.Regex]::Matches($helper, 'session health(?:\s|$)', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $heartbeatCleanup = [Text.RegularExpressions.Regex]::Matches($helper, 'helper heartbeat cleanup removed=True', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $result.Add('HelperStarts=' + $helperStarts)
    $result.Add('HelperCleanShutdowns=' + $helperShutdowns)
    $result.Add('HelperSessionHealthRecords=' + $helperHealth)
    $result.Add('HeartbeatCleanups=' + $heartbeatCleanup)

    # Pass 76 pronunciation-normalization evidence is metadata-only. The support
    # bundle never copies the editable pronunciation file or narrated text; it only
    # reports bounded counts already emitted by the helper.
    $pronunciationLoads = [Text.RegularExpressions.Regex]::Matches($helper, 'pronunciation corrections loaded effective=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $pronunciationApplications = [Text.RegularExpressions.Regex]::Matches($helper, 'pronunciation normalization applied context=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $pronunciationErrors = [Text.RegularExpressions.Regex]::Matches($helper, 'pronunciation (?:corrections reload failed|user override template could not be created)', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $pronunciationReplacementCount = 0
    foreach ($match in [Text.RegularExpressions.Regex]::Matches($helper, '(?i)pronunciation normalization applied[^\r\n]*\breplacements=(\d+)')) {
        $value = 0
        if ([int]::TryParse($match.Groups[1].Value, [ref]$value)) { $pronunciationReplacementCount += [int]$value }
    }
    $result.Add('PronunciationRuleLoads=' + $pronunciationLoads)
    $result.Add('PronunciationNormalizationApplications=' + $pronunciationApplications)
    $result.Add('PronunciationReplacementCount=' + $pronunciationReplacementCount)
    $result.Add('PronunciationErrors=' + $pronunciationErrors)

    # Pass 21: heartbeat/recovery evidence is deliberately metadata-only. It uses
    # process identity/lifecycle markers already written by the mod/helper, never
    # heartbeat-file contents, narration payloads, configuration, or credentials.
    $heartbeatFreshObserved = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=helper\.heartbeat(?=.*\baction=fresh(?:\s|$))')
    $heartbeatIdentityChanges = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=helper\.heartbeat(?=.*\baction=identity-changed(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $heartbeatStale = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=helper\.heartbeat(?=.*\baction=stale(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $helperRecoveryObserved = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=helper\.recovery(?=.*\bstatus=observed(?:\s|$))')
    $sameGameRecoveryObserved = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=helper\.recovery(?=.*\bstatus=observed(?:\s|$))(?=.*\bsameGamePid=true(?:\s|$))')
    $helperLaunchRequests = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=helper\.launch(?=.*\bstatus=requested(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $helperRecoveryLaunchRequests = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=helper\.launch(?=.*\bstatus=requested(?:\s|$))(?=.*\breason=heartbeat-recovery%3A|\breason=heartbeat-recovery:)', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $helperSettingsChecks = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=helper\.settingsOpenCheck(?:\s|$)', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $atomicHeartbeatSummaryPattern = '(?i)support summary helper=' + [Text.RegularExpressions.Regex]::Escape([string]$EvidenceVersion) + ' supportSchema=11[^\r\n]*\bheartbeatAtomic=true(?:\s|$)'
    $atomicHeartbeatSummary = [Text.RegularExpressions.Regex]::IsMatch($helper, $atomicHeartbeatSummaryPattern)

    # Corroborate a game-bound process replacement from helper logs without putting
    # the actual process identifiers into the shareable summary. Multiple distinct
    # helper PIDs for one exact owner PID is the expected shape of a recovered helper.
    $helperPidsByGame = @{}
    foreach ($line in ([string]$helper -split "`r?`n")) {
        $identity = [Text.RegularExpressions.Regex]::Match($line, '(?i)helper started; mode=exact-pid helperPid=(\d+) helperStartFileTimeUtc=(\d+) gamePid=(\d+)')
        if (-not $identity.Success) { continue }
        $gameKey = [string]$identity.Groups[3].Value
        $helperKey = [string]$identity.Groups[1].Value + ':' + [string]$identity.Groups[2].Value
        if (-not $helperPidsByGame.ContainsKey($gameKey)) { $helperPidsByGame[$gameKey] = @{} }
        $helperPidsByGame[$gameKey][$helperKey] = $true
    }
    $gameBoundReplacementCount = 0
    foreach ($gameKey in @($helperPidsByGame.Keys)) {
        if ($helperPidsByGame[$gameKey].Count -gt 1) { $gameBoundReplacementCount++ }
    }
    $gameBoundReplacementObserved = $gameBoundReplacementCount -gt 0
    $recoveryCorroborated = $sameGameRecoveryObserved -and $gameBoundReplacementObserved

    $result.Add('HelperHeartbeatFreshObserved=' + $(if ($heartbeatFreshObserved) { 'YES' } else { 'NO' }))
    $result.Add('HelperHeartbeatIdentityChanges=' + $heartbeatIdentityChanges)
    $result.Add('HelperHeartbeatStaleObservations=' + $heartbeatStale)
    $result.Add('HelperRecoveryObserved=' + $(if ($helperRecoveryObserved) { 'YES' } else { 'NO' }))
    $result.Add('HelperSameGamePidRecoveryObserved=' + $(if ($sameGameRecoveryObserved) { 'YES' } else { 'NO' }))
    $result.Add('HelperLaunchRequests=' + $helperLaunchRequests)
    $result.Add('HelperRecoveryLaunchRequests=' + $helperRecoveryLaunchRequests)
    $result.Add('HelperSettingsOpenChecks=' + $helperSettingsChecks)
    $result.Add('HelperAtomicHeartbeatSummaryObserved=' + $(if ($atomicHeartbeatSummary) { 'YES' } else { 'NO' }))
    $result.Add('HelperGameBoundProcessReplacementObserved=' + $(if ($gameBoundReplacementObserved) { 'YES' } else { 'NO' }))
    $result.Add('HelperGameBoundReplacementOwnerCount=' + $gameBoundReplacementCount)
    $result.Add('HelperRecoveryCorroborated=' + $(if ($recoveryCorroborated) { 'YES' } else { 'NO' }))

    $maxDuration = [int64]0
    foreach ($match in [Text.RegularExpressions.Regex]::Matches($helper, '(?i)session health[^\r\n]*\bdurationSeconds=(\d+)')) {
        $value = [int64]0
        if ([int64]::TryParse($match.Groups[1].Value, [ref]$value) -and $value -gt $maxDuration) { $maxDuration = $value }
    }
    $result.Add('LongestHelperSessionSeconds=' + $maxDuration)
    $result.Add('OneHourSoakObserved=' + $(if ($maxDuration -ge 3600) { 'YES' } else { 'NO' }))
    $result.Add('TwoHourSoakObserved=' + $(if ($maxDuration -ge 7200) { 'YES' } else { 'NO' }))

    $queueModeEvidence = New-Object System.Collections.Generic.List[string]
    foreach ($mode in @('interrupt','queue','ignore')) {
        if ([Text.RegularExpressions.Regex]::IsMatch($helper, '(?i)\bqueue=' + $mode + '(?:\s|$)')) { $queueModeEvidence.Add($mode) }
    }
    $result.Add('QueueModesObserved=' + $(if ($queueModeEvidence.Count -gt 0) { $queueModeEvidence -join ',' } else { 'none' }))
    $result.Add('QueueEnqueuedEvidence=' + [Text.RegularExpressions.Regex]::Matches($helper, 'speech queued seq=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count)
    $result.Add('QueueAdvancedEvidence=' + [Text.RegularExpressions.Regex]::Matches($helper, 'speech queue advancing seq=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count)
    $result.Add('IgnoreDroppedEvidence=' + [Text.RegularExpressions.Regex]::Matches($helper, 'speech ignored while active seq=', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count)

    # Pass 20 closes several remaining evidence gaps without broadening the support
    # privacy boundary. These are only mode/window/profile identifiers already
    # present in allow-listed metadata diagnostics; no narration or Browser search
    # contents are copied into the summary.
    $queueUiModes = New-Object System.Collections.Generic.List[string]
    foreach ($mode in @('interrupt','queue','ignore')) {
        if ([Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=speech\.queueMode(?=.*\bmode=' + $mode + '(?:\s|$))')) { $queueUiModes.Add($mode) }
    }
    $result.Add('QueueModeSettingsObserved=' + $(if ($queueUiModes.Count -gt 0) { $queueUiModes -join ',' } else { 'none' }))
    $result.Add('QueueModeSettingCoverage=' + $queueUiModes.Count + '/3')

    $duplicateWindows = New-Object System.Collections.Generic.List[string]
    foreach ($seconds in @(0,1,3,5,10)) {
        if ([Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=speech\.duplicateSetting(?=.*\bseconds=' + $seconds + '(?:\s|$))')) { $duplicateWindows.Add([string]$seconds) }
    }
    $result.Add('DuplicateWindowsObserved=' + $(if ($duplicateWindows.Count -gt 0) { $duplicateWindows -join ',' } else { 'none' }))
    $result.Add('DuplicateWindowCoverage=' + $duplicateWindows.Count + '/5')

    $duplicateSuppressWindows = New-Object System.Collections.Generic.List[string]
    foreach ($seconds in @(1,3,5,10)) {
        if ([Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=speech\.duplicate(?=.*\baction=suppressed(?:\s|$))(?=.*\bseconds=' + $seconds + '(?:\s|$))')) { $duplicateSuppressWindows.Add([string]$seconds) }
    }
    $result.Add('DuplicateSuppressionWindowsObserved=' + $(if ($duplicateSuppressWindows.Count -gt 0) { $duplicateSuppressWindows -join ',' } else { 'none' }))
    $result.Add('DuplicateSuppressionWindowCoverage=' + $duplicateSuppressWindows.Count + '/4')

    $readerCloseStop = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=speech\.stop(?=.*\breason=reader closed(?:\s|$))(?=.*\bsent=true(?:\s|$))')
    $result.Add('ReaderCloseStopObserved=' + $(if ($readerCloseStop) { 'YES' } else { 'NO' }))

    $profileIds = @{}
    $profileEngines = @{}
    $lastProfileId = ''
    $profileRoundTrip = $false
    $storedProfileApplies = 0
    foreach ($line in ([string]$uiText -split "`r?`n")) {
        if ($line -notmatch '(?i)event=speech\.voiceProfile(?:\s|$)') { continue }
        $actionMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)action=([^\s]+)')
        $engineMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)engine=([^\s]+)')
        $idMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)profileId=([^\s]+)')
        $sourceMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)profileSource=([^\s]+)')
        if ($engineMatch.Success) { $profileEngines[$engineMatch.Groups[1].Value.ToLowerInvariant()] = $true }
        if (-not $idMatch.Success) { continue }
        $profileId = $idMatch.Groups[1].Value
        $action = $(if ($actionMatch.Success) { $actionMatch.Groups[1].Value.ToLowerInvariant() } else { '' })
        $profileSource = $(if ($sourceMatch.Success) { $sourceMatch.Groups[1].Value.ToLowerInvariant() } else { '' })
        if ($action -eq 'apply' -and $profileSource -eq 'stored') {
            $storedProfileApplies++
            if ($profileIds.ContainsKey($profileId) -and -not [string]::IsNullOrWhiteSpace($lastProfileId) -and $lastProfileId -ne $profileId) { $profileRoundTrip = $true }
        }
        $profileIds[$profileId] = $true
        $lastProfileId = $profileId
    }
    $profileEngineNames = @($profileEngines.Keys | Sort-Object)
    $result.Add('VoiceProfileDistinctProfilesObserved=' + $profileIds.Count)
    $result.Add('VoiceProfileEnginesObserved=' + $(if ($profileEngineNames.Count -gt 0) { $profileEngineNames -join ',' } else { 'none' }))
    $result.Add('VoiceProfileStoredApplyEvidence=' + $storedProfileApplies)
    $result.Add('VoiceProfileRoundTripObserved=' + $(if ($profileRoundTrip) { 'YES' } else { 'NO' }))
    $wholeMenuCommit = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=voice\.browser(?=.*\baction=commit(?:\s|$))(?=.*\bsource=menu-close(?:\s|$))')
    $result.Add('VoiceBrowserWholeMenuCommitObserved=' + $(if ($wholeMenuCommit) { 'YES' } else { 'NO' }))

    $settingsOpens = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=session\.begin(?:\s|$)', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $browserOpens = [Text.RegularExpressions.Regex]::Matches($uiText, 'event=voice\.browser(?=.*\baction=open(?:\s|$))', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $result.Add('SettingsOpenStressTarget50=' + [Math]::Min(50, $settingsOpens) + '/50')
    $result.Add('BrowserOpenStressTarget50=' + [Math]::Min(50, $browserOpens) + '/50')
    $settingsInputSources = New-Object System.Collections.Generic.List[string]
    foreach ($source in @('keyboard','controller')) {
        if ([Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=session\.begin(?=.*\bsource=' + $source + '(?:\s|$))')) { $settingsInputSources.Add($source) }
    }
    $result.Add('SettingsOpenSourcesObserved=' + $(if ($settingsInputSources.Count -gt 0) { $settingsInputSources -join ',' } else { 'none' }))
    $result.Add('SettingsOpenSourceCoverage=' + $settingsInputSources.Count + '/2')

    # Pass 20 release-evidence gap closure builds on the Pass 19 release-matrix evidence. Every field below is derived from metadata-only
    # DIAG events; browser search contents and recorded binding values are not copied
    # into this summary. This lets one normal support bundle show which input/display
    # paths were actually exercised without claiming unobserved paths passed.
    $viewportProfiles = New-Object System.Collections.Generic.List[string]
    $viewportSeen = @{}
    $viewportResolutionSeen = @{}
    $viewportScaleSeen = @{}
    $mainViewport = $false
    $browserViewport = $false
    foreach ($line in ([string]$uiText -split "`r?`n")) {
        if ($line -notmatch '(?i)event=renderer\.viewport(?:\s|$)') { continue }
        $profileMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)profile=([^\s]+)')
        $widthMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)width=(\d+)')
        $heightMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)height=(\d+)')
        $scaleMatch = [Text.RegularExpressions.Regex]::Match($line, '(?i)(?:^|\s)scale=([0-9.]+)')
        if (-not ($profileMatch.Success -and $widthMatch.Success -and $heightMatch.Success)) { continue }
        $profile = $profileMatch.Groups[1].Value.ToLowerInvariant()
        if ($profile -eq 'main') { $mainViewport = $true }
        if ($profile -eq 'browser') { $browserViewport = $true }
        $scale = $(if ($scaleMatch.Success) { $scaleMatch.Groups[1].Value } else { '?' })
        $resolution = $widthMatch.Groups[1].Value + 'x' + $heightMatch.Groups[1].Value
        $viewportResolutionSeen[$resolution] = $true
        if ($scale -ne '?') { $viewportScaleSeen[$scale] = $true }
        $descriptor = $profile + ':' + $resolution + '@' + $scale
        if (-not $viewportSeen.ContainsKey($descriptor) -and $viewportProfiles.Count -lt 16) {
            $viewportSeen[$descriptor] = $true
            $viewportProfiles.Add($descriptor)
        }
    }
    $result.Add('MainViewportObserved=' + $(if ($mainViewport) { 'YES' } else { 'NO' }))
    $result.Add('BrowserViewportObserved=' + $(if ($browserViewport) { 'YES' } else { 'NO' }))
    $result.Add('ViewportProfilesObserved=' + $(if ($viewportProfiles.Count -gt 0) { $viewportProfiles -join ',' } else { 'none' }))
    $resolutionTargets = New-Object System.Collections.Generic.List[string]
    foreach ($target in @('1920x1080','2048x1152','2560x1440','3840x2160')) { if ($viewportResolutionSeen.ContainsKey($target)) { $resolutionTargets.Add($target) } }
    $result.Add('ViewportResolutionTargetsObserved=' + $(if ($resolutionTargets.Count -gt 0) { $resolutionTargets -join ',' } else { 'none' }))
    $result.Add('ViewportResolutionCoverage=' + $resolutionTargets.Count + '/4')
    $result.Add('ViewportDistinctScalesObserved=' + $viewportScaleSeen.Count)

    $browserEvidence = [ordered]@{
        KeyboardRow = 'event=voice\.browser\.input(?=.*\baction=row(?:\s|$))(?=.*\bsource=keyboard(?:\s|$))'
        ControllerRow = 'event=voice\.browser\.input(?=.*\baction=row(?:\s|$))(?=.*\bsource=controller-native(?:\s|$))'
        HoldRepeat = 'event=voice\.browser(?=.*\baction=hold-repeat(?:\s|$))'
        DPadHold = 'event=voice\.browser(?=.*\baction=hold-repeat(?:\s|$))(?=.*\bsources=[^\r\n]*dpad)'
        LeftStickHold = 'event=voice\.browser(?=.*\baction=hold-repeat(?:\s|$))(?=.*\bsources=[^\r\n]*left-stick)'
        WheelRow = 'event=input\.mouse\.wheel(?=.*\bmode=row(?:\s|$))'
        WheelPage = 'event=input\.mouse\.wheel(?=.*\bmode=page(?:\s|$))'
        PageKey = 'event=voice\.browser\.input(?=.*\baction=page(?:\s|$))(?=.*\bsource=keyboard-page-key(?:\s|$))'
        PageKeyRepeat = 'event=voice\.browser(?=.*\baction=page-hold-repeat(?:\s|$))(?=.*\bsource=keyboard(?:\s|$))'
        RightStickPage = 'event=voice\.browser(?=.*\baction=right-stick-page-(?:first|repeat)(?:\s|$))'
        Home = 'event=voice\.browser(?=.*\baction=jump(?:\s|$))(?=.*\btarget=start(?:\s|$))'
        End = 'event=voice\.browser(?=.*\baction=jump(?:\s|$))(?=.*\btarget=end(?:\s|$))'
        UppercaseSearch = 'event=voice\.browser\.input(?=.*\baction=search(?:\s|$))(?=.*\bkind=letter(?:\s|$))(?=.*\bshifted=true(?:\s|$))'
        Backspace = 'event=voice\.browser\.input(?=.*\baction=search(?:\s|$))(?=.*\bkind=backspace(?:\s|$))'
        ClearSearch = 'event=voice\.browser\.input(?=.*\baction=search(?:\s|$))(?=.*\bkind=clear(?:\s|$))'
        Favorite = 'event=voice\.browser\.input(?=.*\baction=favorite(?:\s|$))'
        Gender = 'event=voice\.browser\.input(?=.*\baction=gender(?:\s|$))'
        Select = 'event=voice\.browser\.input(?=.*\baction=select(?:\s|$))'
        Preview = 'event=voice\.browser(?=.*\baction=preview(?:\s|$))'
        CloseApply = 'event=voice\.browser(?=.*\baction=close(?:\s|$))'
    }
    $browserObserved = New-Object System.Collections.Generic.List[string]
    $browserMissing = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $browserEvidence.GetEnumerator()) {
        $hit = [Text.RegularExpressions.Regex]::IsMatch($uiText, [string]$entry.Value, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $result.Add(('BrowserInput.' + [string]$entry.Key + '=' + $(if ($hit) { 'YES' } else { 'NO' })))
        if ($hit) { $browserObserved.Add([string]$entry.Key) } else { $browserMissing.Add([string]$entry.Key) }
    }
    $result.Add('BrowserInputCoverage=' + $browserObserved.Count + '/' + $browserEvidence.Count)
    $result.Add('BrowserInputMissing=' + $(if ($browserMissing.Count -gt 0) { $browserMissing -join ',' } else { 'none' }))

    $recorderEvidence = [ordered]@{
        KeyboardChord = 'event=input\.bindCapture(?=.*\bstatus=committed(?:\s|$))(?=.*\bkind=keyboard(?:\s|$))(?=.*\bmode=chord(?:\s|$))'
        ControllerChord = 'event=input\.bindCapture(?=.*\bstatus=committed(?:\s|$))(?=.*\bkind=controller(?:\s|$))(?=.*\bmode=chord(?:\s|$))'
        KeyboardSequence = 'event=input\.bindCapture(?=.*\bstatus=committed(?:\s|$))(?=.*\bkind=keyboard(?:\s|$))(?=.*\bmode=sequence(?:\s|$))'
        ControllerSequence = 'event=input\.bindCapture(?=.*\bstatus=committed(?:\s|$))(?=.*\bkind=controller(?:\s|$))(?=.*\bmode=sequence(?:\s|$))'
        EscapeCancel = 'event=input\.bindCapture(?=.*\bstatus=cancelled(?:\s|$))(?=.*\bsource=Escape(?:%20|\s)+alone(?:\s|$))'
        CircleCancel = 'event=input\.bindCapture(?=.*\bstatus=cancelled(?:\s|$))(?=.*\bsource=Circle(?:%20|\s)+alone(?:\s|$))'
        AnalogCapture = 'event=input\.bindCaptureAnalog(?=.*\bstatus=captured-direction(?:\s|$))'
        AnalogRearm = 'event=input\.bindCaptureAnalog(?=.*\bstatus=neutral-rearmed(?:\s|$))'
    }
    $recorderObserved = 0
    foreach ($entry in $recorderEvidence.GetEnumerator()) {
        $hit = [Text.RegularExpressions.Regex]::IsMatch($uiText, [string]$entry.Value, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $result.Add(('Recorder.' + [string]$entry.Key + '=' + $(if ($hit) { 'YES' } else { 'NO' })))
        if ($hit) { $recorderObserved++ }
    }
    $result.Add('RecorderCoverage=' + $recorderObserved + '/' + $recorderEvidence.Count)

    $conflictGameOk = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=input\.bindConflictScan(?=.*\bstatus=complete(?:\s|$))(?=.*\bgameScan=ok(?:\s|$))')
    $conflictGameUnavailable = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=input\.bindConflictScan(?=.*\bstatus=complete(?:\s|$))(?=.*\bgameScan=(?:controller-unavailable|player-input-unavailable|mappings-unavailable:[^\s]*|mapping-count-unavailable:[^\s]*)(?:\s|$))')
    $conflictRegistryUnavailable = [Text.RegularExpressions.Regex]::IsMatch($uiText, '(?i)event=input\.bindConflictScan(?=.*\bstatus=complete(?:\s|$))(?=.*\bregistryScan=(?:unavailable|enum-tables-unavailable)(?:\s|$))')
    $result.Add('Conflict.GameScanOkObserved=' + $(if ($conflictGameOk) { 'YES' } else { 'NO' }))
    $result.Add('Conflict.GameScanUnavailableObserved=' + $(if ($conflictGameUnavailable) { 'YES' } else { 'NO' }))
    $result.Add('Conflict.RegistryUnavailableObserved=' + $(if ($conflictRegistryUnavailable) { 'YES' } else { 'NO' }))

    $result.Add('NormalHelperShutdownEvidence=' + $(if ($helperShutdowns -gt 0 -and $heartbeatCleanup -gt 0) { 'YES' } else { 'NOT-OBSERVED' }))
    $result.Add('Note=Use this as objective evidence alongside the release-candidate guide; visual correctness, audible behavior, transitions, and crash attribution still require human/runtime judgment.')
    return ($result -join "`r`n")
}


function Get-EvidenceMap([string]$Text) {
    $map = @{}
    foreach ($line in ([string]$Text -split "`r?`n")) {
        $match = [Text.RegularExpressions.Regex]::Match([string]$line, '^([^=]+)=(.*)$')
        if ($match.Success) {
            $name = [string]$match.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) { $map[$name] = [string]$match.Groups[2].Value.Trim() }
        }
    }
    return $map
}

function Test-EvidenceSetContains([hashtable]$Map, [string]$Name, [string[]]$RequiredValues) {
    if ($null -eq $Map -or -not $Map.ContainsKey($Name)) { return $false }
    $seen = @{}
    foreach ($value in ([string]$Map[$Name] -split ',')) {
        $clean = ([string]$value).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($clean) -and $clean -ne 'none') { $seen[$clean] = $true }
    }
    foreach ($required in $RequiredValues) {
        if (-not $seen.ContainsKey(([string]$required).ToLowerInvariant())) { return $false }
    }
    return $true
}

function Get-ReleaseReadinessSummary([string]$RuntimeEvidenceText, [string]$HelperRuntimeText, [string]$UIRuntimeText, [string]$EvidenceVersion) {
    # This is an evidence index, not an automatic claim that 1.0 is ready. It only
    # turns already share-safe/current-version summary fields into a compact list of
    # runtime gates that were actually observed. Visual correctness, audible timing,
    # physical-device behavior, transitions, crash attribution, clean-install restart
    # persistence, and live Azure failure handling still require human verification.
    $runtime = Get-EvidenceMap $RuntimeEvidenceText
    $helper = Get-EvidenceMap $HelperRuntimeText
    $ui = Get-EvidenceMap $UIRuntimeText
    $result = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[string]
    $observedCount = 0
    $totalCount = 0

    $expectedMatches = $runtime.ContainsKey('EvidenceExpectedVersion') -and ([string]$runtime['EvidenceExpectedVersion'] -eq [string]$EvidenceVersion)
    $versionScoped = $expectedMatches -and $runtime.ContainsKey('EvidenceCurrentVersionOnly') -and ([string]$runtime['EvidenceCurrentVersionOnly'] -eq 'YES')

    $queueModes = $versionScoped -and (Test-EvidenceSetContains $runtime 'QueueModesObserved' @('interrupt','queue','ignore'))
    $profileEngines = $versionScoped -and (Test-EvidenceSetContains $runtime 'VoiceProfileEnginesObserved' @('system_speech','azure'))
    $optionalPauseCycle = (
        $versionScoped -and
        $ui.ContainsKey('NativeInteractBlockApply') -and ([int]$ui['NativeInteractBlockApply'] -gt 0) -and
        $ui.ContainsKey('UserPauseAcquire') -and ([int]$ui['UserPauseAcquire'] -gt 0) -and
        $ui.ContainsKey('UserPauseRelease') -and ([int]$ui['UserPauseRelease'] -gt 0) -and
        $ui.ContainsKey('PausePreferenceOn') -and ([int]$ui['PausePreferenceOn'] -gt 0) -and
        $ui.ContainsKey('PausePreferenceOff') -and ([int]$ui['PausePreferenceOff'] -gt 0)
    )

    $gates = @(
        @('VersionScope', $versionScoped, ('expected=' + [string]$EvidenceVersion + '; evidence=' + $(if ($runtime.ContainsKey('EvidenceExpectedVersion')) { [string]$runtime['EvidenceExpectedVersion'] } else { 'none' }) + '; currentVersionOnly=' + $(if ($runtime.ContainsKey('EvidenceCurrentVersionOnly')) { [string]$runtime['EvidenceCurrentVersionOnly'] } else { 'NO' }))),
        @('UIHealth', ($versionScoped -and $ui.ContainsKey('ObservedHealth') -and [string]$ui['ObservedHealth'] -eq 'NO-KNOWN-UI-POLL-OR-SESSION-FAILURE-IN-BOUNDED-TAIL'), $(if ($ui.ContainsKey('ObservedHealth')) { [string]$ui['ObservedHealth'] } else { 'not-observed' })),
        @('OptionalMenuPauseCycle', $optionalPauseCycle, ('interact=' + $(if ($ui.ContainsKey('NativeInteractBlockApply')) { [string]$ui['NativeInteractBlockApply'] } else { '0' }) + '; acquire=' + $(if ($ui.ContainsKey('UserPauseAcquire')) { [string]$ui['UserPauseAcquire'] } else { '0' }) + '; release=' + $(if ($ui.ContainsKey('UserPauseRelease')) { [string]$ui['UserPauseRelease'] } else { '0' }) + '; on=' + $(if ($ui.ContainsKey('PausePreferenceOn')) { [string]$ui['PausePreferenceOn'] } else { '0' }) + '; off=' + $(if ($ui.ContainsKey('PausePreferenceOff')) { [string]$ui['PausePreferenceOff'] } else { '0' }))),
        @('HelperHealth', ($versionScoped -and $helper.ContainsKey('ObservedHealth') -and [string]$helper['ObservedHealth'] -eq 'NO-KNOWN-HELPER-FAILURE-IN-BOUNDED-LOGS'), $(if ($helper.ContainsKey('ObservedHealth')) { [string]$helper['ObservedHealth'] } else { 'not-observed' })),
        @('VoiceProfileRoundTrip', ($versionScoped -and $runtime.ContainsKey('VoiceProfileRoundTripObserved') -and [string]$runtime['VoiceProfileRoundTripObserved'] -eq 'YES'), ('roundTrip=' + $(if ($runtime.ContainsKey('VoiceProfileRoundTripObserved')) { [string]$runtime['VoiceProfileRoundTripObserved'] } else { 'NO' }) + '; storedApplies=' + $(if ($runtime.ContainsKey('VoiceProfileStoredApplyEvidence')) { [string]$runtime['VoiceProfileStoredApplyEvidence'] } else { '0' }))),
        @('VoiceProfileCrossEngine', $profileEngines, ('engines=' + $(if ($runtime.ContainsKey('VoiceProfileEnginesObserved')) { [string]$runtime['VoiceProfileEnginesObserved'] } else { 'none' }))),
        @('QueueSettings', ($versionScoped -and $runtime.ContainsKey('QueueModeSettingCoverage') -and [string]$runtime['QueueModeSettingCoverage'] -eq '3/3'), ('coverage=' + $(if ($runtime.ContainsKey('QueueModeSettingCoverage')) { [string]$runtime['QueueModeSettingCoverage'] } else { '0/3' }))),
        @('QueueHelperModes', $queueModes, ('observed=' + $(if ($runtime.ContainsKey('QueueModesObserved')) { [string]$runtime['QueueModesObserved'] } else { 'none' }))),
        @('ReaderCloseStop', ($versionScoped -and $runtime.ContainsKey('ReaderCloseStopObserved') -and [string]$runtime['ReaderCloseStopObserved'] -eq 'YES'), ('observed=' + $(if ($runtime.ContainsKey('ReaderCloseStopObserved')) { [string]$runtime['ReaderCloseStopObserved'] } else { 'NO' }))),
        @('DuplicateSettings', ($versionScoped -and $runtime.ContainsKey('DuplicateWindowCoverage') -and [string]$runtime['DuplicateWindowCoverage'] -eq '5/5'), ('coverage=' + $(if ($runtime.ContainsKey('DuplicateWindowCoverage')) { [string]$runtime['DuplicateWindowCoverage'] } else { '0/5' }))),
        @('DuplicateSuppressionWindows', ($versionScoped -and $runtime.ContainsKey('DuplicateSuppressionWindowCoverage') -and [string]$runtime['DuplicateSuppressionWindowCoverage'] -eq '4/4'), ('coverage=' + $(if ($runtime.ContainsKey('DuplicateSuppressionWindowCoverage')) { [string]$runtime['DuplicateSuppressionWindowCoverage'] } else { '0/4' }))),
        @('BrowserInputMatrix', ($versionScoped -and $runtime.ContainsKey('BrowserInputCoverage') -and [string]$runtime['BrowserInputCoverage'] -eq '20/20'), ('coverage=' + $(if ($runtime.ContainsKey('BrowserInputCoverage')) { [string]$runtime['BrowserInputCoverage'] } else { '0/20' }))),
        @('RecorderMatrix', ($versionScoped -and $runtime.ContainsKey('RecorderCoverage') -and [string]$runtime['RecorderCoverage'] -eq '8/8'), ('coverage=' + $(if ($runtime.ContainsKey('RecorderCoverage')) { [string]$runtime['RecorderCoverage'] } else { '0/8' }))),
        @('SettingsInputSources', ($versionScoped -and $runtime.ContainsKey('SettingsOpenSourceCoverage') -and [string]$runtime['SettingsOpenSourceCoverage'] -eq '2/2'), ('coverage=' + $(if ($runtime.ContainsKey('SettingsOpenSourceCoverage')) { [string]$runtime['SettingsOpenSourceCoverage'] } else { '0/2' }))),
        @('ConflictGameScan', ($versionScoped -and $runtime.ContainsKey('Conflict.GameScanOkObserved') -and [string]$runtime['Conflict.GameScanOkObserved'] -eq 'YES'), ('gameScanOk=' + $(if ($runtime.ContainsKey('Conflict.GameScanOkObserved')) { [string]$runtime['Conflict.GameScanOkObserved'] } else { 'NO' }))),
        @('MainAndBrowserViewport', ($versionScoped -and $runtime.ContainsKey('MainViewportObserved') -and [string]$runtime['MainViewportObserved'] -eq 'YES' -and $runtime.ContainsKey('BrowserViewportObserved') -and [string]$runtime['BrowserViewportObserved'] -eq 'YES'), ('main=' + $(if ($runtime.ContainsKey('MainViewportObserved')) { [string]$runtime['MainViewportObserved'] } else { 'NO' }) + '; browser=' + $(if ($runtime.ContainsKey('BrowserViewportObserved')) { [string]$runtime['BrowserViewportObserved'] } else { 'NO' }))),
        @('ResolutionTargets', ($versionScoped -and $runtime.ContainsKey('ViewportResolutionCoverage') -and [string]$runtime['ViewportResolutionCoverage'] -eq '4/4'), ('coverage=' + $(if ($runtime.ContainsKey('ViewportResolutionCoverage')) { [string]$runtime['ViewportResolutionCoverage'] } else { '0/4' }))),
        @('SettingsStress50', ($versionScoped -and $runtime.ContainsKey('SettingsOpenStressTarget50') -and [string]$runtime['SettingsOpenStressTarget50'] -eq '50/50'), ('observed=' + $(if ($runtime.ContainsKey('SettingsOpenStressTarget50')) { [string]$runtime['SettingsOpenStressTarget50'] } else { '0/50' }))),
        @('BrowserStress50', ($versionScoped -and $runtime.ContainsKey('BrowserOpenStressTarget50') -and [string]$runtime['BrowserOpenStressTarget50'] -eq '50/50'), ('observed=' + $(if ($runtime.ContainsKey('BrowserOpenStressTarget50')) { [string]$runtime['BrowserOpenStressTarget50'] } else { '0/50' }))),
        @('LoreStress50', ($versionScoped -and $runtime.ContainsKey('LoreReaderOpenStressTarget50') -and [string]$runtime['LoreReaderOpenStressTarget50'] -eq '50/50'), ('observed=' + $(if ($runtime.ContainsKey('LoreReaderOpenStressTarget50')) { [string]$runtime['LoreReaderOpenStressTarget50'] } else { '0/50' }))),
        @('TransitionAdmissionGuard', ($versionScoped -and $runtime.ContainsKey('TransitionAdmissionGuardObserved') -and [string]$runtime['TransitionAdmissionGuardObserved'] -eq 'YES'), ('observed=' + $(if ($runtime.ContainsKey('TransitionAdmissionGuardObserved')) { [string]$runtime['TransitionAdmissionGuardObserved'] } else { 'NO' }))),
        @('HelperRecovery', ($versionScoped -and $runtime.ContainsKey('HelperRecoveryCorroborated') -and [string]$runtime['HelperRecoveryCorroborated'] -eq 'YES'), ('corroborated=' + $(if ($runtime.ContainsKey('HelperRecoveryCorroborated')) { [string]$runtime['HelperRecoveryCorroborated'] } else { 'NO' }))),
        @('CleanConfigDefaults', ($versionScoped -and $runtime.ContainsKey('CleanConfigDefaultObserved') -and [string]$runtime['CleanConfigDefaultObserved'] -eq 'YES'), ('observed=' + $(if ($runtime.ContainsKey('CleanConfigDefaultObserved')) { [string]$runtime['CleanConfigDefaultObserved'] } else { 'NO' }))),
        @('LegacyConfigMigration', ($versionScoped -and $runtime.ContainsKey('LegacyConfigMigrationObserved') -and [string]$runtime['LegacyConfigMigrationObserved'] -eq 'YES'), ('observed=' + $(if ($runtime.ContainsKey('LegacyConfigMigrationObserved')) { [string]$runtime['LegacyConfigMigrationObserved'] } else { 'NO' }))),
        @('ConfigBackupRecovery', ($versionScoped -and $runtime.ContainsKey('ConfigBackupRecoveryObserved') -and [string]$runtime['ConfigBackupRecoveryObserved'] -eq 'YES'), ('observed=' + $(if ($runtime.ContainsKey('ConfigBackupRecoveryObserved')) { [string]$runtime['ConfigBackupRecoveryObserved'] } else { 'NO' }))),
        @('OneHourSoak', ($versionScoped -and $runtime.ContainsKey('OneHourSoakObserved') -and [string]$runtime['OneHourSoakObserved'] -eq 'YES'), ('oneHour=' + $(if ($runtime.ContainsKey('OneHourSoakObserved')) { [string]$runtime['OneHourSoakObserved'] } else { 'NO' }) + '; seconds=' + $(if ($runtime.ContainsKey('LongestHelperSessionSeconds')) { [string]$runtime['LongestHelperSessionSeconds'] } else { '0' }))),
        @('NormalHelperShutdown', ($versionScoped -and $runtime.ContainsKey('NormalHelperShutdownEvidence') -and [string]$runtime['NormalHelperShutdownEvidence'] -eq 'YES'), ('observed=' + $(if ($runtime.ContainsKey('NormalHelperShutdownEvidence')) { [string]$runtime['NormalHelperShutdownEvidence'] } else { 'NOT-OBSERVED' })))
    )

    $result.Add('MortalShell2TTS release-readiness evidence index')
    $result.Add('EvidenceExpectedVersion=' + [string]$EvidenceVersion)
    $result.Add('EvidenceCurrentVersionOnly=' + $(if ($versionScoped) { 'YES' } else { 'NO' }))
    $result.Add('Meaning=OBSERVED means the bounded current-version support evidence contains the expected machine-checkable marker; it is not a substitute for human visual/audible/crash-attribution judgment.')
    foreach ($gate in $gates) {
        $totalCount++
        $name = [string]$gate[0]
        $ok = [bool]$gate[1]
        $detail = [string]$gate[2]
        if ($ok) { $observedCount++ } else { $pending.Add($name) }
        $result.Add(('Gate.' + $name + '=' + $(if ($ok) { 'OBSERVED' } else { 'PENDING' }) + '; ' + $detail))
    }
    $result.Add('AutomatedEvidenceCoverage=' + $observedCount + '/' + $totalCount)
    $result.Add('AutomatedEvidencePending=' + $(if ($pending.Count -gt 0) { $pending -join ',' } else { 'none' }))
    $result.Add('HumanRequired=audible queue ordering/interruption; duplicate-window edge timing and preview bypass; visual layout quality; physical controller/mouse behavior; optional Pause Game With Menu On/Off feel and balanced world resume; death/reload/save-load/area/main-menu transitions; crash attribution; clean-install save/restart persistence; representative historical in-game upgrades; Windows 10/11 target validation; live Azure valid/bad-key/wrong-region/offline/service/output cases; final 1-2+ hour gameplay judgment.')
    $result.Add('ReleaseDecision=Do not infer 1.0 readiness from this file alone. Use RELEASE_CANDIDATE_TEST_GUIDE.txt and human review for the remaining gates.')
    return ($result -join "`r`n")
}

try {
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('MortalShell2TTS share-safe support bundle')
    $summary.Add('CollectorVersion=' + $ExpectedVersion)
    $summary.Add('Created=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    try { $summary.Add('Windows=' + [string][Environment]::OSVersion.Version) } catch {}
    try { $summary.Add('PowerShell=' + [string]$PSVersionTable.PSVersion) } catch {}
    try { $summary.Add('PSEdition=' + [string]$PSVersionTable.PSEdition) } catch {}
    try { $summary.Add('LanguageMode=' + [string]$ExecutionContext.SessionState.LanguageMode) } catch {}
    try { $summary.Add('CLR=' + [string][Environment]::Version) } catch {}
    try { $summary.Add('OS64=' + [string][Environment]::Is64BitOperatingSystem) } catch {}
    try { $summary.Add('Process64=' + [string][Environment]::Is64BitProcess) } catch {}
    $summary.Add('')
    $summary.Add('This bundle intentionally excludes Azure keys/DPAPI blobs, raw TTSConfig.ini,')
    $summary.Add('tts_command.txt, tts_sequence.txt, tts_helper_heartbeat.txt, narrated text, voice catalogs, crash dumps, and arbitrary files.')
    $summary.Add('Voice/audio-output names and timestamps may appear because they are useful diagnostics.')
    $summary.Add('User-profile paths and bare local Windows user/computer/domain identities are sanitized.')
    Write-SafeFile 'support_summary.txt' ($summary -join "`r`n")

    Write-SafeFile 'config_summary.txt' (Get-AllowListedConfigSummary)
    Write-SafeFile 'release_integrity.txt' (Get-ReleaseIntegritySummary)

    if (Test-Path -LiteralPath $EngineStatusPath) {
        try { Write-SafeFile 'tts_engine_status.txt' (Read-SharedText $EngineStatusPath 131072) } catch {}
    }

    foreach ($suffix in @('', '.1', '.2')) {
        $source = Join-Path $ModRoot ('tts_helper.log' + $suffix)
        if (Test-Path -LiteralPath $source) {
            try {
                # Older development logs can predate rotation and be very large.
                # Read only a bounded tail instead of loading the complete file.
                $content = Read-SharedTailText $source 4194304
                Write-SafeFile ('tts_helper.log' + $suffix) $content
            } catch {}
        }
    }

    # Build evidence in chronological generation order (oldest retained -> newest)
    # from the same bounded helper logs already eligible for the support bundle.
    $helperEvidenceBuilder = New-Object Text.StringBuilder
    $rotationFilesPresent = 0
    foreach ($suffix in @('.2', '.1', '')) {
        $source = Join-Path $ModRoot ('tts_helper.log' + $suffix)
        if (Test-Path -LiteralPath $source) {
            try {
                if ($suffix -ne '') { $rotationFilesPresent++ }
                $null = $helperEvidenceBuilder.AppendLine((Read-SharedTailText $source 4194304))
            } catch {}
        }
    }
    $helperEvidenceText = [string]$helperEvidenceBuilder.ToString()

    $ue4ssSummary = Get-UE4SSSummary
    Write-SafeFile 'ue4ss_mortalshell2tts_summary.log' $ue4ssSummary

    # Evidence reports are stricter than the raw share-safe summaries: scope them
    # to the final contiguous run of this exact version. If the newest marker is
    # older/newer or absent, return empty evidence instead of letting historical
    # sessions create a false RC PASS. The raw sanitized logs remain available for
    # diagnosis and clearly expose why current-version evidence was unavailable.
    $uiScopePattern = 'event=startup\.begin(?=.*\bversion=(?<version>[0-9]+(?:\.[0-9]+){2})(?:\s|$))'
    $helperScopePattern = 'helper session start version=(?<version>[0-9]+(?:\.[0-9]+){2})(?:\s|$)'
    $uiEvidenceScope = Get-CurrentVersionEvidenceScope $ue4ssSummary $uiScopePattern 'ui' $ExpectedVersion
    $helperEvidenceScope = Get-CurrentVersionEvidenceScope $helperEvidenceText $helperScopePattern 'helper' $ExpectedVersion

    $uiRuntimeSummary = Get-UIRuntimeHealthSummary ([string]$uiEvidenceScope.Text)
    $helperRuntimeSummary = Get-HelperRuntimeHealthSummary ([string]$helperEvidenceScope.Text) $rotationFilesPresent
    $runtimeEvidenceSummary = Get-RuntimeEvidenceSummary ([string]$uiEvidenceScope.Text) ([string]$helperEvidenceScope.Text) ([bool]$uiEvidenceScope.Scoped) ([bool]$helperEvidenceScope.Scoped) ([int]$uiEvidenceScope.MarkerCount) ([int]$helperEvidenceScope.MarkerCount) $ExpectedVersion
    Write-SafeFile 'ui_runtime_summary.txt' $uiRuntimeSummary
    Write-SafeFile 'helper_runtime_summary.txt' $helperRuntimeSummary
    Write-SafeFile 'runtime_evidence_summary.txt' $runtimeEvidenceSummary
    Write-SafeFile 'release_readiness_summary.txt' (Get-ReleaseReadinessSummary $runtimeEvidenceSummary $helperRuntimeSummary $uiRuntimeSummary $ExpectedVersion)

    $scopeSummary = New-Object System.Collections.Generic.List[string]
    $scopeSummary.Add('MortalShell2TTS current-version evidence scope')
    $scopeSummary.Add('ExpectedVersion=' + $ExpectedVersion)
    $scopeSummary.Add('UI=' + $(if ($uiEvidenceScope.Scoped) { 'CURRENT-VERSION' } else { 'UNSCOPED' }) + '; observedVersion=' + [string]$uiEvidenceScope.ObservedVersion + '; markers=' + [string]$uiEvidenceScope.MarkerCount + '; reason=' + [string]$uiEvidenceScope.Reason)
    $scopeSummary.Add('Helper=' + $(if ($helperEvidenceScope.Scoped) { 'CURRENT-VERSION' } else { 'UNSCOPED' }) + '; observedVersion=' + [string]$helperEvidenceScope.ObservedVersion + '; markers=' + [string]$helperEvidenceScope.MarkerCount + '; reason=' + [string]$helperEvidenceScope.Reason)
    $scopeSummary.Add('Rule=Runtime checklist evidence is never credited from an older candidate solely because its lines remain in UE4SS/helper log history.')
    Write-SafeFile 'evidence_scope_summary.txt' ($scopeSummary -join "`r`n")

    # If the release-candidate preflight has been run, include only the newest
    # report. The preflight is credential/narration blind and this copy is
    # sanitized again before staging.
    try {
        $preflightReport = @(Get-ChildItem -LiteralPath $ModRoot -Filter 'MortalShell2TTS_RC_Preflight_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        if ($preflightReport.Count -gt 0) {
            Write-SafeFile 'rc_preflight_report.txt' (Read-SharedText $preflightReport[0].FullName 2097152)
        }
    } catch {}

    # If the standalone compatibility checker has been run, include only the
    # newest report. The checker itself is intentionally credential/config/text
    # blind, and this copy is sanitized again before staging.
    try {
        $compatibilityReport = @(Get-ChildItem -LiteralPath $ModRoot -Filter 'MortalShell2TTS_Compatibility_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        if ($compatibilityReport.Count -gt 0) {
            Write-SafeFile 'compatibility_report.txt' (Read-SharedText $compatibilityReport[0].FullName 2097152)
        }
    } catch {}

    $readme = @'
This ZIP is generated by MortalShell2TTS/CollectSupportBundle.ps1.

It is designed for sharing in support reports. It does NOT intentionally include:
- Azure subscription keys or DPAPI key blobs
- raw TTSConfig.ini
- tts_command.txt / narration payloads
- tts_helper_heartbeat.txt / transient helper process health
- narrated lore text
- voice catalogs
- crash dumps
- arbitrary files from your game or Windows profile

It may include timestamps, selected voice/audio-output names, sanitized paths,
configuration values from a small allow-list, MortalShell2TTS-related UE4SS log lines, bounded UI/helper lifecycle summaries, and a compact runtime-evidence summary derived only from those already allow-listed logs.
Local Windows user/computer/domain identity tokens are sanitized and final-ZIP audited.
The collector sanitizes the copied logs again so older pre-sanitization helper logs are
not copied verbatim. release_integrity.txt verifies the immutable shipped files against the release manifest.
helper_runtime_summary.txt and runtime_evidence_summary.txt make queue/profile/settings/browser/lore-reader/config-provenance/transition-guard/stress/shutdown evidence easier to review without broadening the privacy boundary. release_readiness_summary.txt condenses those current-version machine-checkable observations into OBSERVED/PENDING gates while explicitly retaining the human/runtime release requirements. Atomic-heartbeat readiness and same-game helper-recovery evidence are derived only from already sanitized logs; the raw heartbeat file remains excluded.
If RunReleaseCandidatePreflight.ps1 was run, its newest sanitized summary is included as rc_preflight_report.txt.
If RunCompatibilityCheck.ps1 was run, its newest local-only report is included as compatibility_report.txt.
'@
    Write-SafeFile 'README_SUPPORT_BUNDLE.txt' $readme

    # Defense in depth: inspect the complete staged bundle before compression.
    # If a future logging change leaks a credential-shaped value, fail closed.
    Assert-NoSupportSecrets
    Write-SupportManifest
    Assert-NoSupportSecrets

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
        Compress-Archive -Path (Join-Path $WorkRoot '*') -DestinationPath $OutputPath -CompressionLevel Optimal
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($WorkRoot, $OutputPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    }

    # Audit the artifact users will actually upload, not only the pre-compression
    # staging directory. Fail closed and delete the ZIP if archive structure,
    # content bounds, private runtime filenames, or secret patterns are wrong.
    Assert-SafeSupportArchive $OutputPath
    Write-Host "Support bundle created (post-compression privacy audit PASS): $OutputPath"
} catch {
    try { if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue } } catch {}
    Write-Error ('Unable to create support bundle: ' + (ConvertTo-SafeSupportText $_.Exception.Message))
    exit 1
} finally {
    try { if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
}
