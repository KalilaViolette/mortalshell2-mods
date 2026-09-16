# MortalShell2TTS - local Windows speech helper
# v0.9.263: version pin only (no helper behavior change).
# v0.9.262: version pin only (no helper behavior change).
# v0.9.261: helper version pinned to the mod (the 0.9.261 performance-logging build shipped a 0.9.260 helper; every Settings open logged version-mismatch:0.9.260 and ran on the deferred-mismatch path). No helper behavior change.
# v0.9.260: Pass 183 changes only shared ModUI controller-consumer integration metadata; runtime speech behavior is unchanged.
# v0.9.255: Pass 178 adds shared MortalShell2ModUI controller settings/calibration/test; speech/helper behavior is unchanged.
# v0.9.166: Pass 89 added read-only native UI transition observation.
# v0.9.161: Pass 84 adds a persistent master pronunciation On/Off switch; Off bypasses normalization at both Azure and local synthesis boundaries while preserving all rules.
# Azure credentials are never written to TTSConfig.ini. The in-game clipboard importer stores
# the key as a Windows DPAPI CurrentUser blob under %LOCALAPPDATA%\MortalShell2TTS.

$ErrorActionPreference = 'Stop'
$CommandPath = Join-Path $PSScriptRoot 'tts_command.txt'
$SequencePath = Join-Path $PSScriptRoot 'tts_sequence.txt'
$LogPath = Join-Path $PSScriptRoot 'tts_helper.log'
$ConfigPath = Join-Path $PSScriptRoot 'TTSConfig.ini'
$VoiceListPath = Join-Path $PSScriptRoot 'tts_voices.txt'
$AudioOutputListPath = Join-Path $PSScriptRoot 'tts_outputs.txt'
$AzureVoiceListPath = Join-Path $PSScriptRoot 'tts_azure_voices.txt'
$EngineStatusPath = Join-Path $PSScriptRoot 'tts_engine_status.txt'
$HeartbeatPath = Join-Path $PSScriptRoot 'tts_helper_heartbeat.txt'
$AzureStreamScriptPath = Join-Path $PSScriptRoot 'AzureStream.ps1'
$PronunciationDefaultsPath = Join-Path $PSScriptRoot 'PronunciationCorrections.default.txt'
$AzureSecretRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MortalShell2TTS'
$PronunciationUserPath = Join-Path $AzureSecretRoot 'PronunciationCorrections.txt'
$AzureSecretPath = Join-Path $AzureSecretRoot 'AzureSpeechKey.dat'
$AzureSecretBackupPath = $AzureSecretPath + '.bak'
$AzurePlayerAssembly = Join-Path $AzureSecretRoot 'AzureWaveOutPlayer.v1.dll'
$AzureEntropyText = 'MortalShell2TTS.AzureSpeech.v1'
$GameProcessNames = @('MortalShell2-Win64-Shipping', 'MortalShell2_Win64_Shipping')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LogMaxBytes = 2MB
$LogGenerations = 2
$SupportSchema = 11
$HelperVersion = '0.9.263'
$HeartbeatIntervalMs = 2000
$HelperIdlePollIntervalMs = 125
$HelperActivePollIntervalMs = 50
$GameLivenessIntervalMs = 1000
$SequenceFallbackReadIntervalMs = 500
$script:HeartbeatState = 'not-initialized'
$script:HeartbeatLastWriteUtc = [DateTime]::MinValue
$script:HeartbeatFailureLogged = $false
$script:HeartbeatTempPath = $HeartbeatPath + '.tmp.' + [string]$PID
$LogMaxEntryChars = 4096
$SpeechTextLimitChars = 65536
$VoicePreviewText = 'Mortal Shell Two text to speech preview. The darkness remembers every name.'
$PronunciationFileMaxBytes = 131072
$PronunciationRuleMaxEntries = 512
$PronunciationMatchMaxChars = 256
$PronunciationSpokenMaxChars = 512
$script:PronunciationRules = @()
$script:PronunciationMatchers = @{ azure = $null; local = $null }
$script:PronunciationRulesStamp = ''
$script:PronunciationRulesState = 'not-loaded'
$script:PronunciationDefaultRuleCount = 0
$script:PronunciationUserRuleCount = 0
$script:PronunciationDisabledDefaultCount = 0
$script:PronunciationInvalidLineCount = 0
$AzureVoiceResponseMaxBytes = 16MB
$VoiceCatalogMaxBytes = 8MB
$VoiceCatalogMaxEntries = 4096
$AudioOutputCatalogMaxBytes = 2MB
$AudioOutputCatalogMaxEntries = 1024
$script:SessionStartUtc = [DateTime]::UtcNow
$script:SessionStats = @{
    Commands = 0
    SpeakRequests = 0
    TestRequests = 0
    PreviewRequests = 0
    StopCommands = 0
    ConfigCommands = 0
    LocalStarts = 0
    AzureStarts = 0
    QueueEnqueued = 0
    QueueAdvanced = 0
    QueueDropped = 0
    IgnoreDropped = 0
    AzureChildFailures = 0
    CommandReadErrors = 0
    SapiFallbacks = 0
    AudioFallbacks = 0
    PronunciationLoads = 0
    PronunciationApplied = 0
    PronunciationReplacements = 0
    PronunciationErrors = 0
}

function Add-SessionStat([string]$Name, [int]$Delta = 1) {
    try {
        if ($script:SessionStats.ContainsKey($Name)) {
            $script:SessionStats[$Name] = [int]$script:SessionStats[$Name] + $Delta
        }
    } catch {}
}
$CommandIpcMaxBytes = 512KB
$SequenceIpcMaxBytes = 4096
$LogMutexName = 'Local\MortalShell2TTS_Log_v1'
$script:LogMutex = $null
$script:SharedLogMutexState = 'not-initialized'
$script:ConfigSource = 'defaults'
$script:WindowsSupportTarget = 'unknown'

function ConvertTo-SafeLogText([string]$Message) {
    if ($null -eq $Message) { return '' }
    $safe = [string]$Message
    try {
        $replacements = @(
            @([string]$PSScriptRoot, '<MOD_DIR>'),
            @([string]$AzureSecretRoot, '<TTS_DATA>'),
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
        # Also redact a different/local account name if an exception happens to
        # mention another profile path rather than the current process profile.
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)\b[A-Z]:\\Users\\[^\\\r\n]+', '%USERPROFILE%')

        # Paths are the most common identity leak, but exception text can also
        # contain a bare Windows user/computer/domain name. Redact those exact
        # environment identities too. Skip very short values to avoid destroying
        # ordinary diagnostic words on unusual local accounts.
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
    } catch {}

    # Defense in depth: no exception/request diagnostic should ever publish an
    # authentication header or a plausible Azure Speech subscription key.
    try {
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Ocp-Apim-Subscription-Key\s*[:=]\s*)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Authorization\s*[:=]\s*Bearer\s+)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)((?:MORTALSHELL2TTS_AZURE_KEY|AZURE_SPEECH_KEY)\s*[:=]\s*)[^\s;,]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Azure(?:Speech)?Key\s*[:=]\s*)(?!missing\b|present\b|dpapi\b|environment\b)[A-Za-z0-9+/=_-]{24,}', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)([?&](?:sig|key|token|code)=)[^&\s]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(DPAPI(?:Blob)?\s*[:=]\s*)[A-Za-z0-9+/=_-]{24,}', '$1<REDACTED>')
        # A speech engine exception should never make the spoken payload public.
        # These are defense-in-depth redactions in addition to avoiding raw speech
        # exception messages at the call sites below.
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?is)<speak\b.*?</speak>', '<SSML_REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?is)<pitch\b.*?</pitch>', '<SAPI_XML_REDACTED>')
    } catch {}
    $safe = ($safe -replace '[\r\n]+', ' ')
    if ($safe.Length -gt $LogMaxEntryChars) { $safe = $safe.Substring(0, $LogMaxEntryChars) + '...[truncated]' }
    return $safe
}

function Get-ExceptionSignature($Exception) {
    if ($null -eq $Exception) { return 'type=Unknown hresult=unknown' }
    $typeName = 'Exception'
    $hresult = 'unknown'
    try { $typeName = [string]$Exception.GetType().FullName } catch {}
    try { $hresult = ('0x{0:X8}' -f ([uint32]$Exception.HResult)) } catch {}
    return ('type=' + $typeName + ' hresult=' + $hresult)
}

function Get-SharedLogMutex {
    if ($null -ne $script:LogMutex) { return $script:LogMutex }
    try {
        $script:LogMutex = New-Object System.Threading.Mutex($false, $LogMutexName)
        $script:SharedLogMutexState = 'ready'
    } catch {
        $script:LogMutex = $null
        $script:SharedLogMutexState = 'unavailable'
    }
    return $script:LogMutex
}

function Invoke-WithSharedLogMutex([scriptblock]$Action) {
    $mutex = Get-SharedLogMutex
    $acquired = $false
    try {
        if ($null -ne $mutex) {
            try { $acquired = $mutex.WaitOne(2000) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            catch { $acquired = $false }
            if ($acquired) { $script:SharedLogMutexState = 'ready' } else { $script:SharedLogMutexState = 'contention-timeout' }
            # A lost diagnostic line is safer than racing AzureStream while that
            # process owns the append/rotation boundary. If named mutex creation is
            # blocked entirely, $mutex is null and logging remains fail-soft below.
            if (-not $acquired) { return $false }
        }
        & $Action
        return $true
    } finally {
        if ($acquired -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
    }
}

function Rotate-HelperLogIfNeeded([int64]$IncomingBytes = 0) {
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    $length = [IO.FileInfo]::new($LogPath).Length
    if (($length + [Math]::Max([int64]0, $IncomingBytes)) -lt $LogMaxBytes) { return }
    for ($index = $LogGenerations; $index -ge 1; $index--) {
        $source = if ($index -eq 1) { $LogPath } else { "$LogPath.$($index - 1)" }
        $destination = "$LogPath.$index"
        if (Test-Path -LiteralPath $source) {
            try { Move-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop } catch {}
        }
    }
}

function Initialize-HelperLog {
    try { [void](Invoke-WithSharedLogMutex { Rotate-HelperLogIfNeeded 0 }) } catch {}
}

function Write-HelperLog([string]$Message) {
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $safe = ConvertTo-SafeLogText $Message
        $line = "[$stamp] $safe`r`n"
        $lineBytes = [Text.Encoding]::UTF8.GetByteCount($line)
        [void](Invoke-WithSharedLogMutex {
            Rotate-HelperLogIfNeeded $lineBytes
            [IO.File]::AppendAllText($LogPath, $line, [Text.Encoding]::UTF8)
        })
    } catch {
    }
}

function Write-HelperHeartbeat([switch]$Force) {
    $now = [DateTime]::UtcNow
    if (-not $Force -and $script:HeartbeatLastWriteUtc -ne [DateTime]::MinValue) {
        if (($now - $script:HeartbeatLastWriteUtc).TotalMilliseconds -lt $HeartbeatIntervalMs) { return $true }
    }

    $tempPath = [string]$script:HeartbeatTempPath
    try {
        $epoch = [int64][Math]::Floor(($now - [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)).TotalSeconds)
        $ownerGamePid = 0
        try { if ($null -ne $gameProcessId) { $ownerGamePid = [int]$gameProcessId } } catch { $ownerGamePid = 0 }
        $ownerMode = 'fallback-name'
        try { if (-not [string]::IsNullOrWhiteSpace([string]$bindingMode)) { $ownerMode = [string]$bindingMode } } catch {}
        $payload = 'version=' + $HelperVersion + ';pid=' + [string]$PID + ';startFileTimeUtc=' + [string]$helperStartFileTimeUtc + ';gamePid=' + [string]$ownerGamePid + ';bindingMode=' + $ownerMode + ';epoch=' + [string]$epoch

        # Publish the heartbeat as a complete snapshot. A direct WriteAllText to the
        # live file can briefly expose an empty/partial payload to Lua, which could
        # be mistaken for a dead helper and trigger an unnecessary recovery launch.
        # Use a per-helper temporary file, verify its bytes, then atomically replace
        # the live snapshot where Windows permits it. Move-Item is a bounded fallback
        # for filesystems/security products that reject File.Replace metadata work.
        [IO.File]::WriteAllText($tempPath, $payload, $Utf8NoBom)
        $staged = [IO.File]::ReadAllText($tempPath, [Text.Encoding]::UTF8)
        if ($staged -ne $payload) { throw 'staged helper heartbeat readback did not match.' }

        $published = $false
        if (Test-Path -LiteralPath $HeartbeatPath -PathType Leaf) {
            try {
                [IO.File]::Replace($tempPath, $HeartbeatPath, $null, $true)
                $published = $true
            } catch {
                try {
                    Move-Item -LiteralPath $tempPath -Destination $HeartbeatPath -Force -ErrorAction Stop
                    $published = $true
                } catch {}
            }
        } else {
            try {
                Move-Item -LiteralPath $tempPath -Destination $HeartbeatPath -Force -ErrorAction Stop
                $published = $true
            } catch {}
        }
        if (-not $published) { throw 'helper heartbeat snapshot could not be published.' }

        $live = [IO.File]::ReadAllText($HeartbeatPath, [Text.Encoding]::UTF8)
        if ($live -ne $payload) { throw 'published helper heartbeat readback did not match.' }

        $script:HeartbeatLastWriteUtc = $now
        $script:HeartbeatState = 'ready'
        $script:HeartbeatFailureLogged = $false
        return $true
    } catch {
        try { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } } catch {}
        $script:HeartbeatState = 'write-failed'
        if (-not $script:HeartbeatFailureLogged) {
            $script:HeartbeatFailureLogged = $true
            Write-HelperLog ('helper heartbeat write failed; self-recovery detection may be reduced; ' + (Get-ExceptionSignature $_.Exception))
        }
        return $false
    }
}

function Remove-OwnHelperHeartbeat {
    $removed = $true
    try {
        if (Test-Path -LiteralPath $HeartbeatPath -PathType Leaf) {
            $content = [IO.File]::ReadAllText($HeartbeatPath, [Text.Encoding]::UTF8)
            $pidMatch = $content -match ('(?:^|;)pid=' + [Regex]::Escape([string]$PID) + '(?:;|$)')
            $startMatch = $content -match ('(?:^|;)startFileTimeUtc=' + [Regex]::Escape([string]$helperStartFileTimeUtc) + '(?:;|$)')
            if ($pidMatch -and $startMatch) {
                Remove-Item -LiteralPath $HeartbeatPath -Force -ErrorAction Stop
                $removed = (-not (Test-Path -LiteralPath $HeartbeatPath -PathType Leaf))
            } else {
                $removed = $false
            }
        }
    } catch {
        $removed = $false
    }
    try { if (Test-Path -LiteralPath $script:HeartbeatTempPath) { Remove-Item -LiteralPath $script:HeartbeatTempPath -Force -ErrorAction SilentlyContinue } } catch {}
    return $removed
}

function Limit-SpeechText([string]$Text, [string]$Context) {
    if ($null -eq $Text) { return '' }
    $value = [string]$Text
    if ($value.Length -le $SpeechTextLimitChars) { return $value }
    $contextName = if ([string]::IsNullOrWhiteSpace($Context)) { 'speech request' } else { [string]$Context }
    Write-HelperLog "$contextName exceeded speech text safety limit originalChars=$($value.Length) limit=$SpeechTextLimitChars; truncating"
    return $value.Substring(0, $SpeechTextLimitChars)
}


function Ensure-PronunciationUserFile {
    $template = @(
        '# MortalShell2TTS user pronunciation overrides',
        '#',
        '# IMPORTANT: this file intentionally starts with NO active user entries.',
        '# The built-in active corrections are shipped separately in:',
        '#   <mod folder>\PronunciationCorrections.default.txt',
        '# You do not need to copy those defaults here; this file only overrides them.',
        '#',
        '# Format: match | spoken-as | scope [| unsupported-voice-fallback]',
        '# TAB-separated columns are also accepted.',
        '# Scope: azure | local | all',
        '# Matching is case-insensitive and whole-word/whole-phrase.',
        '# Azure IPA rules can use: ipa:<phones> with scope azure.',
        '# Optional field 4 is used only when the selected Azure voice does not support phoneme SSML.',
        '# Prefixing field 4 with fallback: is recommended for readability.',
        '# Plain spoken-as aliases still work for every voice.',
        '# User entries replace the shipped default for the same match.',
        '# To disable a shipped default without replacing it:',
        '#   match | !disable | azure',
        '#',
        '# Examples (remove the leading #):',
        '# example | ipa:<IPA phones> | azure | fallback:spoken approximation',
        '# simple-name | spoken alias | azure',
        '#',
        '# This file is persistent under %LOCALAPPDATA%\MortalShell2TTS and is not',
        '# overwritten by clean mod-folder updates.'
    ) -join "`r`n"

    if (Test-Path -LiteralPath $PronunciationUserPath -PathType Leaf) {
        # Upgrade ONLY untouched generated templates. Any user edit, including
        # comments, prevents rewriting so custom pronunciation work is preserved.
        try {
            $legacyTemplate = @(
                '# MortalShell2TTS user pronunciation overrides',
                '#',
                '# Format: match | spoken-as | scope   (TAB-separated lines are also accepted)',
                '# Scope: azure | local | all',
                '# Matching is case-insensitive and whole-word/whole-phrase.',
                '# User entries replace the shipped default for the same match.',
                '# To disable a shipped default without replacing it:',
                '#   match | !disable | azure',
                '#',
                '# Examples (remove the leading #):',
                '# bosom | buz-um | azure',
                '# Harbinger | har-bin-jer | azure',
                '#',
                '# This file is persistent under %LOCALAPPDATA%\MortalShell2TTS and is not',
                '# overwritten by clean mod-folder updates.'
            ) -join "`r`n"

            $previousTemplate = @(
                '# MortalShell2TTS user pronunciation overrides',
                '#',
                '# IMPORTANT: this file intentionally starts with NO active user entries.',
                '# The built-in active corrections are shipped separately in:',
                '#   <mod folder>\PronunciationCorrections.default.txt',
                '# You do not need to copy those defaults here; this file only overrides them.',
                '#',
                '# Format: match | spoken-as | scope   (TAB-separated lines are also accepted)',
                '# Scope: azure | local | all',
                '# Matching is case-insensitive and whole-word/whole-phrase.',
                '# User entries replace the shipped default for the same match.',
                '# To disable a shipped default without replacing it:',
                '#   match | !disable | azure',
                '#',
                '# Examples (remove the leading #):',
                '# bosom | buz-um | azure',
                '# Harbinger | har-bin-jer | azure',
                '#',
                '# This file is persistent under %LOCALAPPDATA%\MortalShell2TTS and is not',
                '# overwritten by clean mod-folder updates.'
            ) -join "`r`n"

            $pass79Template = @(
                '# MortalShell2TTS user pronunciation overrides',
                '#',
                '# IMPORTANT: this file intentionally starts with NO active user entries.',
                '# The built-in active corrections are shipped separately in:',
                '#   <mod folder>\PronunciationCorrections.default.txt',
                '# You do not need to copy those defaults here; this file only overrides them.',
                '#',
                '# Format: match | spoken-as | scope   (TAB-separated lines are also accepted)',
                '# Scope: azure | local | all',
                '# Matching is case-insensitive and whole-word/whole-phrase.',
                '# For Azure MAI, prefer one-token aliases; hyphenated pseudo-syllables may over-stress.',
                '# User entries replace the shipped default for the same match.',
                '# To disable a shipped default without replacing it:',
                '#   match | !disable | azure',
                '#',
                '# Examples (remove the leading #):',
                '# bosom | buzzum | azure',
                '# Harbinger | harbinjer | azure',
                '#',
                '# This file is persistent under %LOCALAPPDATA%\MortalShell2TTS and is not',
                '# overwritten by clean mod-folder updates.'
            ) -join "`r`n"

            $pass81Template = @(
                '# MortalShell2TTS user pronunciation overrides',
                '#',
                '# IMPORTANT: this file intentionally starts with NO active user entries.',
                '# The built-in active corrections are shipped separately in:',
                '#   <mod folder>\PronunciationCorrections.default.txt',
                '# You do not need to copy those defaults here; this file only overrides them.',
                '#',
                '# Format: match | spoken-as | scope   (TAB-separated lines are also accepted)',
                '# Scope: azure | local | all',
                '# Matching is case-insensitive and whole-word/whole-phrase.',
                '# Azure supports exact IPA phonemes: use ipa:<phones> with scope azure.',
                '# See PronunciationCorrections.default.txt for shipped IPA examples.',
                '# Plain spoken-as aliases still work, especially for simple compounds.',
                '# User entries replace the shipped default for the same match.',
                '# To disable a shipped default without replacing it:',
                '#   match | !disable | azure',
                '#',
                '# Examples (remove the leading #):',
                '# example | ipa:<IPA phones> | azure',
                '# simple-name | spoken alias | azure',
                '#',
                '# This file is persistent under %LOCALAPPDATA%\MortalShell2TTS and is not',
                '# overwritten by clean mod-folder updates.'
            ) -join "`r`n"

            $existingItem = Get-Item -LiteralPath $PronunciationUserPath -ErrorAction Stop
            if ([int64]$existingItem.Length -le [int64]$PronunciationFileMaxBytes) {
                $existingText = [IO.File]::ReadAllText($PronunciationUserPath, [Text.Encoding]::UTF8)
                if ($existingText -eq ($legacyTemplate + "`r`n") -or
                    $existingText -eq ($previousTemplate + "`r`n") -or
                    $existingText -eq ($pass79Template + "`r`n") -or
                    $existingText -eq ($pass81Template + "`r`n")) {
                    [IO.File]::WriteAllText($PronunciationUserPath, ($template + "`r`n"), $Utf8NoBom)
                    Write-HelperLog 'pronunciation user override template comments upgraded to Pass 83 voice-capability fallback guidance; active user rules remain zero'
                }
            }
        } catch {
            Write-HelperLog ('pronunciation user override template upgrade skipped; ' + (Get-ExceptionSignature $_.Exception))
        }
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $AzureSecretRoot)) {
            [IO.Directory]::CreateDirectory($AzureSecretRoot) | Out-Null
        }
        [IO.File]::WriteAllText($PronunciationUserPath, ($template + "`r`n"), $Utf8NoBom)
        return $true
    } catch {
        Add-SessionStat 'PronunciationErrors'
        Write-HelperLog ('pronunciation user override template could not be created; ' + (Get-ExceptionSignature $_.Exception))
        return $false
    }
}

function Get-PronunciationRulesStamp {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($PronunciationDefaultsPath, $PronunciationUserPath)) {
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                $parts.Add(([string]$item.LastWriteTimeUtc.Ticks + ':' + [string]$item.Length))
            } else {
                $parts.Add('missing')
            }
        } catch {
            $parts.Add('unreadable')
        }
    }
    return ($parts -join '|')
}

function Read-PronunciationRuleFile([string]$Path, [string]$SourceKind) {
    $results = New-Object System.Collections.Generic.List[object]
    # Windows PowerShell 5.1 can throw System.ArgumentException ('Argument types do not match')
    # when @() wraps a List[object] created by New-Object. Convert explicitly instead.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $results.ToArray() }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([int64]$item.Length -gt [int64]$PronunciationFileMaxBytes) {
        throw "pronunciation $SourceKind file exceeded safety limit bytes=$($item.Length) limit=$PronunciationFileMaxBytes"
    }

    $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    $lineNumber = 0
    foreach ($rawLine in $lines) {
        $lineNumber++
        $line = [string]$rawLine
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }

        if ($line.Contains("`t")) {
            $parts = @($line -split "`t", 4)
        } else {
            $parts = @($line -split '\|', 4)
        }
        if ($parts.Count -lt 2) {
            $script:PronunciationInvalidLineCount++
            continue
        }

        $match = ([string]$parts[0]).Replace("`0", '').Trim()
        $spoken = ([string]$parts[1]).Replace("`0", '').Trim()
        $scope = if ($parts.Count -ge 3) { ([string]$parts[2]).Replace("`0", '').Trim().ToLowerInvariant() } else { 'all' }
        $fallback = if ($parts.Count -ge 4) { ([string]$parts[3]).Replace("`0", '').Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($scope)) { $scope = 'all' }
        if (-not [string]::IsNullOrWhiteSpace($fallback) -and $fallback.StartsWith('fallback:', [StringComparison]::OrdinalIgnoreCase)) {
            $fallback = $fallback.Substring(9).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($match) -or [string]::IsNullOrWhiteSpace($spoken) -or
            $match.Length -gt $PronunciationMatchMaxChars -or $spoken.Length -gt $PronunciationSpokenMaxChars -or
            $fallback.Length -gt $PronunciationSpokenMaxChars -or
            ($scope -ne 'all' -and $scope -ne 'azure' -and $scope -ne 'local')) {
            $script:PronunciationInvalidLineCount++
            continue
        }

        $kind = 'alias'
        $value = $spoken
        if ($spoken.StartsWith('ipa:', [StringComparison]::OrdinalIgnoreCase)) {
            # IPA is an Azure SSML pronunciation primitive, not plain text. Keep it
            # out of Windows local/all rules so a local engine can never read the
            # literal "ipa:..." payload aloud.
            if ($scope -ne 'azure') {
                $script:PronunciationInvalidLineCount++
                continue
            }
            $kind = 'ipa'
            $value = $spoken.Substring(4).Trim()
            if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt $PronunciationSpokenMaxChars) {
                $script:PronunciationInvalidLineCount++
                continue
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($fallback)) {
            # Field four is meaningful only for IPA rules. Reject accidental extra
            # data on plain aliases rather than silently creating ambiguous behavior.
            $script:PronunciationInvalidLineCount++
            continue
        }

        $results.Add([PSCustomObject]@{
            Match = $match
            MatchKey = $match.ToLowerInvariant()
            Spoken = $spoken
            Kind = $kind
            Value = $value
            FallbackValue = $fallback
            Scope = $scope
            SourceKind = $SourceKind
            LineNumber = $lineNumber
        })
        if ($results.Count -gt $PronunciationRuleMaxEntries) {
            throw "pronunciation $SourceKind file exceeded rule limit entries>$PronunciationRuleMaxEntries"
        }
    }
    return $results.ToArray()
}

function Test-PronunciationWordChar([char]$Character) {
    # Equivalent to the original [\p{L}\p{N}_] boundary intent without compiling
    # a dynamically generated regex. Char.IsLetter/IsNumber are Unicode-aware.
    return ([char]::IsLetter($Character) -or [char]::IsNumber($Character) -or ([int]$Character -eq 95))
}

function Test-PronunciationWholeBoundary([string]$Text, [int]$Start, [int]$Length) {
    if ($null -eq $Text -or $Start -lt 0 -or $Length -le 0 -or ($Start + $Length) -gt $Text.Length) {
        return $false
    }

    if ($Start -gt 0) {
        $before = [char]$Text[$Start - 1]
        if (Test-PronunciationWordChar $before) { return $false }
    }

    $end = $Start + $Length
    if ($end -lt $Text.Length) {
        $after = [char]$Text[$end]
        if (Test-PronunciationWordChar $after) { return $false }
    }

    return $true
}

function New-PronunciationMatcher([object[]]$Rules, [string]$TargetScope) {
    $scopeName = ([string]$TargetScope).Trim().ToLowerInvariant()
    if ($scopeName -ne 'azure' -and $scopeName -ne 'local') { return $null }

    $eligible = @($Rules | Where-Object { ([string]$_.Scope -eq 'all') -or ([string]$_.Scope -eq $scopeName) })
    if ($eligible.Count -eq 0) { return $null }

    # Pass 76 built one dynamic Regex from all correction text. That failed to
    # initialize under the user's Windows PowerShell 5.1/.NET runtime with a
    # System.ArgumentException, leaving pronunciationRules=0. Keep the same
    # one-pass/longest-first semantics without a generated regex: the matcher is
    # now just the immutable scoped rule set and Apply-PronunciationCorrections
    # finds original-source spans with String.IndexOf(OrdinalIgnoreCase).
    return [PSCustomObject]@{
        Rules = @($eligible)
        RuleCount = $eligible.Count
        Strategy = 'ordinal-scan'
    }
}

function Get-PronunciationRules {
    $null = Ensure-PronunciationUserFile
    $stamp = Get-PronunciationRulesStamp
    if ($stamp -eq $script:PronunciationRulesStamp -and $script:PronunciationRulesState -eq 'ready') {
        return @($script:PronunciationRules)
    }

    $previous = @($script:PronunciationRules)
    $loadStage = 'start'
    try {
        $script:PronunciationInvalidLineCount = 0

        $loadStage = 'read-defaults'
        $defaults = @(Read-PronunciationRuleFile $PronunciationDefaultsPath 'default')

        $loadStage = 'read-user'
        $users = @(Read-PronunciationRuleFile $PronunciationUserPath 'user')

        $loadStage = 'merge'
        $effective = New-Object System.Collections.Generic.List[object]
        foreach ($rule in $defaults) {
            $effective.Add($rule)
        }

        $disabled = 0
        foreach ($rule in $users) {
            # A user rule owns the match completely, regardless of the default scope.
            for ($index = $effective.Count - 1; $index -ge 0; $index--) {
                if ([string]$effective[$index].MatchKey -eq [string]$rule.MatchKey) {
                    $effective.RemoveAt($index)
                    $disabled++
                }
            }
            if ([string]$rule.Spoken -ieq '!disable') { continue }
            $effective.Add($rule)
        }

        $loadStage = 'sort'
        $compiled = @($effective | Sort-Object -Property @{Expression={ [int]$_.Match.Length }; Descending=$true}, @{Expression={ [string]$_.MatchKey }; Ascending=$true})

        $loadStage = 'build-azure-matcher'
        $azureMatcher = New-PronunciationMatcher $compiled 'azure'

        $loadStage = 'build-local-matcher'
        $localMatcher = New-PronunciationMatcher $compiled 'local'

        $loadStage = 'commit'
        $script:PronunciationRules = $compiled
        $script:PronunciationMatchers = @{ azure = $azureMatcher; local = $localMatcher }
        $script:PronunciationRulesStamp = $stamp
        $script:PronunciationRulesState = 'ready'
        $script:PronunciationDefaultRuleCount = $defaults.Count
        $script:PronunciationUserRuleCount = $users.Count
        $script:PronunciationDisabledDefaultCount = $disabled
        Add-SessionStat 'PronunciationLoads'
        Write-HelperLog "pronunciation corrections loaded strategy=ordinal-scan effective=$($script:PronunciationRules.Count) defaults=$($defaults.Count) userEntries=$($users.Count) overriddenOrDisabled=$disabled invalidLines=$($script:PronunciationInvalidLineCount)"
        return @($script:PronunciationRules)
    } catch {
        Add-SessionStat 'PronunciationErrors'
        $script:PronunciationRulesState = if ($previous.Count -gt 0) { 'stale-after-error' } else { 'unavailable' }
        $message = ''
        try { $message = [string]$_.Exception.Message } catch {}
        Write-HelperLog ('pronunciation corrections reload failed stage=' + $loadStage + '; keeping previous rules=' + $previous.Count + '; ' + (Get-ExceptionSignature $_.Exception) + '; message=' + $message)
        return $previous
    }
}

function Get-AzurePronunciationCapability([string]$VoiceName) {
    $voice = ([string]$VoiceName).Trim()
    if ([string]::IsNullOrWhiteSpace($voice)) {
        return [PSCustomObject]@{ Phoneme = $false; Reason = 'voice-missing' }
    }

    $lower = $voice.ToLowerInvariant()

    # MAI currently accepts the surrounding SSML document but Harper MAI-Voice-2
    # has been runtime-proven to ignore inline <phoneme>. Treat the entire MAI
    # family conservatively so those voices use each rule's spelling fallback.
    if ($lower.Contains(':mai-voice-')) {
        return [PSCustomObject]@{ Phoneme = $false; Reason = 'mai-family' }
    }

    # Microsoft documents Dragon HD Omni as not supporting <phoneme>.
    if ($lower.Contains('dragonhdomni')) {
        return [PSCustomObject]@{ Phoneme = $false; Reason = 'dragon-hd-omni' }
    }

    # Microsoft language-support footnote 3 marks these locales as not supporting
    # phonemes/custom lexicon/visemes. Keep this list conservative; a false
    # negative only selects the harmless spelling fallback.
    $locale = ''
    $voiceParts = @($voice.Split('-'))
    if ($voiceParts.Count -ge 2) {
        $locale = ($voiceParts[0] + '-' + $voiceParts[1]).ToLowerInvariant()
        if ($voiceParts.Count -ge 3 -and ($voiceParts[1].Length -gt 3 -or $voiceParts[2].Length -le 4)) {
            # Script/variant locales such as iu-Cans-CA and sr-Latn-RS need more
            # than the ordinary language-region pair to identify the documented row.
            $candidate3 = ($voiceParts[0] + '-' + $voiceParts[1] + '-' + $voiceParts[2]).ToLowerInvariant()
            if ($candidate3 -match '^(iu-(cans|latn)-ca|sr-latn-rs|zh-cn-(henan|liaoning|shaanxi|shandong|sichuan))$') {
                $locale = $candidate3
            }
        }
    }
    if ($lower.StartsWith('zh-cn-henan-')) { $locale = 'zh-cn-henan' }
    elseif ($lower.StartsWith('zh-cn-liaoning-')) { $locale = 'zh-cn-liaoning' }
    elseif ($lower.StartsWith('zh-cn-shaanxi-')) { $locale = 'zh-cn-shaanxi' }
    elseif ($lower.StartsWith('zh-cn-shandong-')) { $locale = 'zh-cn-shandong' }
    elseif ($lower.StartsWith('zh-cn-sichuan-')) { $locale = 'zh-cn-sichuan' }

    $noPhonemeLocales = @(
        'as-in','az-az','bn-bd','bn-in','bs-ba','cy-gb','et-ee','eu-es','fa-ir',
        'fil-ph','ga-ie','gl-es','hy-am','is-is','iu-cans-ca','iu-latn-ca','jv-id',
        'ka-ge','kk-kz','km-kh','kn-in','lo-la','lt-lt','lv-lv','mk-mk','ml-in',
        'mn-mn','mt-mt','my-mm','ne-np','or-in','pa-in','ps-af','si-lk','so-so',
        'sq-al','sr-latn-rs','sr-rs','su-id','sw-ke','wuu-cn','yue-cn',
        'zh-cn-henan','zh-cn-liaoning','zh-cn-shaanxi','zh-cn-shandong',
        'zh-cn-sichuan','zu-za'
    )
    if ($noPhonemeLocales -contains $locale) {
        return [PSCustomObject]@{ Phoneme = $false; Reason = ('locale-no-phoneme:' + $locale) }
    }

    # Microsoft explicitly documents <phoneme> for DragonHD (non-Omni).
    if ($lower.Contains(':dragonhd')) {
        return [PSCustomObject]@{ Phoneme = $true; Reason = 'dragon-hd' }
    }

    # Turbo multilingual voices are documented as supporting the full SSML set.
    if ($lower.Contains('turbomultilingualneural')) {
        return [PSCustomObject]@{ Phoneme = $true; Reason = 'turbo-multilingual-neural' }
    }

    # Ordinary Azure Speech neural voices use the standard SSML feature set. The
    # documented no-phoneme locales above were excluded first.
    if ($lower.EndsWith('neural')) {
        return [PSCustomObject]@{ Phoneme = $true; Reason = 'standard-neural' }
    }

    # Unknown/custom/future families fail safe to the spelling fallback. This is
    # intentionally conservative because an unsupported <phoneme> can be silently
    # ignored while a plain alias remains audible.
    return [PSCustomObject]@{ Phoneme = $false; Reason = 'unknown-family' }
}

function Apply-PronunciationCorrections([string]$Text, [string]$Scope, [string]$Context, [object]$AzurePhonemesRef, [string]$AzureVoiceName) {
    if ($null -eq $Text) { return '' }
    $result = [string]$Text
    if ([string]::IsNullOrWhiteSpace($result)) { return $result }

    $targetScope = ([string]$Scope).Trim().ToLowerInvariant()
    if ($targetScope -ne 'azure' -and $targetScope -ne 'local') { $targetScope = 'all' }

    $rules = @(Get-PronunciationRules)
    if ($rules.Count -eq 0 -or $targetScope -eq 'all') { return $result }

    $matcher = $script:PronunciationMatchers[$targetScope]
    if ($null -eq $matcher) { return $result }

    $scopedRules = @($matcher.Rules)
    if ($scopedRules.Count -eq 0) { return $result }

    $voiceCapability = $null
    if ($targetScope -eq 'azure') {
        $voiceCapability = Get-AzurePronunciationCapability $AzureVoiceName
    }

    # Collect matches against the ORIGINAL source only. This preserves Pass-76's
    # non-cascading promise: text introduced by a spoken alias or fallback is never
    # fed back through another pronunciation rule.
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($rule in $scopedRules) {
        $needle = [string]$rule.Match
        if ([string]::IsNullOrWhiteSpace($needle) -or $needle.Length -gt $result.Length) { continue }

        $searchStart = 0
        while ($searchStart -le ($result.Length - $needle.Length)) {
            $found = $result.IndexOf($needle, $searchStart, [StringComparison]::OrdinalIgnoreCase)
            if ($found -lt 0) { break }

            if (Test-PronunciationWholeBoundary $result $found $needle.Length) {
                $candidates.Add([PSCustomObject]@{
                    Start = [int]$found
                    Length = [int]$needle.Length
                    Spoken = [string]$rule.Spoken
                    Kind = [string]$rule.Kind
                    Value = [string]$rule.Value
                    FallbackValue = [string]$rule.FallbackValue
                    MatchKey = [string]$rule.MatchKey
                })
            }

            # Advance by one source character so overlapping candidates can still
            # be discovered; the final earliest/longest selection decides which
            # original-source span wins.
            $searchStart = $found + 1
        }
    }

    if ($candidates.Count -eq 0) { return $result }

    # Regex alternation previously chose the earliest source location and, for
    # alternatives beginning at that same location, the longest rule first.
    # Reproduce that policy explicitly and skip any candidate overlapping a span
    # already selected.
    $ordered = @($candidates | Sort-Object -Property @{Expression={ [int]$_.Start }; Ascending=$true}, @{Expression={ [int]$_.Length }; Descending=$true}, @{Expression={ [string]$_.MatchKey }; Ascending=$true})
    $pieces = New-Object System.Collections.Generic.List[string]
    $cursor = 0
    $replacementCount = 0
    $ipaCount = 0
    $fallbackCount = 0
    $fallbackMissingCount = 0
    $aliasCount = 0
    $usedMarkers = @{}

    foreach ($candidate in $ordered) {
        $start = [int]$candidate.Start
        $length = [int]$candidate.Length
        if ($start -lt $cursor) { continue }

        if ($start -gt $cursor) {
            $pieces.Add($result.Substring($cursor, $start - $cursor))
        }

        $sourceSpan = $result.Substring($start, $length)
        $kind = ([string]$candidate.Kind).Trim().ToLowerInvariant()
        if ($kind -eq 'ipa' -and $targetScope -eq 'azure') {
            $canUsePhoneme = ($null -ne $voiceCapability -and [bool]$voiceCapability.Phoneme -and
                $null -ne $AzurePhonemesRef -and $null -ne $AzurePhonemesRef.Value)
            if ($canUsePhoneme) {
                # Use one XML-safe Private Use Area marker per selected IPA span.
                # The Azure child escapes ordinary narration first and expands only
                # these helper-generated markers into bounded <phoneme> elements.
                $marker = $null
                for ($codePoint = 0xE000; $codePoint -le 0xF8FF; $codePoint++) {
                    $candidateMarker = [string][char]$codePoint
                    if ($result.IndexOf($candidateMarker, [StringComparison]::Ordinal) -ge 0) { continue }
                    if ($usedMarkers.ContainsKey([string]$codePoint)) { continue }
                    $marker = $candidateMarker
                    $usedMarkers[[string]$codePoint] = $true
                    break
                }
                if ($null -eq $marker) {
                    $pieces.Add($sourceSpan)
                } else {
                    $AzurePhonemesRef.Value.Add([PSCustomObject]@{
                        Marker = $marker
                        Fallback = $sourceSpan
                        Phoneme = [string]$candidate.Value
                    })
                    $pieces.Add($marker)
                    $ipaCount++
                    $replacementCount++
                }
            } else {
                # Unsupported/unknown voice family: use the rule's plain-text
                # backup pronunciation. If no backup was supplied, preserve the
                # original word rather than speaking the literal IPA payload.
                $fallback = ([string]$candidate.FallbackValue).Trim()
                if ([string]::IsNullOrWhiteSpace($fallback)) {
                    $pieces.Add($sourceSpan)
                    $fallbackMissingCount++
                } else {
                    $pieces.Add($fallback)
                    $fallbackCount++
                    $replacementCount++
                }
            }
        } else {
            $pieces.Add([string]$candidate.Value)
            $aliasCount++
            $replacementCount++
        }
        $cursor = $start + $length
    }

    if ($replacementCount -le 0) {
        if ($fallbackMissingCount -gt 0 -and $null -ne $voiceCapability) {
            Write-HelperLog "pronunciation normalization skipped strategy=ordinal-scan context=$Context scope=$targetScope fallbackMissing=$fallbackMissingCount voicePhoneme=$(([bool]$voiceCapability.Phoneme).ToString().ToLowerInvariant()) voiceReason=$([string]$voiceCapability.Reason)"
        }
        return $result
    }
    if ($cursor -lt $result.Length) {
        $pieces.Add($result.Substring($cursor))
    }

    $result = ($pieces -join '')
    Add-SessionStat 'PronunciationApplied'
    Add-SessionStat 'PronunciationReplacements' $replacementCount
    $contextName = if ([string]::IsNullOrWhiteSpace($Context)) { 'speech' } else { [string]$Context }
    $capabilityText = 'n/a'
    $capabilityReason = 'n/a'
    if ($null -ne $voiceCapability) {
        $capabilityText = ([bool]$voiceCapability.Phoneme).ToString().ToLowerInvariant()
        $capabilityReason = [string]$voiceCapability.Reason
    }
    Write-HelperLog "pronunciation normalization applied strategy=ordinal-scan context=$contextName scope=$targetScope replacements=$replacementCount ipa=$ipaCount fallback=$fallbackCount fallbackMissing=$fallbackMissingCount alias=$aliasCount voicePhoneme=$capabilityText voiceReason=$capabilityReason inputChars=$($Text.Length) outputChars=$($result.Length)"

    return (Limit-SpeechText $result ('normalized ' + $(if ([string]::IsNullOrWhiteSpace($Context)) { 'speech' } else { [string]$Context })))
}

function Limit-CatalogField([string]$Value, [int]$MaxChars) {
    if ($null -eq $Value) { return '' }
    $clean = ([string]$Value).Replace("`0", '').Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ').Trim()
    if ($MaxChars -gt 0 -and $clean.Length -gt $MaxChars) { return $clean.Substring(0, $MaxChars) }
    return $clean
}

function Read-BoundedUtf8Lines([string]$Path, [int64]$MaxBytes, [int]$MaxLines, [string]$Context) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $contextName = if ([string]::IsNullOrWhiteSpace($Context)) { 'catalog' } else { [string]$Context }
    $stream = $null
    $reader = $null
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($MaxBytes -gt 0 -and [int64]$item.Length -gt $MaxBytes) {
            throw "$contextName exceeded local catalog safety limit bytes=$($item.Length) limit=$MaxBytes"
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536, $false)
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($MaxLines -gt 0 -and $lines.Count -ge $MaxLines) {
                throw "$contextName exceeded catalog entry safety limit entries>$MaxLines"
            }
            $lines.Add([string]$line)
        }
        return @($lines)
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}

function Get-AzureVoiceCatalogLines {
    return @(Read-BoundedUtf8Lines $AzureVoiceListPath $VoiceCatalogMaxBytes $VoiceCatalogMaxEntries 'Azure voice catalog')
}


function Read-HttpContentUtf8Bounded($Content, [int64]$MaxBytes, [string]$Context) {
    if ($null -eq $Content) { return '' }
    $contextName = if ([string]::IsNullOrWhiteSpace($Context)) { 'HTTP response' } else { [string]$Context }
    $stream = $null
    $memory = $null
    try {
        $declaredLength = $null
        try { $declaredLength = $Content.Headers.ContentLength } catch {}
        if ($MaxBytes -gt 0 -and $null -ne $declaredLength -and [int64]$declaredLength -gt $MaxBytes) {
            throw "$contextName response exceeded safety limit bytes=$declaredLength limit=$MaxBytes"
        }

        $stream = $Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try { if ($stream.CanTimeout) { $stream.ReadTimeout = 6000 } } catch {}
        $memory = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 65536
        $total = [int64]0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += [int64]$read
            if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) {
                throw "$contextName response exceeded safety limit bytes>$MaxBytes"
            }
            $memory.Write($buffer, 0, $read)
        }
        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    } finally {
        if ($null -ne $memory) { try { $memory.Dispose() } catch {} }
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}

function Get-AzureVoiceCatalogCount {
    try {
        return @((Get-AzureVoiceCatalogLines) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    } catch {
        Write-HelperLog ('Azure voice catalog validation failed: ' + $_.Exception.Message)
        return 0
    }
}

function Remove-StaleRuntimeFiles {
    $removed = 0
    try {
        $cutoff = [DateTime]::UtcNow.AddMinutes(-2)
        # Main command/sequence files can contain narration text. A healthy Lua launch rewrites
        # them immediately before helper startup, so only snapshots older than the conservative
        # cutoff are crash residue and are safe to remove here.
        $patterns = @('tts_azure_request_*.json', 'tts_command.txt', 'tts_sequence.txt', 'tts_command.txt.tmp', 'tts_sequence.txt.tmp', 'TTSConfig.ini.tmp')
        foreach ($pattern in $patterns) {
            foreach ($item in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter $pattern -File -ErrorAction SilentlyContinue)) {
                try {
                    if ($item.LastWriteTimeUtc -lt $cutoff) {
                        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                        $removed++
                    }
                } catch {}
            }
        }

        # Runtime C# builds happen under LocalAppData. Abandoned temporary files can
        # remain after a forced game/PowerShell termination, so clean only files
        # old enough that no healthy Azure child should still own them. A .previous
        # cache is kept if the live cache is missing because AzureStream can restore it.
        if (Test-Path -LiteralPath $AzureSecretRoot) {
            $cacheCutoff = [DateTime]::UtcNow.AddMinutes(-10)
            foreach ($pattern in @('AzureWaveOutPlayer.v1.dll.*.tmp.dll', 'AzureWaveOutPlayer.v1.dll.sha256.*.tmp', 'AzureSpeechKey.dat.*.tmp')) {
                foreach ($item in @(Get-ChildItem -LiteralPath $AzureSecretRoot -Filter $pattern -File -ErrorAction SilentlyContinue)) {
                    try {
                        if ($item.LastWriteTimeUtc -lt $cacheCutoff) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop; $removed++ }
                    } catch {}
                }
            }
            # The credential backup is for rollback from a corrupt published store,
            # not a second persistent credential source. If the primary was deliberately
            # removed, do not resurrect it from backup; retire an old orphan backup.
            try {
                if (-not (Test-Path -LiteralPath $AzureSecretPath) -and (Test-Path -LiteralPath $AzureSecretBackupPath)) {
                    $secretBackupItem = [IO.FileInfo]::new($AzureSecretBackupPath)
                    if ($secretBackupItem.LastWriteTimeUtc -lt $cacheCutoff) { Remove-Item -LiteralPath $AzureSecretBackupPath -Force -ErrorAction Stop; $removed++ }
                }
            } catch {}
            foreach ($previousPath in @($AzurePlayerAssembly + '.previous', $AzurePlayerAssembly + '.sha256.previous')) {
                try {
                    if ((Test-Path -LiteralPath $AzurePlayerAssembly) -and (Test-Path -LiteralPath $previousPath)) {
                        $previousItem = [IO.FileInfo]::new($previousPath)
                        if ($previousItem.LastWriteTimeUtc -lt $cacheCutoff) { Remove-Item -LiteralPath $previousPath -Force -ErrorAction Stop; $removed++ }
                    }
                } catch {}
            }
        }
    } catch {}
    if ($removed -gt 0) { Write-HelperLog "stale runtime cleanup removed=$removed" }
}

function Enable-Tls12Compatibility {
    # Windows PowerShell 5.1 can inherit an older explicit ServicePointManager
    # protocol set on some Windows/.NET installations. Preserve modern
    # SystemDefault (0), but add TLS 1.2 when an explicit legacy set omitted it.
    # Azure Speech requires modern TLS; this changes no certificate/proxy policy.
    try {
        $before = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$before -eq 0) { return 'system-default' }
        $tls12 = [Net.SecurityProtocolType]::Tls12
        if (($before -band $tls12) -eq $tls12) { return 'already-enabled' }
        [Net.ServicePointManager]::SecurityProtocol = ($before -bor $tls12)
        $after = [Net.ServicePointManager]::SecurityProtocol
        if (($after -band $tls12) -eq $tls12) { return 'added-tls12' }
        return 'tls12-unavailable'
    } catch {
        return 'tls12-check-failed'
    }
}

$script:Tls12Compatibility = Enable-Tls12Compatibility

function Test-RetriableAzureCatalogStatus([int]$StatusCode) {
    return ($StatusCode -eq 408 -or $StatusCode -eq 429 -or $StatusCode -eq 500 -or $StatusCode -eq 502 -or $StatusCode -eq 503 -or $StatusCode -eq 504)
}

function Test-RetriableAzureCatalogException($Exception) {
    $cursor = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $cursor; $depth++) {
        $typeName = ''
        try { $typeName = [string]$cursor.GetType().FullName } catch {}
        if ($typeName -match 'TaskCanceledException|OperationCanceledException|HttpRequestException|WebException|SocketException|IOException') { return $true }
        try { $cursor = $cursor.InnerException } catch { $cursor = $null }
    }
    return $false
}

function Get-AzureCatalogRetryDelayMs($Response) {
    $delayMs = 450
    try {
        if ($null -ne $Response -and $null -ne $Response.Headers.RetryAfter) {
            if ($null -ne $Response.Headers.RetryAfter.Delta) {
                $delayMs = [int][Math]::Ceiling($Response.Headers.RetryAfter.Delta.TotalMilliseconds)
            } elseif ($null -ne $Response.Headers.RetryAfter.Date) {
                $delayMs = [int][Math]::Ceiling(($Response.Headers.RetryAfter.Date.UtcDateTime - [DateTime]::UtcNow).TotalMilliseconds)
            }
        }
    } catch {}
    return [Math]::Max(100, [Math]::Min(2000, $delayMs))
}

function Get-FriendlyHttpFailure([int]$StatusCode, [string]$Reason, [string]$Operation) {
    $operationName = if ([string]::IsNullOrWhiteSpace($Operation)) { 'Azure request' } else { $Operation }
    switch ($StatusCode) {
        400 { return "$operationName rejected by Azure (HTTP 400). Check voice/style/region request settings." }
        401 { return "$operationName authentication failed (HTTP 401). The Azure Speech key is invalid or not authorized." }
        403 { return "$operationName was forbidden (HTTP 403). Check the Speech resource, key permissions, and region." }
        404 { return "$operationName endpoint/voice was not found (HTTP 404). Check Azure region and selected voice." }
        408 { return "$operationName timed out at the service (HTTP 408). Check network connectivity and retry." }
        429 { return "$operationName was throttled by Azure (HTTP 429). Wait briefly before retrying." }
        500 { return "$operationName failed because Azure returned HTTP 500. Retry later." }
        502 { return "$operationName failed because Azure returned HTTP 502. Retry later." }
        503 { return "$operationName is temporarily unavailable (HTTP 503). Retry later." }
        504 { return "$operationName timed out upstream (HTTP 504). Retry later." }
        default {
            $cleanReason = ([string]$Reason).Replace("`r", ' ').Replace("`n", ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($cleanReason)) { return "$operationName failed with HTTP $StatusCode." }
            return "$operationName failed with HTTP $StatusCode $cleanReason."
        }
    }
}

function Get-FriendlyNetworkFailure($Exception, [string]$Operation) {
    $operationName = if ([string]::IsNullOrWhiteSpace($Operation)) { 'network request' } else { $Operation }
    if ($null -eq $Exception) { return "$operationName failed for an unknown reason." }

    # Get-FriendlyHttpFailure deliberately creates a short response-body-free
    # message before throwing. PowerShell wraps a thrown string in RuntimeException;
    # preserve our own controlled message instead of replacing it with a useless
    # generic type/HResult line.
    try {
        $controlled = ([string]$Exception.Message).Replace("`r", ' ').Replace("`n", ' ').Trim()
        if ($controlled.StartsWith($operationName, [StringComparison]::OrdinalIgnoreCase) -and
            ($controlled -match '(?i)\bHTTP\s+\d{3}\b|response exceeded safety limit|returned too many voice records|returned an invalid voice catalog')) {
            return $controlled
        }
    } catch {}

    $cursor = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $cursor; $depth++) {
        $typeName = ''
        try { $typeName = [string]$cursor.GetType().FullName } catch {}
        if ($typeName -match 'TaskCanceledException|OperationCanceledException') {
            return "$operationName timed out or was canceled. Check network connectivity and retry."
        }
        if ($typeName -match 'HttpRequestException') {
            return "$operationName could not reach Azure. Check internet access, DNS, proxy/firewall rules, TLS, and the configured region; $(Get-ExceptionSignature $cursor)"
        }
        if ($typeName -match 'WebException') {
            $status = ''
            try { $status = [string]$cursor.Status } catch {}
            if ($status -ne '') { return "$operationName failed at the network layer status=$status; $(Get-ExceptionSignature $cursor)" }
            return "$operationName failed at the network layer; $(Get-ExceptionSignature $cursor)"
        }
        if ($typeName -match 'SocketException') {
            return "$operationName failed during DNS/socket connection; $(Get-ExceptionSignature $cursor)"
        }
        try { $cursor = $cursor.InnerException } catch { $cursor = $null }
    }
    return "$operationName failed; $(Get-ExceptionSignature $Exception)"
}

function Test-DirectoryWritable([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { return $false }
    $probe = $null
    try {
        if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
        $probe = Join-Path $Directory ('.mstts_write_probe_' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probe, 'ok', $Utf8NoBom)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        if ($null -ne $probe) { try { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch {} }
        return $false
    }
}

function Write-CompatibilityPreflight {
    $languageMode = 'Unknown'
    try { $languageMode = [string]$ExecutionContext.SessionState.LanguageMode } catch {}
    $psVersion = 'Unknown'
    try { $psVersion = [string]$PSVersionTable.PSVersion } catch {}
    $detectedPSEdition = 'Desktop'
    try { if ($PSVersionTable.ContainsKey('PSEdition')) { $detectedPSEdition = [string]$PSVersionTable.PSEdition } } catch {}
    $windowsVersion = 'Unknown'
    $windowsTarget = 'unknown'
    try {
        $os = [Environment]::OSVersion
        $windowsVersion = [string]$os.Version
        if ($os.Platform -ne [PlatformID]::Win32NT) { $windowsTarget = 'non-windows' }
        elseif ($os.Version.Major -eq 10) { $windowsTarget = 'supported-windows10-11' }
        else { $windowsTarget = 'outside-documented-target' }
    } catch {}
    $script:WindowsSupportTarget = $windowsTarget
    $architecture = 'Unknown'
    try { $architecture = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' } } catch {}
    $executionPolicy = 'Unknown'
    try {
        $policyRows = @(Get-ExecutionPolicy -List -ErrorAction Stop | ForEach-Object { ([string]$_.Scope) + ':' + ([string]$_.ExecutionPolicy) })
        if ($policyRows.Count -gt 0) { $executionPolicy = [string]::Join(',', [string[]]$policyRows) }
    } catch {}

    $systemSpeech = $false
    try { Add-Type -AssemblyName System.Speech -ErrorAction Stop; $systemSpeech = $true } catch {}
    $netHttp = $false
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop; $netHttp = $true } catch {}
    $dpapi = $false
    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $dpapi = ($null -ne [type]::GetType('System.Security.Cryptography.ProtectedData, System.Security', $false))
        if (-not $dpapi) { $dpapi = ($null -ne ('System.Security.Cryptography.ProtectedData' -as [type])) }
    } catch {}

    $sapi = $false
    $sapiProbe = $null
    try {
        $sapiProbe = New-Object -ComObject SAPI.SpVoice -ErrorAction Stop
        $sapi = ($null -ne $sapiProbe)
    } catch {
        $sapi = $false
    } finally {
        if ($null -ne $sapiProbe) {
            try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($sapiProbe) } catch {}
            $sapiProbe = $null
        }
    }

    $modWritable = Test-DirectoryWritable $PSScriptRoot
    $dataWritable = Test-DirectoryWritable $AzureSecretRoot
    $dynamicAddType = ($languageMode -eq 'FullLanguage')
    $azurePlayerCache = 'missing'
    if (Test-Path -LiteralPath $AzurePlayerAssembly) {
        try {
            $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($AzurePlayerAssembly)
            $signaturePath = $AzurePlayerAssembly + '.sha256'
            if ($null -eq $assemblyName) {
                $azurePlayerCache = 'invalid'
            } elseif (Test-Path -LiteralPath $signaturePath) {
                $azurePlayerCache = 'metadata-valid+source-signature'
            } else {
                $azurePlayerCache = 'legacy-or-stale-no-signature'
            }
        } catch {
            $azurePlayerCache = 'invalid'
        }
    }
    Write-HelperLog "compatibility preflight helper=$HelperVersion windows=$windowsVersion windowsTarget=$windowsTarget arch=$architecture powershell=$psVersion edition=$detectedPSEdition languageMode=$languageMode executionPolicy=$executionPolicy systemSpeech=$systemSpeech sapi=$sapi netHttp=$netHttp tls12Compatibility=$script:Tls12Compatibility dpapi=$dpapi modWritable=$modWritable dataWritable=$dataWritable azurePlayerCache=$azurePlayerCache dynamicAddTypeLikely=$dynamicAddType"

    if ($windowsTarget -ne 'supported-windows10-11') {
        Write-HelperLog "compatibility warning: detected platform/version is outside the documented Windows 10/11 support target. windows=$windowsVersion target=$windowsTarget"
    }
    if ($languageMode -ne 'FullLanguage') {
        Write-HelperLog "compatibility warning: PowerShell LanguageMode=$languageMode; enterprise policy may block runtime C# compilation used by Azure playback. Windows Speech may still work."
    }
    if (-not $systemSpeech) { Write-HelperLog 'compatibility warning: System.Speech could not be loaded; local Windows narration is unavailable.' }
    if (-not $sapi) { Write-HelperLog 'compatibility warning: SAPI.SpVoice COM could not be created; specific-output routing and SAPI fallback may be unavailable.' }
    if (-not $netHttp) { Write-HelperLog 'compatibility warning: System.Net.Http could not be loaded; Azure catalog/synthesis is unavailable.' }
    if ($script:Tls12Compatibility -eq 'tls12-unavailable' -or $script:Tls12Compatibility -eq 'tls12-check-failed') { Write-HelperLog ('compatibility warning: TLS 1.2 compatibility could not be confirmed; Azure HTTPS may fail on this Windows/.NET configuration. state=' + $script:Tls12Compatibility) }
    if (-not $dpapi) { Write-HelperLog 'compatibility warning: Windows DPAPI ProtectedData is unavailable; Azure key storage/import cannot work.' }
    if (-not $modWritable) { Write-HelperLog 'compatibility warning: mod directory is not writable; IPC/config publishing cannot work reliably.' }
    if (-not $dataWritable) { Write-HelperLog 'compatibility warning: TTS data directory is not writable; Azure key/player cache features may fail.' }
}

function Read-SharedUtf8Text([string]$Path, [int64]$MaxBytes = 1048576, [string]$Context = 'shared text', [bool]$AllowTransientMissing = $false) {
    $stream = $null
    $reader = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        } catch [IO.FileNotFoundException] {
            if ($AllowTransientMissing) { return '' }
            throw
        } catch [IO.DirectoryNotFoundException] {
            if ($AllowTransientMissing) { return '' }
            throw
        }
        if ($MaxBytes -gt 0 -and [int64]$stream.Length -gt $MaxBytes) {
            throw "$Context exceeded safety limit bytes=$($stream.Length) limit=$MaxBytes"
        }
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $false)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}

function Test-TTSConfigSnapshotText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [PSCustomObject]@{ Valid = $false; Reason = 'empty' }
    }
    if ($Text.Length -gt 1MB) {
        return [PSCustomObject]@{ Valid = $false; Reason = 'oversized' }
    }

    $schema = 1
    $lastNonEmpty = ''
    $sections = @{ Mod = $false; Speech = $false; Engine = $false }
    try {
        foreach ($rawLine in ($Text -split '\r?\n')) {
            $line = ([string]$rawLine).Trim()
            if ($line -eq '') { continue }
            $lastNonEmpty = $line
            $match = [Text.RegularExpressions.Regex]::Match($line, '^(?i:ConfigSchema)\s*=\s*(\d+)\s*$')
            if ($match.Success) { $schema = [Math]::Max(1, [int]$match.Groups[1].Value) }
            if ($line -ieq '[Mod]') { $sections.Mod = $true }
            elseif ($line -ieq '[Speech]') { $sections.Speech = $true }
            elseif ($line -ieq '[Engine]') { $sections.Engine = $true }
        }
    } catch {}

    if ($schema -ge 3) {
        if ($lastNonEmpty -cne '; MortalShell2TTSConfigEnd=1') {
            return [PSCustomObject]@{ Valid = $false; Reason = 'missing-or-nonfinal-end-marker' }
        }
        if (-not $sections.Mod -or -not $sections.Speech -or -not $sections.Engine) {
            return [PSCustomObject]@{ Valid = $false; Reason = 'missing-required-section' }
        }
    }
    return [PSCustomObject]@{ Valid = $true; Reason = '' }
}

function Read-ValidatedTTSConfigText {
    $script:ConfigSource = 'defaults'
    $current = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            if ([IO.FileInfo]::new($ConfigPath).Length -gt 1MB) {
                Write-HelperLog 'config snapshot rejected reason=oversized; checking last-known-good backup'
            } else {
                $current = Read-SharedUtf8Text $ConfigPath 1048576 'TTSConfig.ini'
            }
        } catch {
            Write-HelperLog "config read error: $($_.Exception.Message)"
        }
    }

    if ($null -ne $current) {
        $state = Test-TTSConfigSnapshotText $current
        if ($state.Valid) {
            $script:ConfigSource = 'current'
            return $current
        }
        Write-HelperLog "config snapshot rejected reason=$($state.Reason); checking last-known-good backup"
    }

    $backupPath = $ConfigPath + '.bak'
    if (Test-Path -LiteralPath $backupPath) {
        try {
            if ([IO.FileInfo]::new($backupPath).Length -gt 1MB) {
                Write-HelperLog 'config backup rejected reason=oversized'
                return $null
            }
            $backup = Read-SharedUtf8Text $backupPath 1048576 'TTSConfig.ini.bak'
            $backupState = Test-TTSConfigSnapshotText $backup
            if ($backupState.Valid) {
                $script:ConfigSource = 'backup'
                Write-HelperLog 'config helper read is using last-known-good backup snapshot'
                return $backup
            }
            Write-HelperLog "config backup rejected reason=$($backupState.Reason)"
        } catch {
            Write-HelperLog "config backup read error: $($_.Exception.Message)"
        }
    }

    # For schema-3 an invalid/truncated snapshot must never be partially parsed by
    # the helper. Older pre-schema-3 nonempty files are accepted by the validator
    # above so normal migration remains compatible.
    return $null
}

function Get-TTSConfig {
    $config = [ordered]@{
        Voice       = 'default'
        Rate        = 0
        Volume      = 100
        Pitch       = 0
        VoiceStyle  = 'default'
        SpeechQueue = 'interrupt'
        DuplicateTextSeconds = 0
        PronunciationCorrections = $true
        ConfigSchema = 1
        AudioOutput = 'default'
        Engine      = 'system_speech'
        AzureVoice  = 'en-US-AvaMultilingualNeural'
        AzureRegion = 'eastus'
    }

    try {
        $configText = Read-ValidatedTTSConfigText
        if ($null -eq $configText) { return $config }
        foreach ($rawLine in ($configText -split '\r?\n')) {
            $line = $rawLine.Trim()
            if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#') -or $line.StartsWith('[')) {
                continue
            }

            $equals = $line.IndexOf('=')
            if ($equals -lt 1) { continue }

            $key = $line.Substring(0, $equals).Trim()
            $value = $line.Substring($equals + 1).Trim()

            switch -Regex ($key) {
                '^(Voice|VoiceName)$' { $config.Voice = $value; break }
                '^Rate$' {
                    $parsed = 0
                    if ([int]::TryParse($value, [ref]$parsed)) {
                        $config.Rate = [Math]::Max(-10, [Math]::Min(10, $parsed))
                    }
                    break
                }
                '^Volume$' {
                    $parsed = 100
                    if ([int]::TryParse($value, [ref]$parsed)) {
                        $config.Volume = [Math]::Max(0, [Math]::Min(100, $parsed))
                    }
                    break
                }
                '^Pitch$' {
                    $parsed = 0
                    if ([int]::TryParse($value, [ref]$parsed)) {
                        $config.Pitch = [Math]::Max(-6, [Math]::Min(6, $parsed))
                    }
                    break
                }
                '^VoiceStyle$' {
                    if ([string]::IsNullOrWhiteSpace($value)) { $config.VoiceStyle = 'default' } else { $config.VoiceStyle = $value.Trim() }
                    break
                }
                '^SpeechQueue$|^SpeechQueueBehavior$' {
                    $mode = ([string]$value).Trim().ToLowerInvariant().Replace('-', '_').Replace(' ', '_')
                    if ($mode -eq 'queue') { $config.SpeechQueue = 'queue' }
                    elseif ($mode -eq 'ignore' -or $mode -eq 'ignore_while_speaking') { $config.SpeechQueue = 'ignore' }
                    else { $config.SpeechQueue = 'interrupt' }
                    break
                }
                '^DuplicateTextSeconds$|^DuplicateSuppressionSeconds$' {
                    $parsed = 0
                    if ([int]::TryParse($value, [ref]$parsed)) {
                        $allowed = @(0, 1, 3, 5, 10)
                        $nearest = 0
                        $bestDistance = [int]::MaxValue
                        foreach ($candidate in $allowed) {
                            $distance = [Math]::Abs($parsed - $candidate)
                            if ($distance -lt $bestDistance) { $nearest = $candidate; $bestDistance = $distance }
                        }
                        $config.DuplicateTextSeconds = $nearest
                    }
                    break
                }
                '^PronunciationCorrections$|^Pronunciation$' {
                    $toggle = ([string]$value).Trim().ToLowerInvariant()
                    $config.PronunciationCorrections = -not ($toggle -eq 'false' -or $toggle -eq '0' -or $toggle -eq 'off' -or $toggle -eq 'no')
                    break
                }
                '^ConfigSchema$' {
                    $parsed = 1
                    if ([int]::TryParse($value, [ref]$parsed)) { $config.ConfigSchema = [Math]::Max(1, $parsed) }
                    break
                }
                '^AudioOutput$' {
                    if ([string]::IsNullOrWhiteSpace($value)) {
                        $config.AudioOutput = 'default'
                    } else {
                        $config.AudioOutput = $value
                    }
                    break
                }
                '^Engine$' {
                    $engine = ([string]$value).Trim().ToLowerInvariant()
                    if ($engine -eq 'azure') { $config.Engine = 'azure' } else { $config.Engine = 'system_speech' }
                    break
                }
                '^AzureVoice$' {
                    if (-not [string]::IsNullOrWhiteSpace($value)) { $config.AzureVoice = $value }
                    break
                }
                '^AzureRegion$' {
                    if (-not [string]::IsNullOrWhiteSpace($value)) { $config.AzureRegion = $value.Trim().ToLowerInvariant() }
                    break
                }
            }
        }
    } catch {
        Write-HelperLog "config read error: $($_.Exception.Message); using defaults"
    }

    # Final defensive normalization in case TTSConfig.ini was edited manually.
    $config.Voice = ([string]$config.Voice).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($config.Voice)) { $config.Voice = 'default' }
    if ($config.Voice.Length -gt 384) { $config.Voice = $config.Voice.Substring(0, 384) }
    $config.AzureVoice = ([string]$config.AzureVoice).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($config.AzureVoice)) { $config.AzureVoice = 'en-US-AvaMultilingualNeural' }
    if ($config.AzureVoice.Length -gt 384) { $config.AzureVoice = $config.AzureVoice.Substring(0, 384) }
    $config.VoiceStyle = ([string]$config.VoiceStyle).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($config.VoiceStyle)) { $config.VoiceStyle = 'default' }
    if ($config.VoiceStyle.Length -gt 96) { $config.VoiceStyle = $config.VoiceStyle.Substring(0, 96) }
    $config.AudioOutput = ([string]$config.AudioOutput).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($config.AudioOutput)) { $config.AudioOutput = 'default' }
    if ($config.AudioOutput.Length -gt 512) { $config.AudioOutput = $config.AudioOutput.Substring(0, 512) }
    $config.AzureRegion = ([string]$config.AzureRegion).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($config.AzureRegion) -or $config.AzureRegion.Length -gt 64 -or $config.AzureRegion -notmatch '^[a-z0-9-]+$') { $config.AzureRegion = 'eastus' }
    return $config
}

function Get-EnabledVoiceNames($Synth) {
    if ($null -eq $Synth) { return @() }
    try { return @($Synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name }) } catch { return @() }
}

function Publish-VoiceList($Synth) {
    if ($null -eq $Synth) {
        try { [IO.File]::WriteAllText($VoiceListPath, '', $Utf8NoBom) } catch {}
        return 0
    }
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($installed in @($Synth.GetInstalledVoices() | Where-Object { $_.Enabled })) {
            if ($lines.Count -ge $VoiceCatalogMaxEntries) {
                Write-HelperLog "System.Speech voice discovery hit safety limit entries=$VoiceCatalogMaxEntries; remaining voices ignored"
                break
            }
            $info = $installed.VoiceInfo
            $name = Limit-CatalogField ([string]$info.Name) 384
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $gender = Limit-CatalogField ([string]$info.Gender) 32
            $locale = ''
            try { $locale = Limit-CatalogField ([string]$info.Culture.Name) 64 } catch {}
            # value, label, gender, locale, styles, pitchSupported
            $lines.Add($name + "`t" + $name + "`t" + $gender + "`t" + $locale + "`t`t1")
        }
        [IO.File]::WriteAllLines($VoiceListPath, [string[]]$lines, $Utf8NoBom)
        return $lines.Count
    } catch {
        Write-HelperLog "voice-list write error: $($_.Exception.Message)"
        return 0
    }
}

function Get-SapiVoiceRecords($SapiVoice) {
    $records = @()
    if ($null -eq $SapiVoice) { return $records }
    try {
        $voices = $SapiVoice.GetVoices()
        $voiceCount = [Math]::Min([int]$voices.Count, $VoiceCatalogMaxEntries)
        if ([int]$voices.Count -gt $VoiceCatalogMaxEntries) {
            Write-HelperLog "SAPI voice discovery hit safety limit entries=$VoiceCatalogMaxEntries; remaining voices ignored"
        }
        for ($index = 0; $index -lt $voiceCount; $index++) {
            $token = $voices.Item($index)
            $name = Limit-CatalogField (Get-SapiTokenName $token) 384
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $gender = ''
            $locale = ''
            try { $gender = Limit-CatalogField ([string]$token.GetAttribute('Gender')) 32 } catch {}
            try {
                $language = [string]$token.GetAttribute('Language')
                if (-not [string]::IsNullOrWhiteSpace($language)) {
                    $firstLanguage = ($language -split ';')[0]
                    $lcid = [Convert]::ToInt32($firstLanguage, 16)
                    $locale = Limit-CatalogField ([Globalization.CultureInfo]::GetCultureInfo($lcid).Name) 64
                }
            } catch {}
            $records += [PSCustomObject]@{ Name = $name; Gender = $gender; Locale = $locale }
        }
    } catch {
        Write-HelperLog "SAPI voice discovery error: $($_.Exception.Message)"
    }
    return @($records)
}

function Publish-SapiVoiceList($SapiVoice) {
    try {
        $records = @(Get-SapiVoiceRecords $SapiVoice)
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($record in $records) {
            if ($lines.Count -ge $VoiceCatalogMaxEntries) { break }
            $cleanName = Limit-CatalogField ([string]$record.Name) 384
            if ([string]::IsNullOrWhiteSpace($cleanName)) { continue }
            $cleanGender = Limit-CatalogField ([string]$record.Gender) 32
            $cleanLocale = Limit-CatalogField ([string]$record.Locale) 64
            $lines.Add($cleanName + "`t" + $cleanName + "`t" + $cleanGender + "`t" + $cleanLocale + "`t`t1")
        }
        [IO.File]::WriteAllLines($VoiceListPath, [string[]]$lines, $Utf8NoBom)
        return $records
    } catch {
        Write-HelperLog "SAPI fallback voice-list write error: $($_.Exception.Message)"
        return @()
    }
}

function Configure-Synthesizer($Synth, $Config, [string[]]$VoiceNames, [string]$SystemDefaultVoice) {
    if ($null -eq $Synth) { return $false }
    $requested = [string]$Config.Voice
    if ([string]::IsNullOrWhiteSpace($requested)) { $requested = 'default' }

    $selected = $null

    if ($requested -ieq 'default') {
        $selected = $SystemDefaultVoice
    } elseif ($requested -ieq 'auto') {
        # Legacy v0.4 compatibility only. New configurations use System Default
        # or an explicit installed voice selected from the in-game menu.
        foreach ($candidate in @('Microsoft Zira Desktop', 'Microsoft Mark Desktop', 'Microsoft Hazel Desktop')) {
            if ($VoiceNames -contains $candidate) { $selected = $candidate; break }
        }
        if ($null -eq $selected) {
            $selected = @($VoiceNames | Where-Object { $_ -notmatch 'David' } | Select-Object -First 1)
            if ($selected -is [array]) { $selected = $selected | Select-Object -First 1 }
        }
        if ($null -eq $selected) { $selected = $SystemDefaultVoice }
    } else {
        $selected = @($VoiceNames | Where-Object { $_ -ieq $requested } | Select-Object -First 1)
        if ($selected -is [array]) { $selected = $selected | Select-Object -First 1 }
        if ($null -eq $selected -or [string]::IsNullOrWhiteSpace([string]$selected)) {
            Write-HelperLog "configured voice not installed: $requested; using system default"
            $selected = $SystemDefaultVoice
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$selected)) {
        try {
            $Synth.SelectVoice([string]$selected)
        } catch {
            Write-HelperLog "voice selection failed for '$selected': $($_.Exception.Message); keeping $($Synth.Voice.Name)"
        }
    }

    $Synth.Rate = [int]$Config.Rate
    $Synth.Volume = [int]$Config.Volume
    return $true
}

function Get-SapiTokenDescription($Token) {
    if ($null -eq $Token) { return '' }
    try {
        $description = [string]$Token.GetDescription()
        if (-not [string]::IsNullOrWhiteSpace($description)) { return $description }
    } catch {
    }
    try { return [string]$Token.Id } catch { return '' }
}

function Get-SapiTokenName($Token) {
    if ($null -eq $Token) { return '' }
    try {
        $name = [string]$Token.GetAttribute('Name')
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    } catch {
    }
    return Get-SapiTokenDescription $Token
}

function Get-SapiAudioOutputRecords($SapiVoice) {
    $records = @()
    if ($null -eq $SapiVoice) { return $records }

    try {
        $outputs = $SapiVoice.GetAudioOutputs()
        $outputCount = [Math]::Min([int]$outputs.Count, $AudioOutputCatalogMaxEntries)
        if ([int]$outputs.Count -gt $AudioOutputCatalogMaxEntries) {
            Write-HelperLog "audio-output discovery hit safety limit entries=$AudioOutputCatalogMaxEntries; remaining outputs ignored"
        }
        for ($index = 0; $index -lt $outputCount; $index++) {
            $token = $outputs.Item($index)
            $id = ''
            try { $id = Limit-CatalogField ([string]$token.Id) 512 } catch {}
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            $description = Limit-CatalogField (Get-SapiTokenDescription $token) 512
            if ([string]::IsNullOrWhiteSpace($description)) { $description = $id }

            $records += [PSCustomObject]@{
                Id          = $id
                Description = $description
                Token       = $token
            }
        }
    } catch {
        Write-HelperLog "audio-output discovery error: $($_.Exception.Message)"
    }

    return @($records)
}

function Publish-AudioOutputList($SapiVoice) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($record in @(Get-SapiAudioOutputRecords $SapiVoice)) {
        if ($lines.Count -ge $AudioOutputCatalogMaxEntries) { break }
        $id = Limit-CatalogField ([string]$record.Id) 512
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $description = Limit-CatalogField ([string]$record.Description) 512
        if ([string]::IsNullOrWhiteSpace($description)) { $description = $id }
        $lines.Add($id + "`t" + $description)
    }

    try {
        $catalogText = [string]::Join("`r`n", [string[]]$lines)
        if ($catalogText.Length -gt 0) { $catalogText += "`r`n" }
        $catalogBytes = [Text.Encoding]::UTF8.GetByteCount($catalogText)
        if ($catalogBytes -gt $AudioOutputCatalogMaxBytes) {
            throw "audio-output catalog exceeded safety limit bytes=$catalogBytes limit=$AudioOutputCatalogMaxBytes"
        }
        [IO.File]::WriteAllText($AudioOutputListPath, $catalogText, $Utf8NoBom)
    } catch {
        Write-HelperLog "audio-output-list write error: $($_.Exception.Message)"
    }

    return $lines.Count
}

function Get-AzureKeySource {
    if (-not [string]::IsNullOrWhiteSpace($env:MORTALSHELL2TTS_AZURE_KEY)) { return 'environment' }
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_SPEECH_KEY)) { return 'environment' }
    if (Test-Path -LiteralPath $AzureSecretPath) { return 'dpapi' }
    return 'missing'
}

function Read-AzureSecretFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $plain = $null
    try {
        $length = [IO.FileInfo]::new($Path).Length
        if ($length -le 0 -or $length -gt 65536) { throw 'Azure key store size is invalid.' }
        $encoded = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($encoded)) { return '' }
        $protected = [Convert]::FromBase64String($encoded)
        $entropy = [Text.Encoding]::UTF8.GetBytes($AzureEntropyText)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plain)
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function Restore-AzureSecretBackup {
    if (-not (Test-Path -LiteralPath $AzureSecretBackupPath)) { return $false }
    try {
        $candidate = Read-AzureSecretFile $AzureSecretBackupPath
        if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
        Copy-Item -LiteralPath $AzureSecretBackupPath -Destination $AzureSecretPath -Force -ErrorAction Stop
        Set-AzureSecretAcl $AzureSecretPath
        Write-HelperLog 'Azure DPAPI key store recovered from last-known-good backup.'
        return $true
    } catch {
        Write-HelperLog ('Azure DPAPI backup recovery failed; ' + (Get-ExceptionSignature $_.Exception))
        return $false
    }
}

function Get-AzureSpeechKey {
    try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch {}
    $environmentKey = [string]$env:MORTALSHELL2TTS_AZURE_KEY
    if ([string]::IsNullOrWhiteSpace($environmentKey)) { $environmentKey = [string]$env:AZURE_SPEECH_KEY }
    if (-not [string]::IsNullOrWhiteSpace($environmentKey)) { return $environmentKey.Trim() }

    if (-not (Test-Path -LiteralPath $AzureSecretPath)) { return '' }
    try {
        $key = Read-AzureSecretFile $AzureSecretPath
        if (-not [string]::IsNullOrWhiteSpace($key)) { return $key }
    } catch {
        Write-HelperLog ('Azure DPAPI key read failed; attempting last-known-good backup; ' + (Get-ExceptionSignature $_.Exception))
    }

    if (Restore-AzureSecretBackup) {
        try { return Read-AzureSecretFile $AzureSecretPath } catch {}
    }
    return ''
}

function Test-AzureKeyValue([string]$Value) {
    $clean = ([string]$Value).Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
    if ($clean.Length -lt 20) { return $null }
    if ($clean -match '\s') { return $null }
    foreach ($character in $clean.ToCharArray()) {
        if ([int][char]$character -lt 32 -or [int][char]$character -eq 127) { return $null }
    }
    return $clean
}

function Set-AzureSecretAcl([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-HelperLog ('Azure key ACL tightening skipped; ' + (Get-ExceptionSignature $_.Exception))
    }
}

function Protect-AzureKey([string]$Key) {
    try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch {}
    $clean = Test-AzureKeyValue $Key
    if ([string]::IsNullOrWhiteSpace($clean)) { throw 'Clipboard does not contain a plausible Azure Speech key.' }

    if (-not (Test-Path -LiteralPath $AzureSecretRoot)) {
        [IO.Directory]::CreateDirectory($AzureSecretRoot) | Out-Null
    }

    $plain = [Text.Encoding]::UTF8.GetBytes($clean)
    $tempPath = $AzureSecretPath + '.' + $PID + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $entropy = [Text.Encoding]::UTF8.GetBytes($AzureEntropyText)
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $encoded = [Convert]::ToBase64String($protected)
        [IO.File]::WriteAllText($tempPath, $encoded, $Utf8NoBom)

        # Validate the staged credential before touching the current store.
        $staged = Read-AzureSecretFile $tempPath
        if ($staged -ne $clean) { throw 'Azure DPAPI staged credential failed readback validation.' }

        if (Test-Path -LiteralPath $AzureSecretPath) {
            try {
                [IO.File]::Replace($tempPath, $AzureSecretPath, $AzureSecretBackupPath, $true)
            } catch {
                # File.Replace is preferred because it publishes + captures the old
                # credential atomically on normal NTFS volumes. Retain a guarded
                # same-directory fallback for unusual filesystems/security products.
                Copy-Item -LiteralPath $AzureSecretPath -Destination $AzureSecretBackupPath -Force -ErrorAction Stop
                Move-Item -LiteralPath $tempPath -Destination $AzureSecretPath -Force -ErrorAction Stop
            }
        } else {
            Move-Item -LiteralPath $tempPath -Destination $AzureSecretPath -Force -ErrorAction Stop
        }

        $published = Read-AzureSecretFile $AzureSecretPath
        if ($published -ne $clean) {
            if (-not (Restore-AzureSecretBackup)) {
                throw 'Azure DPAPI credential publish failed final readback validation and no valid backup was available.'
            }
            throw 'Azure DPAPI credential publish failed final readback validation; previous credential restored.'
        }

        Set-AzureSecretAcl $AzureSecretPath
        if (Test-Path -LiteralPath $AzureSecretBackupPath) { Set-AzureSecretAcl $AzureSecretBackupPath }
        Write-HelperLog ('Azure DPAPI key store published with staged readback; previousBackup=' + [string](Test-Path -LiteralPath $AzureSecretBackupPath))
    } finally {
        try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch {}
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function Get-ClipboardTextSafe {
    try {
        $command = Get-Command Get-Clipboard -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string](Get-Clipboard -Raw)
        }
    } catch {
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        if ([Windows.Forms.Clipboard]::ContainsText()) {
            return [string][Windows.Forms.Clipboard]::GetText()
        }
    } catch {
    }
    return ''
}

function Clear-ClipboardIfMatches([string]$ImportedKey) {
    try {
        $current = Get-ClipboardTextSafe
        if (([string]$current).Trim() -eq ([string]$ImportedKey).Trim()) {
            $command = Get-Command Set-Clipboard -ErrorAction SilentlyContinue
            if ($null -ne $command) {
                Set-Clipboard -Value ''
                return $true
            }
            Add-Type -AssemblyName System.Windows.Forms
            [Windows.Forms.Clipboard]::Clear()
            return $true
        }
    } catch {
    }
    return $false
}

function Publish-EngineStatus($Config, [int]$AzureVoiceCount, [string]$Message) {
    $source = Get-AzureKeySource
    $ready = ($source -ne 'missing' -and -not [string]::IsNullOrWhiteSpace([string]$Config.AzureRegion))
    try {
        # Build the status payload explicitly instead of relying on PowerShell's
        # array-expression coercion. Some Windows PowerShell 5.1 paths collapsed
        # the previous six-element expression into one space-joined line.
        $cleanMessage = ([string]$Message).Replace("`r", ' ').Replace("`n", ' ')
        $statusText = 'Engine=' + [string]$Config.Engine + "`r`n"
        $statusText += 'AzureKey=' + $source + "`r`n"
        $statusText += 'AzureReady=' + ($ready.ToString().ToLowerInvariant()) + "`r`n"
        $statusText += 'AzureRegion=' + [string]$Config.AzureRegion + "`r`n"
        $statusText += 'AzureVoiceCount=' + [string]$AzureVoiceCount + "`r`n"
        $statusText += 'AzureMessage=' + $cleanMessage + "`r`n"
        [IO.File]::WriteAllText($EngineStatusPath, $statusText, $Utf8NoBom)
    } catch {}
}

function Publish-AzureVoiceList($Config) {
    $key = Get-AzureSpeechKey
    if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace([string]$Config.AzureRegion)) {
        try { [IO.File]::WriteAllText($AzureVoiceListPath, '', $Utf8NoBom) } catch {}
        return 0
    }

    $client = $null
    $response = $null
    try {
        Add-Type -AssemblyName System.Net.Http
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $endpoint = 'https://' + [string]$Config.AzureRegion + '.tts.speech.microsoft.com/cognitiveservices/voices/list'

        # Catalog refresh is user-visible because it drives the browser. Give
        # transient network/service failures one bounded retry instead of turning
        # a momentary 429/5xx/socket hiccup into an empty/stale browser session.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $request = $null
            $attemptResponse = $null
            try {
                $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $endpoint)
                $request.Headers.TryAddWithoutValidation('Ocp-Apim-Subscription-Key', $key) | Out-Null
                $attemptResponse = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                if ($attemptResponse.IsSuccessStatusCode) {
                    $response = $attemptResponse
                    $attemptResponse = $null
                    if ($attempt -gt 1) { Write-HelperLog "Azure voice-list refresh retry succeeded attempt=$attempt" }
                    break
                }

                $statusCode = [int]$attemptResponse.StatusCode
                $reasonPhrase = [string]$attemptResponse.ReasonPhrase
                if ($attempt -lt 2 -and (Test-RetriableAzureCatalogStatus $statusCode)) {
                    $delayMs = Get-AzureCatalogRetryDelayMs $attemptResponse
                    try { $attemptResponse.Dispose() } catch {}
                    $attemptResponse = $null
                    Write-HelperLog "Azure voice-list refresh transient HTTP $statusCode; retrying once delayMs=$delayMs"
                    Start-Sleep -Milliseconds $delayMs
                    continue
                }
                throw (Get-FriendlyHttpFailure $statusCode $reasonPhrase 'Azure voice-list refresh')
            } catch {
                if ($attempt -lt 2 -and (Test-RetriableAzureCatalogException $_.Exception)) {
                    Write-HelperLog "Azure voice-list refresh transient network failure; retrying once; $(Get-ExceptionSignature $_.Exception)"
                    Start-Sleep -Milliseconds 450
                    continue
                }
                throw
            } finally {
                if ($null -ne $attemptResponse) { try { $attemptResponse.Dispose() } catch {} }
                if ($null -ne $request) { try { $request.Dispose() } catch {} }
            }
        }
        if ($null -eq $response) { throw 'Azure voice-list refresh did not return a usable HTTP response.' }

        $json = Read-HttpContentUtf8Bounded $response.Content $AzureVoiceResponseMaxBytes 'Azure voice-list refresh'
        $actualBytes = [Text.Encoding]::UTF8.GetByteCount([string]$json)

        # Windows PowerShell 5.1 preserves a JSON root array as one pipeline object
        # from ConvertFrom-Json. Wrapping that command directly in @() therefore
        # creates a one-element OUTER array whose element is the entire Azure array.
        # Member enumeration then silently turns ShortName/Gender/etc. into joined
        # multi-value strings and publishes one giant fake voice. Enumerate the
        # parsed root explicitly into a real record list instead.
        $recordsRaw = $json | ConvertFrom-Json
        $recordsList = New-Object 'System.Collections.Generic.List[object]'
        foreach ($record in $recordsRaw) {
            if ($null -ne $record) { $recordsList.Add($record) }
            if ($recordsList.Count -gt $VoiceCatalogMaxEntries) {
                throw "Azure voice-list refresh returned too many voice records count=$($recordsList.Count) limit=$VoiceCatalogMaxEntries"
            }
        }
        $records = $recordsList.ToArray()
        if ($records.Count -eq 0 -or $null -eq $records[0]) {
            throw 'Azure voice-list refresh returned an invalid voice catalog.'
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $voiceSeen = @{}
        foreach ($voice in @($records | Sort-Object Locale, DisplayName, ShortName)) {
            $short = Limit-CatalogField ([string]$voice.ShortName) 384
            if ([string]::IsNullOrWhiteSpace($short)) { continue }
            $voiceKey = $short.ToLowerInvariant()
            if ($voiceSeen.ContainsKey($voiceKey)) { continue }
            $voiceSeen[$voiceKey] = $true
            $display = Limit-CatalogField ([string]$voice.DisplayName) 448
            if ([string]::IsNullOrWhiteSpace($display)) { $display = $short }
            $locale = Limit-CatalogField ([string]$voice.Locale) 64
            $gender = Limit-CatalogField ([string]$voice.Gender) 32

            $styles = New-Object System.Collections.Generic.List[string]
            $styleSeen = @{}
            try {
                foreach ($rawStyle in $voice.StyleList) {
                    if ($styles.Count -ge 64) { break }
                    $style = (Limit-CatalogField ([string]$rawStyle) 96).Replace(',', ' ')
                    if ([string]::IsNullOrWhiteSpace($style)) { continue }
                    $keyStyle = $style.ToLowerInvariant()
                    if ($styleSeen.ContainsKey($keyStyle)) { continue }
                    $styleSeen[$keyStyle] = $true
                    $styles.Add($style)
                }
            } catch {}

            $label = $display
            if (-not [string]::IsNullOrWhiteSpace($locale)) { $label += ' (' + $locale + ')' }
            $label = Limit-CatalogField $label 512
            $pitchSupported = if ($short -match 'DragonHD') { '0' } else { '1' }
            $styleText = Limit-CatalogField ([string]::Join(',', [string[]]$styles)) 8192
            $lines.Add($short + "`t" + $label + "`t" + $gender + "`t" + $locale + "`t" + $styleText + "`t" + $pitchSupported)
        }

        if ($lines.Count -eq 0) { throw 'Azure voice-list refresh returned an invalid voice catalog.' }
        # A healthy Azure catalog is a large multi-record list. If a future runtime
        # change ever collapses a multi-record response into one serialized row,
        # fail closed and preserve the previous catalog rather than poisoning the UI.
        if ($records.Count -gt 1 -and $lines.Count -le 1) {
            throw "Azure voice-list refresh produced implausibly collapsed catalog records=$($records.Count) serializedRows=$($lines.Count)"
        }
        $voiceText = [string]::Join("`r`n", [string[]]$lines)
        if ($voiceText.Length -gt 0) { $voiceText += "`r`n" }
        $catalogBytes = [Text.Encoding]::UTF8.GetByteCount($voiceText)
        if ($catalogBytes -gt $VoiceCatalogMaxBytes) {
            throw "Azure voice-list refresh returned an invalid voice catalog; serializedBytes=$catalogBytes limit=$VoiceCatalogMaxBytes"
        }
        [IO.File]::WriteAllText($AzureVoiceListPath, $voiceText, $Utf8NoBom)
        Write-HelperLog "Azure voices discovered: $($lines.Count); region=$($Config.AzureRegion); responseBytes=$actualBytes catalogBytes=$catalogBytes"
        return $lines.Count
    } catch {
        Write-HelperLog (Get-FriendlyNetworkFailure $_.Exception 'Azure voice-list refresh')
        return -1
    } finally {
        if ($null -ne $response) { try { $response.Dispose() } catch {} }
        if ($null -ne $client) { try { $client.Dispose() } catch {} }
        $key = $null
    }
}

function Normalize-AzureVoiceStyle($Config) {
    if ($null -eq $Config -or [string]$Config.Engine -ne 'azure') { return $Config }
    $style = ([string]$Config.VoiceStyle).Trim()
    if ([string]::IsNullOrWhiteSpace($style) -or $style -ieq 'default') { $Config.VoiceStyle = 'default'; return $Config }
    if (-not (Test-Path -LiteralPath $AzureVoiceListPath)) { return $Config }

    try {
        $voiceName = [string]$Config.AzureVoice
        $recordFound = $false
        foreach ($line in @(Get-AzureVoiceCatalogLines)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $fields = @([string]$line -split "`t", 6)
            if ($fields.Count -lt 1 -or [string]$fields[0] -ine $voiceName) { continue }
            $recordFound = $true
            $styles = @()
            if ($fields.Count -ge 5 -and -not [string]::IsNullOrWhiteSpace([string]$fields[4])) {
                $styles = @(([string]$fields[4]).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
            $supported = @($styles | Where-Object { $_ -ieq $style } | Select-Object -First 1)
            if ($supported.Count -eq 0) {
                Write-HelperLog "configured Azure style unavailable for voice=$voiceName style=$style; using default"
                $Config.VoiceStyle = 'default'
            } else {
                $Config.VoiceStyle = [string]$supported[0]
            }
            break
        }
        if (-not $recordFound) {
            # Catalog may be stale/offline. Preserve the requested style and let
            # Azure validate it rather than silently discarding user tuning.
            return $Config
        }
    } catch {
        Write-HelperLog "Azure style validation skipped: $($_.Exception.Message)"
    }
    return $Config
}

function Resolve-AzureVoiceFromCatalog($Config) {
    if ($null -eq $Config -or [string]$Config.Engine -ne 'azure') { return $Config }
    if (-not (Test-Path -LiteralPath $AzureVoiceListPath)) { return $Config }

    try {
        $requested = ([string]$Config.AzureVoice).Trim()
        if ([string]::IsNullOrWhiteSpace($requested)) { return $Config }
        $records = @()
        foreach ($line in @(Get-AzureVoiceCatalogLines)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $fields = @([string]$line -split "`t", 6)
            if ($fields.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$fields[0])) { continue }
            $records += [PSCustomObject]@{
                Voice = [string]$fields[0]
                Locale = if ($fields.Count -ge 4) { [string]$fields[3] } else { '' }
            }
        }
        if ($records.Count -eq 0) { return $Config }
        if (@($records | Where-Object { $_.Voice -ieq $requested } | Select-Object -First 1).Count -gt 0) { return $Config }

        # A retired/renamed configured Azure voice should not turn all Azure speech
        # into repeated HTTP 400/404 failures when a fresh catalog proves it is gone.
        # This is a runtime-only fallback; Lua keeps the user's configured selection
        # so the browser can visibly show/fix it rather than silently rewriting it.
        $fallback = @($records | Where-Object { $_.Voice -ieq 'en-US-AvaMultilingualNeural' } | Select-Object -First 1)
        if ($fallback.Count -eq 0) {
            $localeHint = ''
            $parts = $requested.Split('-')
            if ($parts.Length -ge 2) { $localeHint = $parts[0] + '-' + $parts[1] }
            if (-not [string]::IsNullOrWhiteSpace($localeHint)) {
                $fallback = @($records | Where-Object { $_.Locale -ieq $localeHint -or $_.Voice.StartsWith($localeHint + '-', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            }
        }
        if ($fallback.Count -eq 0) { $fallback = @($records | Select-Object -First 1) }
        if ($fallback.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$fallback[0].Voice)) {
            $resolved = [string]$fallback[0].Voice
            Write-HelperLog "configured Azure voice is absent from the current catalog; using runtime fallback configured=$requested fallback=$resolved"
            $Config.AzureVoice = $resolved
            $Config.VoiceStyle = 'default'
        }
    } catch {
        Write-HelperLog ('Azure voice fallback check skipped ' + (Get-ExceptionSignature $_.Exception))
    }
    return $Config
}

function Resolve-AzureAudioOutputName($SapiVoice, [string]$RequestedOutput) {
    if ([string]::IsNullOrWhiteSpace($RequestedOutput) -or $RequestedOutput -ieq 'default') { return '' }
    foreach ($record in @(Get-SapiAudioOutputRecords $SapiVoice)) {
        if ([string]$record.Id -ieq $RequestedOutput -or [string]$record.Description -ieq $RequestedOutput) {
            return [string]$record.Description
        }
    }
    return ''
}

function Stop-AzureStream([ref]$ProcessRef, [ref]$RequestPathRef) {
    $process = $ProcessRef.Value
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        } catch {
        }
        try { $process.Dispose() } catch {}
        $ProcessRef.Value = $null
    }
    $requestPath = [string]$RequestPathRef.Value
    if (-not [string]::IsNullOrWhiteSpace($requestPath)) {
        try { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue } catch {}
        $RequestPathRef.Value = $null
    }
}

function Start-AzureStream($Config, $SapiVoice, [string]$Text, [string]$Sequence, [ref]$ProcessRef, [ref]$RequestPathRef, [bool]$PreviewCadence = $false) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $azurePhonemes = New-Object System.Collections.Generic.List[object]
    if ([bool]$Config.PronunciationCorrections) {
        $Text = Apply-PronunciationCorrections $Text 'azure' 'azure synthesis' ([ref]$azurePhonemes) ([string]$Config.AzureVoice)
    } else {
        Write-HelperLog 'pronunciation normalization bypassed context=azure synthesis reason=disabled'
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if (-not (Test-Path -LiteralPath $AzureStreamScriptPath)) {
        Write-HelperLog 'Azure stream script is missing; cannot speak.'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace((Get-AzureSpeechKey))) {
        Write-HelperLog 'Azure speak requested but no Azure Speech key is configured.'
        return $false
    }

    Stop-AzureStream $ProcessRef $RequestPathRef

    $requestPath = Join-Path $PSScriptRoot ('tts_azure_request_' + [Guid]::NewGuid().ToString('N') + '.json')
    $request = [ordered]@{
        Text = $Text
        PronunciationPhonemes = $azurePhonemes.ToArray()
        PreviewCadence = [bool]$PreviewCadence
        Region = [string]$Config.AzureRegion
        Voice = [string]$Config.AzureVoice
        Rate = [int]$Config.Rate
        Volume = [int]$Config.Volume
        Pitch = [int]$Config.Pitch
        Style = [string]$Config.VoiceStyle
        AudioOutputName = Resolve-AzureAudioOutputName $SapiVoice ([string]$Config.AudioOutput)
    }
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Compress -Depth 4), $Utf8NoBom)
    $RequestPathRef.Value = $requestPath

    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $powershell
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $ownerGamePid = if ($null -ne $gameProcessId) { [int]$gameProcessId } else { 0 }
    $ownerGameStart = if ($null -ne $gameStartFileTimeUtc) { [long]$gameStartFileTimeUtc } else { 0 }
    $ownerHelperStart = if ($null -ne $helperStartFileTimeUtc) { [long]$helperStartFileTimeUtc } else { 0 }
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $AzureStreamScriptPath + '" -RequestPath "' + $requestPath + '" -SecretPath "' + $AzureSecretPath + '" -LogPath "' + $LogPath + '" -ParentHelperPid ' + [string]$PID + ' -ParentHelperStartFileTimeUtc ' + [string]$ownerHelperStart + ' -GameProcessId ' + [string]$ownerGamePid + ' -GameStartFileTimeUtc ' + [string]$ownerGameStart
    try {
        $process = [Diagnostics.Process]::Start($psi)
        if ($null -eq $process) { throw 'Process.Start returned no Azure stream process.' }
        $ProcessRef.Value = $process
        Write-HelperLog "Azure stream started seq=$Sequence pid=$($process.Id) chars=$($Text.Length) voice=$($Config.AzureVoice) region=$($Config.AzureRegion) previewCadence=$PreviewCadence audioOutput=$(if ([string]::IsNullOrWhiteSpace($request.AudioOutputName)) {'System Default'} else {$request.AudioOutputName})"
        return $true
    } catch {
        try { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue } catch {}
        $RequestPathRef.Value = $null
        Write-HelperLog "Azure stream process could not start: $($_.Exception.Message)"
        return $false
    }
}

function Select-SapiVoice($SapiVoice, $Config, [string]$SystemDefaultVoiceId) {
    if ($null -eq $SapiVoice) { return '' }

    $requested = [string]$Config.Voice
    if ([string]::IsNullOrWhiteSpace($requested)) { $requested = 'default' }
    $selectedToken = $null

    try {
        $voices = $SapiVoice.GetVoices()
        for ($index = 0; $index -lt [int]$voices.Count; $index++) {
            $token = $voices.Item($index)
            $id = ''
            try { $id = [string]$token.Id } catch {}
            $name = Get-SapiTokenName $token
            $description = Get-SapiTokenDescription $token

            if ($requested -ieq 'default') {
                if (-not [string]::IsNullOrWhiteSpace($SystemDefaultVoiceId) -and $id -eq $SystemDefaultVoiceId) {
                    $selectedToken = $token
                    break
                }
            } elseif ($name -ieq $requested -or $description -ieq $requested -or $description -like ($requested + ' -*')) {
                $selectedToken = $token
                break
            }
        }

        if ($null -eq $selectedToken -and $requested -ne 'default') {
            Write-HelperLog "configured SAPI voice not installed: $requested; using SAPI system default"
        }

        if ($null -eq $selectedToken -and -not [string]::IsNullOrWhiteSpace($SystemDefaultVoiceId)) {
            for ($index = 0; $index -lt [int]$voices.Count; $index++) {
                $token = $voices.Item($index)
                try {
                    if ([string]$token.Id -eq $SystemDefaultVoiceId) {
                        $selectedToken = $token
                        break
                    }
                } catch {
                }
            }
        }

        if ($null -ne $selectedToken) {
            $SapiVoice.Voice = $selectedToken
        }
    } catch {
        Write-HelperLog "SAPI voice selection failed for '$requested': $($_.Exception.Message)"
    }

    try { return Get-SapiTokenName $SapiVoice.Voice } catch { return '' }
}

function Set-SapiDefaultAudioOutput($SapiVoice) {
    if ($null -eq $SapiVoice) { return $false }
    try {
        # SAPI documents Nothing/NULL as "use the default audio device". Resetting
        # explicitly prevents a previously selected device token from surviving a
        # later config change or a device disconnect.
        $SapiVoice.AudioOutput = $null
        return $true
    } catch {
        Write-HelperLog ("SAPI default-output reset failed; " + (Get-ExceptionSignature $_.Exception))
        return $false
    }
}

function Select-SapiAudioOutput($SapiVoice, [string]$RequestedOutput) {
    $result = [ordered]@{
        Success = $false
        Id      = ''
        Name    = ''
    }

    if ($null -eq $SapiVoice -or [string]::IsNullOrWhiteSpace($RequestedOutput) -or $RequestedOutput -ieq 'default') {
        return [PSCustomObject]$result
    }

    foreach ($record in @(Get-SapiAudioOutputRecords $SapiVoice)) {
        if ([string]$record.Id -ieq $RequestedOutput -or [string]$record.Description -ieq $RequestedOutput) {
            try {
                $SapiVoice.AudioOutput = $record.Token
                $result.Success = $true
                $result.Id = [string]$record.Id
                $result.Name = [string]$record.Description
                return [PSCustomObject]$result
            } catch {
                Write-HelperLog "audio-output selection failed for '$($record.Description)': $($_.Exception.Message)"
                return [PSCustomObject]$result
            }
        }
    }

    Write-HelperLog "configured audio output is unavailable: $RequestedOutput; using Windows default"
    return [PSCustomObject]$result
}

function Stop-AllSpeech($SystemSynth, $SapiVoice) {
    if ($null -ne $SystemSynth) {
        try { $SystemSynth.SpeakAsyncCancelAll() } catch {}
    }
    if ($null -ne $SapiVoice) {
        try { $null = $SapiVoice.Speak('', 3) } catch {}
    }
}

function Configure-SpeechBackends($SystemSynth, $SapiVoice, $Config, [string[]]$VoiceNames, [string]$SystemDefaultVoice, [string]$SapiSystemDefaultVoiceId) {
    $status = [ordered]@{
        Backend    = 'unavailable'
        OutputId   = 'default'
        OutputName = 'System Default'
        VoiceName  = ''
    }

    if ($null -ne $SystemSynth) {
        try {
            $null = Configure-Synthesizer $SystemSynth $Config $VoiceNames $SystemDefaultVoice
            try { $SystemSynth.SetOutputToDefaultAudioDevice() } catch {}
            $status.Backend = 'system_speech'
            try { $status.VoiceName = [string]$SystemSynth.Voice.Name } catch {}
        } catch {
            Write-HelperLog "System.Speech configuration failed: $($_.Exception.Message); trying SAPI fallback"
        }
    }

    $requestedOutput = [string]$Config.AudioOutput
    $specificOutputRequested = -not [string]::IsNullOrWhiteSpace($requestedOutput) -and $requestedOutput -ine 'default'

    # SAPI is normally used only for specific-output routing. If System.Speech is
    # unavailable, however, it becomes the local-TTS fallback even on the default
    # output so Azure/local speech remain independently usable.
    if ($null -ne $SapiVoice -and ($specificOutputRequested -or $status.Backend -eq 'unavailable')) {
        $sapiVoiceName = Select-SapiVoice $SapiVoice $Config $SapiSystemDefaultVoiceId
        try { $SapiVoice.Rate = [int]$Config.Rate } catch {}
        try { $SapiVoice.Volume = [int]$Config.Volume } catch {}

        if ($specificOutputRequested) {
            $output = Select-SapiAudioOutput $SapiVoice $requestedOutput
            if ($output.Success) {
                $status.Backend = 'sapi5'
                $status.OutputId = [string]$output.Id
                $status.OutputName = [string]$output.Name
                if (-not [string]::IsNullOrWhiteSpace($sapiVoiceName)) { $status.VoiceName = $sapiVoiceName }
                return [PSCustomObject]$status
            }
            if ($status.Backend -ne 'unavailable') {
                # System.Speech still works on its default output, so keep it.
                # Reset the standby SAPI object as well so a previously selected
                # token cannot linger if this object is later needed as fallback.
                $null = Set-SapiDefaultAudioOutput $SapiVoice
                return [PSCustomObject]$status
            }
            Write-HelperLog 'System.Speech is unavailable and the requested SAPI output could not be selected; falling back to the SAPI default output.'
            $null = Set-SapiDefaultAudioOutput $SapiVoice
        } else {
            $null = Set-SapiDefaultAudioOutput $SapiVoice
        }

        $status.Backend = 'sapi5'
        $status.OutputId = 'default'
        $status.OutputName = 'System Default'
        if (-not [string]::IsNullOrWhiteSpace($sapiVoiceName)) { $status.VoiceName = $sapiVoiceName }
        return [PSCustomObject]$status
    }

    if ($specificOutputRequested -and $null -eq $SapiVoice -and $status.Backend -ne 'unavailable') {
        Write-HelperLog 'specific audio output requested but SAPI is unavailable; using Windows default'
    }

    return [PSCustomObject]$status
}

function Invoke-SapiSpeech($SapiVoice, [string]$Text, $Config) {
    if ($null -eq $SapiVoice -or [string]::IsNullOrWhiteSpace($Text)) { return $false }
    $pitch = 0
    try { $pitch = [Math]::Max(-6, [Math]::Min(6, [int]$Config.Pitch)) } catch {}
    if ($pitch -ne 0) {
        try {
            $escaped = [Security.SecurityElement]::Escape($Text)
            $pitchText = if ($pitch -gt 0) { '+' + $pitch } else { [string]$pitch }
            $xml = '<pitch absmiddle="' + $pitchText + '">' + $escaped + '</pitch>'
            # Async + purge-before-speak + XML.
            $null = $SapiVoice.Speak($xml, 11)
            return $true
        } catch {
            Write-HelperLog ("SAPI pitch markup failed; falling back to plain speech; " + (Get-ExceptionSignature $_.Exception))
        }
    }
    try {
        $null = $SapiVoice.Speak($Text, 3)
        return $true
    } catch {
        Write-HelperLog ("SAPI speech failed; " + (Get-ExceptionSignature $_.Exception))
        return $false
    }
}

function Configure-SapiEmergencyFallback($SapiVoice, $Config, [string]$SapiSystemDefaultVoiceId) {
    if ($null -eq $SapiVoice) { return [PSCustomObject]@{ Ready = $false; VoiceName = ''; OutputName = 'System Default' } }
    $voiceName = Select-SapiVoice $SapiVoice $Config $SapiSystemDefaultVoiceId
    try { $SapiVoice.Rate = [int]$Config.Rate } catch {}
    try { $SapiVoice.Volume = [int]$Config.Volume } catch {}

    $outputName = 'System Default'
    $requestedOutput = [string]$Config.AudioOutput
    $specificOutputRequested = -not [string]::IsNullOrWhiteSpace($requestedOutput) -and $requestedOutput -ine 'default'
    if ($specificOutputRequested) {
        $output = Select-SapiAudioOutput $SapiVoice $requestedOutput
        if ($output.Success) {
            $outputName = [string]$output.Name
        } else {
            $null = Set-SapiDefaultAudioOutput $SapiVoice
        }
    } else {
        $null = Set-SapiDefaultAudioOutput $SapiVoice
    }
    return [PSCustomObject]@{ Ready = $true; VoiceName = [string]$voiceName; OutputName = [string]$outputName }
}

function Speak-Active($SystemSynth, $SapiVoice, $Status, [string]$Text, $Config, [string]$SapiSystemDefaultVoiceId) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ([bool]$Config.PronunciationCorrections) {
        $Text = Apply-PronunciationCorrections $Text 'local' 'local synthesis' $null ''
    } else {
        Write-HelperLog 'pronunciation normalization bypassed context=local synthesis reason=disabled'
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $pitch = 0
    try { $pitch = [Math]::Max(-6, [Math]::Min(6, [int]$Config.Pitch)) } catch {}

    if ($Status.Backend -eq 'sapi5' -and $null -ne $SapiVoice) {
        if (Invoke-SapiSpeech $SapiVoice $Text $Config) { return $true }

        # A specifically selected SAPI output can disappear between configuration and
        # speech (USB/Bluetooth/virtual-device disconnect). Retry once on the Windows
        # default output instead of leaving local narration dead until the next CONFIG.
        $requestedOutput = [string]$Config.AudioOutput
        $specificOutputRequested = -not [string]::IsNullOrWhiteSpace($requestedOutput) -and $requestedOutput -ine 'default' -and [string]$Status.OutputId -ine 'default'
        if ($specificOutputRequested) {
            Write-HelperLog 'SAPI narration failed on the configured audio output; retrying once on Windows default output.'
            try {
                if (Set-SapiDefaultAudioOutput $SapiVoice) {
                    try { $SapiVoice.Rate = [int]$Config.Rate } catch {}
                    try { $SapiVoice.Volume = [int]$Config.Volume } catch {}
                    if (Invoke-SapiSpeech $SapiVoice $Text $Config) {
                        try { $Status.OutputId = 'default'; $Status.OutputName = 'System Default' } catch {}
                        Add-SessionStat 'AudioFallbacks'
                        Write-HelperLog "SAPI audio-output recovery succeeded audioOutput=System Default chars=$($Text.Length)"
                        return $true
                    }
                }
            } catch {
                Write-HelperLog ("SAPI default-output recovery failed; " + (Get-ExceptionSignature $_.Exception))
            }
        }
        return $false
    }

    if ($Status.Backend -eq 'system_speech' -and $null -ne $SystemSynth) {
        try { $SystemSynth.SpeakAsyncCancelAll() } catch {}
        if ($pitch -ne 0) {
            try {
                $escaped = [Security.SecurityElement]::Escape($Text)
                $voiceName = [Security.SecurityElement]::Escape([string]$SystemSynth.Voice.Name)
                $language = 'en-US'
                try { $language = [string]$SystemSynth.Voice.Culture.Name } catch {}
                $pitchText = if ($pitch -gt 0) { '+' + $pitch + 'st' } else { [string]$pitch + 'st' }
                $ssml = '<speak version="1.0" xml:lang="' + $language + '" xmlns="http://www.w3.org/2001/10/synthesis"><voice name="' + $voiceName + '"><prosody pitch="' + $pitchText + '">' + $escaped + '</prosody></voice></speak>'
                $null = $SystemSynth.SpeakSsmlAsync($ssml)
                return $true
            } catch {
                Write-HelperLog ("System.Speech pitch SSML failed; falling back to plain speech; " + (Get-ExceptionSignature $_.Exception))
            }
        }
        try {
            $null = $SystemSynth.SpeakAsync($Text)
            return $true
        } catch {
            Write-HelperLog ("System.Speech narration failed; attempting SAPI emergency fallback; " + (Get-ExceptionSignature $_.Exception))
            if ($null -ne $SapiVoice) {
                try {
                    $fallback = Configure-SapiEmergencyFallback $SapiVoice $Config $SapiSystemDefaultVoiceId
                    if ($fallback.Ready -and (Invoke-SapiSpeech $SapiVoice $Text $Config)) {
                        Add-SessionStat 'SapiFallbacks'
                        Write-HelperLog "SAPI emergency fallback succeeded voice=$($fallback.VoiceName) audioOutput=$($fallback.OutputName) chars=$($Text.Length)"
                        return $true
                    }
                } catch {
                    Write-HelperLog ("SAPI emergency fallback failed; " + (Get-ExceptionSignature $_.Exception))
                }
            }
            return $false
        }
    }

    # A backend may have become unavailable after configuration. Give the already
    # created SAPI object one last fail-soft path before declaring local speech dead.
    if ($null -ne $SapiVoice) {
        try {
            $fallback = Configure-SapiEmergencyFallback $SapiVoice $Config $SapiSystemDefaultVoiceId
            if ($fallback.Ready -and (Invoke-SapiSpeech $SapiVoice $Text $Config)) {
                Add-SessionStat 'SapiFallbacks'
                Write-HelperLog "local narration recovered through SAPI emergency fallback voice=$($fallback.VoiceName) audioOutput=$($fallback.OutputName) chars=$($Text.Length)"
                return $true
            }
        } catch {
            Write-HelperLog ("local SAPI recovery failed; " + (Get-ExceptionSignature $_.Exception))
        }
    }

    Write-HelperLog 'local narration requested but neither System.Speech nor SAPI could speak.'
    return $false
}

function Get-GameProcesses {
    $byId = @{}

    foreach ($name in $GameProcessNames) {
        try {
            foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                if ($null -ne $process) {
                    $byId[[int]$process.Id] = $process
                }
            }
        } catch {
        }
    }

    return @($byId.Values)
}

function Find-CurrentGameProcess {
    $deadline = (Get-Date).AddSeconds(3)

    do {
        $candidates = @(Get-GameProcesses)
        if ($candidates.Count -gt 0) {
            $ranked = @()

            foreach ($process in $candidates) {
                $startUtc = $null
                try { $startUtc = $process.StartTime.ToUniversalTime() } catch {}

                $ranked += [PSCustomObject]@{
                    Process  = $process
                    StartUtc = $startUtc
                    Id       = [int]$process.Id
                }
            }

            $withStart = @($ranked | Where-Object { $null -ne $_.StartUtc })
            if ($withStart.Count -gt 0) {
                return ($withStart | Sort-Object StartUtc -Descending | Select-Object -First 1).Process
            }

            return ($ranked | Sort-Object Id -Descending | Select-Object -First 1).Process
        }

        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Test-AnyGameRunning {
    return @(Get-GameProcesses).Count -gt 0
}

function Test-SpeechActive($SystemSynth, $SapiVoice, $AzureProcess) {
    try { if ([DateTime]::UtcNow -lt $script:speechStartGuardUntil) { return $true } } catch {}
    if ($null -ne $AzureProcess) {
        try { if (-not $AzureProcess.HasExited) { return $true } } catch {}
    }
    if ($null -ne $SystemSynth) {
        try {
            if ([string]$SystemSynth.State -eq 'Speaking') { return $true }
        } catch {}
    }
    if ($null -ne $SapiVoice) {
        try {
            # SpeechRunState.SRSEIsSpeaking = 2.
            if ([int]$SapiVoice.Status.RunningState -eq 2) { return $true }
        } catch {}
    }
    return $false
}

function Clear-SpeechQueue($Queue, [string]$Reason) {
    if ($null -eq $Queue) { return }
    $count = 0
    try { $count = [int]$Queue.Count } catch {}
    try { $Queue.Clear() } catch {}
    if ($count -gt 0) { Write-HelperLog "speech queue cleared count=$count reason=$Reason" }
}

function Invoke-SpeechItem(
    [string]$Text,
    [string]$Sequence,
    $SystemSynth,
    $SapiVoice,
    [string[]]$VoiceNames,
    [string]$SystemDefaultVoice,
    [string]$SapiSystemDefaultVoiceId,
    [ref]$SpeechStatusRef,
    [ref]$AzureProcessRef,
    [ref]$AzureRequestPathRef,
    [ref]$AzureVoiceCountRef,
    [ref]$LastAzureRegionRef,
    [ref]$LastEngineRef
) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $previousRegion = [string]$LastAzureRegionRef.Value
    $previousEngine = [string]$LastEngineRef.Value
    $configNow = Get-TTSConfig

    # If region/engine context changed, refresh before deciding whether the saved
    # Azure voice is retired. Using the old-region catalog for fallback selection
    # could otherwise replace a perfectly valid voice only because the cache was stale.
    $azureContextChanged = (([string]$configNow.AzureRegion -ne $previousRegion) -or (([string]$configNow.Engine -eq 'azure') -and $previousEngine -ne 'azure'))
    if ((Get-AzureKeySource) -ne 'missing' -and $azureContextChanged) {
        $refreshed = Publish-AzureVoiceList $configNow
        if ($refreshed -ge 0) { $AzureVoiceCountRef.Value = $refreshed }
    }
    if ($configNow.Engine -eq 'azure') {
        $configNow = Resolve-AzureVoiceFromCatalog $configNow
        $configNow = Normalize-AzureVoiceStyle $configNow
    }
    $statusNow = Configure-SpeechBackends $SystemSynth $SapiVoice $configNow $VoiceNames $SystemDefaultVoice $SapiSystemDefaultVoiceId
    $SpeechStatusRef.Value = $statusNow
    $LastAzureRegionRef.Value = [string]$configNow.AzureRegion
    $LastEngineRef.Value = [string]$configNow.Engine
    Publish-EngineStatus $configNow ([int]$AzureVoiceCountRef.Value) 'Configuration synchronized for speech.'

    if ($configNow.Engine -eq 'azure') {
        $started = Start-AzureStream $configNow $SapiVoice $Text $Sequence $AzureProcessRef $AzureRequestPathRef
        if ($started) {
            $resolvedOutput = Resolve-AzureAudioOutputName $SapiVoice ([string]$configNow.AudioOutput)
            if ([string]::IsNullOrWhiteSpace($resolvedOutput)) { $resolvedOutput = 'System Default' }
            $script:speechStartGuardUntil = [DateTime]::UtcNow.AddMilliseconds(150)
            Add-SessionStat 'AzureStarts'
            Write-HelperLog "speak seq=$Sequence voice=$($configNow.AzureVoice) rate=$($configNow.Rate) volume=$($configNow.Volume) pitch=$($configNow.Pitch) style=$($configNow.VoiceStyle) backend=azure_stream audioOutput=$resolvedOutput queue=$($configNow.SpeechQueue)"
            return $true
        }
        return $false
    }

    $spoken = Speak-Active $SystemSynth $SapiVoice $statusNow $Text $configNow $SapiSystemDefaultVoiceId
    if (-not $spoken) {
        Write-HelperLog "local speak failed seq=$Sequence backend=$($statusNow.Backend) chars=$($Text.Length)"
        return $false
    }
    $script:speechStartGuardUntil = [DateTime]::UtcNow.AddMilliseconds(150)
    Add-SessionStat 'LocalStarts'
    Write-HelperLog "speak seq=$Sequence voice=$($statusNow.VoiceName) rate=$($configNow.Rate) volume=$($configNow.Volume) pitch=$($configNow.Pitch) backend=$($statusNow.Backend) audioOutput=$($statusNow.OutputName) queue=$($configNow.SpeechQueue)"
    return $true
}

$createdNew = $false
$mutex = $null
$synth = $null
$sapi = $null
$sapiSystemDefaultVoiceId = ''
$sapiSystemDefaultVoiceName = ''
$speechStatus = $null
$audioOutputCount = 0
$azureProcess = $null
$azureRequestPath = $null
$azureVoiceCount = 0
$lastAzureRegion = ''
$lastEngine = ''
$speechStartGuardUntil = [DateTime]::MinValue
$speechQueue = New-Object 'System.Collections.Generic.Queue[object]'
$speechQueueLimit = 24
$gameProcessId = $null
$gameStartFileTimeUtc = $null
$helperStartFileTimeUtc = 0
try { $helperStartFileTimeUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc() } catch {}
$bindingMode = 'fallback-name'

try {
    $gameProcess = Find-CurrentGameProcess

    if ($null -ne $gameProcess) {
        $gameProcessId = [int]$gameProcess.Id
        $gameProcessName = [string]$gameProcess.ProcessName
        $bindingMode = 'exact-pid'

        try {
            $gameStartFileTimeUtc = $gameProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
        } catch {
            $gameStartFileTimeUtc = $null
        }

        $MutexName = "Local\MortalShell2TTSHelper_$gameProcessId"
    } else {
        $MutexName = 'Local\MortalShell2TTSHelper_Fallback'
        Write-HelperLog 'exact game PID lookup failed; using name-based lifecycle fallback'
    }

    $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-HelperLog "duplicate helper rejected; mode=$bindingMode gamePid=$gameProcessId"
        exit 0
    }

    Initialize-HelperLog
    # Versioned session anchor for support evidence. Keep this metadata-only and
    # emit it before compatibility/backend initialization so even an early helper
    # failure can be correctly attributed to this candidate without mixing older
    # helper sessions from rotated logs.
    Write-HelperLog "helper session start version=$HelperVersion pid=$PID startFileTimeUtc=$helperStartFileTimeUtc gamePid=$(if ($null -eq $gameProcessId) { 0 } else { $gameProcessId }) bindingMode=$bindingMode"
    Remove-StaleRuntimeFiles
    # Compatibility reporting is diagnostic/support instrumentation. A defect in
    # this optional probe must never prevent the actual speech helper from starting.
    try {
        Write-CompatibilityPreflight
    } catch {
        $preflightMessage = ''
        $preflightLine = 0
        try { $preflightMessage = [string]$_.Exception.Message } catch {}
        try { $preflightLine = [int]$_.InvocationInfo.ScriptLineNumber } catch {}
        Write-HelperLog ("compatibility preflight unexpected failure; continuing helper startup; " + (Get-ExceptionSignature $_.Exception) + " line=$preflightLine message=$preflightMessage")
    }
    $heartbeatReady = Write-HelperHeartbeat -Force
    Write-HelperLog "helper heartbeat initialized ready=$heartbeatReady intervalMs=$HeartbeatIntervalMs"

    $systemDefaultVoice = ''
    $voiceNames = @()
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $synth.SetOutputToDefaultAudioDevice()
        $systemDefaultVoice = [string]$synth.Voice.Name
        $voiceNames = @(Get-EnabledVoiceNames $synth)
        $null = Publish-VoiceList $synth
        Write-HelperLog "System.Speech voices discovered: count=$($voiceNames.Count); systemDefault=$systemDefaultVoice"
    } catch {
        $synth = $null
        try { [IO.File]::WriteAllText($VoiceListPath, '', $Utf8NoBom) } catch {}
        Write-HelperLog "System.Speech initialization failed; attempting SAPI local fallback and keeping Azure available: $($_.Exception.Message)"
    }

    try {
        $sapi = New-Object -ComObject SAPI.SpVoice
        try { $sapiSystemDefaultVoiceId = [string]$sapi.Voice.Id } catch { $sapiSystemDefaultVoiceId = '' }
        try { $sapiSystemDefaultVoiceName = Get-SapiTokenName $sapi.Voice } catch { $sapiSystemDefaultVoiceName = '' }
        $audioOutputCount = Publish-AudioOutputList $sapi
        if ($null -eq $synth) {
            $sapiVoiceRecords = @(Publish-SapiVoiceList $sapi)
            $voiceNames = @($sapiVoiceRecords | ForEach-Object { [string]$_.Name })
            $systemDefaultVoice = $sapiSystemDefaultVoiceName
            Write-HelperLog "SAPI fallback voices discovered: count=$($voiceNames.Count); default=$sapiSystemDefaultVoiceName"
        }
        Write-HelperLog "audio outputs discovered: $audioOutputCount; sapiDefaultVoice=$sapiSystemDefaultVoiceName"
    } catch {
        $sapi = $null
        try { [IO.File]::WriteAllText($AudioOutputListPath, '', $Utf8NoBom) } catch {}
        Write-HelperLog "SAPI audio/local fallback unavailable: $($_.Exception.Message)"
    }

    $ttsConfig = Get-TTSConfig
    $speechStatus = Configure-SpeechBackends $synth $sapi $ttsConfig $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId
    $lastAzureRegion = [string]$ttsConfig.AzureRegion
    $lastEngine = [string]$ttsConfig.Engine
    if ((Get-AzureKeySource) -ne 'missing') {
        $shouldRefreshAzureVoices = ($ttsConfig.Engine -eq 'azure' -or -not (Test-Path -LiteralPath $AzureVoiceListPath))
        if (-not $shouldRefreshAzureVoices -and (Test-Path -LiteralPath $AzureVoiceListPath)) {
            try {
                $cachedVoiceLines = @(Get-AzureVoiceCatalogLines)
                $firstVoiceLine = @($cachedVoiceLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
                if ($firstVoiceLine.Count -eq 0 -or (([string]$firstVoiceLine[0]).Split("`t").Count -lt 6)) { $shouldRefreshAzureVoices = $true }
            } catch {
                Write-HelperLog ('cached Azure voice catalog rejected; forcing refresh: ' + $_.Exception.Message)
                $shouldRefreshAzureVoices = $true
            }
        }
        if ($shouldRefreshAzureVoices) {
            $azureVoiceCount = Publish-AzureVoiceList $ttsConfig
            if ($azureVoiceCount -lt 0) { $azureVoiceCount = Get-AzureVoiceCatalogCount }
        } elseif (Test-Path -LiteralPath $AzureVoiceListPath) {
            $azureVoiceCount = Get-AzureVoiceCatalogCount
        }
    } else {
        try { [IO.File]::WriteAllText($AzureVoiceListPath, '', $Utf8NoBom) } catch {}
    }
    Publish-EngineStatus $ttsConfig $azureVoiceCount 'Ready'

    $supportWindows = 'Unknown'
    try { $supportWindows = [string][Environment]::OSVersion.Version } catch {}
    $supportPowerShell = 'Unknown'
    try { $supportPowerShell = [string]$PSVersionTable.PSVersion } catch {}
    $supportLanguageMode = 'Unknown'
    try { $supportLanguageMode = [string]$ExecutionContext.SessionState.LanguageMode } catch {}
    $supportGameVersion = 'Unknown'
    try {
        if ($null -ne $gameProcess -and $null -ne $gameProcess.MainModule) {
            $fileVersion = [string]$gameProcess.MainModule.FileVersionInfo.FileVersion
            if (-not [string]::IsNullOrWhiteSpace($fileVersion)) { $supportGameVersion = $fileVersion }
        }
    } catch {}
    $supportUE4SSVersion = 'Unknown'
    try {
        if ($null -ne $gameProcess) {
            foreach ($module in @($gameProcess.Modules)) {
                if ([string]$module.ModuleName -ieq 'UE4SS.dll') {
                    $ue4ssFileVersion = [string]$module.FileVersionInfo.FileVersion
                    if (-not [string]::IsNullOrWhiteSpace($ue4ssFileVersion)) { $supportUE4SSVersion = $ue4ssFileVersion }
                    else { $supportUE4SSVersion = 'loaded-version-unreported' }
                    break
                }
            }
        }
    } catch {}
    $pronunciationRules = @(Get-PronunciationRules)
    $activeBackend = if ($ttsConfig.Engine -eq 'azure') { 'azure_stream' } else { $speechStatus.Backend }
    $activeVoice = if ($ttsConfig.Engine -eq 'azure') { [string]$ttsConfig.AzureVoice } else { [string]$speechStatus.VoiceName }
    $pronunciationVoicePhoneme = 'n/a'
    $pronunciationVoiceReason = 'n/a'
    if ($ttsConfig.Engine -eq 'azure') {
        $pronunciationCapability = Get-AzurePronunciationCapability ([string]$ttsConfig.AzureVoice)
        $pronunciationVoicePhoneme = ([bool]$pronunciationCapability.Phoneme).ToString().ToLowerInvariant()
        $pronunciationVoiceReason = [string]$pronunciationCapability.Reason
    }
    $supportGamePid = 0
    try { if ($null -ne $gameProcessId) { $supportGamePid = [int]$gameProcessId } } catch { $supportGamePid = 0 }
    Write-HelperLog "support summary helper=$HelperVersion supportSchema=$SupportSchema configSchema=$($ttsConfig.ConfigSchema) configSource=$script:ConfigSource gameVersion=$supportGameVersion ue4ssVersion=$supportUE4SSVersion windows=$supportWindows windowsTarget=$script:WindowsSupportTarget powershell=$supportPowerShell languageMode=$supportLanguageMode helperPid=$PID helperStartFileTimeUtc=$helperStartFileTimeUtc gamePid=$supportGamePid bindingMode=$bindingMode engine=$($ttsConfig.Engine) backend=$activeBackend voice=$activeVoice voiceCount=$($voiceNames.Count) rate=$($ttsConfig.Rate) volume=$($ttsConfig.Volume) pitch=$($ttsConfig.Pitch) style=$($ttsConfig.VoiceStyle) audioOutput=$($speechStatus.OutputName) audioOutputs=$audioOutputCount azureKey=$(Get-AzureKeySource) azureVoices=$azureVoiceCount queue=$($ttsConfig.SpeechQueue) duplicateSeconds=$($ttsConfig.DuplicateTextSeconds) pronunciationEnabled=$(([bool]$ttsConfig.PronunciationCorrections).ToString().ToLowerInvariant()) pronunciationRules=$($pronunciationRules.Count) pronunciationState=$script:PronunciationRulesState pronunciationUserEntries=$script:PronunciationUserRuleCount pronunciationVoicePhoneme=$pronunciationVoicePhoneme pronunciationVoiceReason=$pronunciationVoiceReason speechTextLimitChars=$SpeechTextLimitChars voiceCatalogEntriesLimit=$VoiceCatalogMaxEntries voiceCatalogBytesLimit=$VoiceCatalogMaxBytes azureVoiceResponseBytesLimit=$AzureVoiceResponseMaxBytes audioCatalogEntriesLimit=$AudioOutputCatalogMaxEntries audioCatalogBytesLimit=$AudioOutputCatalogMaxBytes commandIpcBytesLimit=$CommandIpcMaxBytes sequenceIpcBytesLimit=$SequenceIpcMaxBytes azureChildOwnerWatch=true azureSecretAtomic=true azureSecretBackup=true sharedLogMutex=$script:SharedLogMutexState helperHeartbeat=$script:HeartbeatState heartbeatAtomic=true helperIdlePollMs=$HelperIdlePollIntervalMs helperActivePollMs=$HelperActivePollIntervalMs gameLivenessMs=$GameLivenessIntervalMs sequenceChangeGate=lastWriteUtc sequenceFallbackReadMs=$SequenceFallbackReadIntervalMs tls12Compatibility=$script:Tls12Compatibility"

    if ($bindingMode -eq 'exact-pid') {
        Write-HelperLog "helper started; mode=exact-pid helperPid=$PID helperStartFileTimeUtc=$helperStartFileTimeUtc gamePid=$gameProcessId game=$gameProcessName systemDefault=$systemDefaultVoice voice=$activeVoice; rate=$($ttsConfig.Rate); volume=$($ttsConfig.Volume); pitch=$($ttsConfig.Pitch); style=$($ttsConfig.VoiceStyle); backend=$activeBackend; audioOutput=$($speechStatus.OutputName); azureKey=$(Get-AzureKeySource); azureRegion=$($ttsConfig.AzureRegion) pronunciationEnabled=$(([bool]$ttsConfig.PronunciationCorrections).ToString().ToLowerInvariant())"
    } else {
        Write-HelperLog "helper started; mode=fallback-name helperPid=$PID helperStartFileTimeUtc=$helperStartFileTimeUtc gamePid=0 systemDefault=$systemDefaultVoice voice=$activeVoice; rate=$($ttsConfig.Rate); volume=$($ttsConfig.Volume); pitch=$($ttsConfig.Pitch); style=$($ttsConfig.VoiceStyle); backend=$activeBackend; audioOutput=$($speechStatus.OutputName); azureKey=$(Get-AzureKeySource); azureRegion=$($ttsConfig.AzureRegion) pronunciationEnabled=$(([bool]$ttsConfig.PronunciationCorrections).ToString().ToLowerInvariant())"
    }

    $lastSequence = ''
    $lastCommandReadError = ''
    $gameRunning = $true
    $nextGameLivenessCheckUtc = [DateTime]::UtcNow
    $lastSequenceWriteTicks = [int64]-1
    $nextSequenceFallbackReadUtc = [DateTime]::UtcNow
    $loopIterations = 0
    $gameLivenessChecks = 0
    $sequenceStampChecks = 0
    $sequenceReads = 0
    $sequenceFallbackReads = 0
    $activeWaits = 0
    $idleWaits = 0
    Write-HelperLog "helper loop cadence idleMs=$HelperIdlePollIntervalMs activeMs=$HelperActivePollIntervalMs gameLivenessMs=$GameLivenessIntervalMs sequenceChangeGate=lastWriteUtc fallbackReadMs=$SequenceFallbackReadIntervalMs"

    while ($true) {
        $loopIterations++
        $loopNowUtc = [DateTime]::UtcNow
        $null = Write-HelperHeartbeat

        # Process enumeration/start-time validation is comparatively expensive in
        # Windows PowerShell. It only needs to bound orphan-helper lifetime, not run
        # at narration-poll cadence. Cache the exact-PID result for up to one second.
        if ($loopNowUtc -ge $nextGameLivenessCheckUtc) {
            $gameLivenessChecks++
            $nextGameLivenessCheckUtc = $loopNowUtc.AddMilliseconds($GameLivenessIntervalMs)
            $gameRunning = $false
            if ($bindingMode -eq 'exact-pid') {
                try {
                    $liveGame = Get-Process -Id $gameProcessId -ErrorAction Stop
                    $sameName = $GameProcessNames -contains [string]$liveGame.ProcessName

                    if ($sameName) {
                        if ($null -ne $gameStartFileTimeUtc) {
                            $liveStartFileTimeUtc = $liveGame.StartTime.ToUniversalTime().ToFileTimeUtc()
                            $gameRunning = ($liveStartFileTimeUtc -eq $gameStartFileTimeUtc)
                        } else {
                            $gameRunning = $true
                        }
                    }
                } catch {
                    $gameRunning = $false
                }
            } else {
                $gameRunning = Test-AnyGameRunning
            }
        }

        if (-not $gameRunning) {
            if ($bindingMode -eq 'exact-pid') {
                Write-HelperLog "bound game process ended; gamePid=$gameProcessId; helper exiting"
            } else {
                Write-HelperLog 'game process ended; fallback helper exiting'
            }
            break
        }

        try {
            $sequenceStampChecks++
            $sequenceWriteTicks = [int64]-1
            try {
                if ([IO.File]::Exists($SequencePath)) {
                    $sequenceWriteTicks = [IO.File]::GetLastWriteTimeUtc($SequencePath).Ticks
                }
            } catch { $sequenceWriteTicks = [int64]-1 }

            # Lua atomically replaces the sequence snapshot after publishing the
            # command payload. Avoid reopening and decoding an unchanged file on every
            # helper wake. The bounded 500 ms forced-read fallback still retries a
            # transient/incomplete IPC snapshot even when its timestamp is unchanged.
            $sequenceStampChanged = ($sequenceWriteTicks -ge 0 -and $sequenceWriteTicks -ne $lastSequenceWriteTicks)
            $sequenceFallbackDue = ($loopNowUtc -ge $nextSequenceFallbackReadUtc)
            if ($sequenceWriteTicks -ge 0 -and ($sequenceStampChanged -or $sequenceFallbackDue)) {
                if ($sequenceFallbackDue -and -not $sequenceStampChanged) { $sequenceFallbackReads++ }
                $nextSequenceFallbackReadUtc = $loopNowUtc.AddMilliseconds($SequenceFallbackReadIntervalMs)
                $sequenceReads++
                # Lua publishes sequence IPC by removing the old destination and renaming
                # a complete .tmp snapshot. The remove/rename gap can race this read after
                # the timestamp probe. Treat only that transient missing-file window as an
                # empty snapshot so the normal fallback poll retries it without inflating
                # CommandReadErrors; all other shared-file failures still fail closed.
                $sequence = (Read-SharedUtf8Text $SequencePath $SequenceIpcMaxBytes 'tts sequence IPC' $true).Trim()
                $lastSequenceWriteTicks = $sequenceWriteTicks
                if ($sequence -ne '' -and $sequence -notmatch '^\d{1,20}$') {
                    if ($sequence -ne $lastSequence) {
                        $lastSequence = $sequence
                        Write-HelperLog 'invalid TTS sequence snapshot ignored'
                    }
                } elseif ($sequence -ne '' -and $sequence -ne $lastSequence) {
                    if (Test-Path -LiteralPath $CommandPath) {
                        $payload = Read-SharedUtf8Text $CommandPath $CommandIpcMaxBytes 'tts command IPC'
                        $lastCommandReadError = ''
                        # Do not acknowledge a sequence until its complete command snapshot
                        # has been opened successfully. A transient IPC read can then retry.
                        $lastSequence = $sequence
                        $newline = $payload.IndexOf("`n")
                        if ($newline -ge 0) {
                            $command = $payload.Substring(0, $newline).Trim()
                            $text = $payload.Substring($newline + 1).TrimEnd([char[]]"`r`n")
                        } else {
                            $command = $payload.Trim()
                            $text = ''
                        }
                        Add-SessionStat 'Commands'

                        if ($command -eq 'SPEAK' -or $command -eq 'TEST') {
                            $text = Limit-SpeechText $text $command
                        }

                        if ($command -eq 'SPEAK') {
                            Add-SessionStat 'SpeakRequests'
                            $ttsConfig = Get-TTSConfig
                            $queueMode = [string]$ttsConfig.SpeechQueue
                            $speechActive = Test-SpeechActive $synth $sapi $azureProcess

                            if ($queueMode -eq 'queue') {
                                if ($speechActive -or $speechQueue.Count -gt 0) {
                                    if ($speechQueue.Count -lt $speechQueueLimit) {
                                        $speechQueue.Enqueue([PSCustomObject]@{ Text = [string]$text; Sequence = [string]$sequence })
                                        Add-SessionStat 'QueueEnqueued'
                                        Write-HelperLog "speech queued seq=$sequence position=$($speechQueue.Count) limit=$speechQueueLimit chars=$($text.Length)"
                                    } else {
                                        Add-SessionStat 'QueueDropped'
                                        Write-HelperLog "speech queue full; dropped seq=$sequence limit=$speechQueueLimit chars=$($text.Length)"
                                    }
                                } else {
                                    $null = Invoke-SpeechItem $text $sequence $synth $sapi $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId ([ref]$speechStatus) ([ref]$azureProcess) ([ref]$azureRequestPath) ([ref]$azureVoiceCount) ([ref]$lastAzureRegion) ([ref]$lastEngine)
                                }
                            } elseif ($queueMode -eq 'ignore') {
                                Clear-SpeechQueue $speechQueue 'ignore-mode synchronization'
                                if ($speechActive) {
                                    Add-SessionStat 'IgnoreDropped'
                                    Write-HelperLog "speech ignored while active seq=$sequence chars=$($text.Length)"
                                } else {
                                    $null = Invoke-SpeechItem $text $sequence $synth $sapi $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId ([ref]$speechStatus) ([ref]$azureProcess) ([ref]$azureRequestPath) ([ref]$azureVoiceCount) ([ref]$lastAzureRegion) ([ref]$lastEngine)
                                }
                            } else {
                                Clear-SpeechQueue $speechQueue 'interrupt-mode request'
                                Stop-AllSpeech $synth $sapi
                                Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                                $null = Invoke-SpeechItem $text $sequence $synth $sapi $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId ([ref]$speechStatus) ([ref]$azureProcess) ([ref]$azureRequestPath) ([ref]$azureVoiceCount) ([ref]$lastAzureRegion) ([ref]$lastEngine)
                            }
                        } elseif ($command -eq 'STOP') {
                            Add-SessionStat 'StopCommands'
                            Clear-SpeechQueue $speechQueue 'STOP command'
                            Stop-AllSpeech $synth $sapi
                            Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                            $speechStartGuardUntil = [DateTime]::MinValue
                            Write-HelperLog "stop seq=$sequence"
                        } elseif ($command -eq 'CONFIG') {
                            Add-SessionStat 'ConfigCommands'
                            Clear-SpeechQueue $speechQueue 'CONFIG command'
                            Stop-AllSpeech $synth $sapi
                            Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                            $previousRegion = $lastAzureRegion
                            $previousEngine = $lastEngine
                            $ttsConfig = Get-TTSConfig
                            if ($null -ne $sapi) { $null = Publish-AudioOutputList $sapi }
                            $speechStatus = Configure-SpeechBackends $synth $sapi $ttsConfig $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId
                            $lastAzureRegion = [string]$ttsConfig.AzureRegion
                            $lastEngine = [string]$ttsConfig.Engine
                            if ((Get-AzureKeySource) -ne 'missing' -and ($lastAzureRegion -ne $previousRegion -or ($lastEngine -eq 'azure' -and $previousEngine -ne 'azure'))) {
                                $refreshed = Publish-AzureVoiceList $ttsConfig
                                if ($refreshed -ge 0) { $azureVoiceCount = $refreshed }
                            }
                            Publish-EngineStatus $ttsConfig $azureVoiceCount 'Configuration applied'
                            $activeBackend = if ($ttsConfig.Engine -eq 'azure') { 'azure_stream' } else { $speechStatus.Backend }
                            $activeVoice = if ($ttsConfig.Engine -eq 'azure') { [string]$ttsConfig.AzureVoice } else { [string]$speechStatus.VoiceName }
                            Write-HelperLog "config seq=$sequence voice=$activeVoice rate=$($ttsConfig.Rate) volume=$($ttsConfig.Volume) pitch=$($ttsConfig.Pitch) style=$($ttsConfig.VoiceStyle) backend=$activeBackend audioOutput=$($speechStatus.OutputName) azureKey=$(Get-AzureKeySource) azureRegion=$($ttsConfig.AzureRegion)"
                        } elseif ($command -eq 'TEST_VOICE') {
                            Add-SessionStat 'PreviewRequests'
                            Clear-SpeechQueue $speechQueue 'voice preview'
                            Stop-AllSpeech $synth $sapi
                            Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                            $parts = @($text -split "`n", 6)
                            $previewVoice = if ($parts.Count -gt 0) { ([string]$parts[0]).Trim() } else { '' }
                            $ttsConfig = Get-TTSConfig
                            $previewText = $VoicePreviewText
                            if ($parts.Count -ge 6) {
                                $parsedRate = 0
                                if ([int]::TryParse(([string]$parts[1]).Trim(), [ref]$parsedRate)) { $ttsConfig.Rate = [Math]::Max(-10, [Math]::Min(10, $parsedRate)) }
                                $parsedVolume = 100
                                if ([int]::TryParse(([string]$parts[2]).Trim(), [ref]$parsedVolume)) { $ttsConfig.Volume = [Math]::Max(0, [Math]::Min(100, $parsedVolume)) }
                                $parsedPitch = 0
                                if ([int]::TryParse(([string]$parts[3]).Trim(), [ref]$parsedPitch)) { $ttsConfig.Pitch = [Math]::Max(-6, [Math]::Min(6, $parsedPitch)) }
                                $previewStyle = ([string]$parts[4]).Trim()
                                $ttsConfig.VoiceStyle = if ([string]::IsNullOrWhiteSpace($previewStyle)) { 'default' } else { $previewStyle }
                                $previewText = [string]$parts[5]
                            } elseif ($parts.Count -gt 1) {
                                $previewText = [string]$parts[1]
                                $ttsConfig.VoiceStyle = 'default'
                            }
                            $previewText = Limit-SpeechText $previewText 'TEST_VOICE'
                            if ($ttsConfig.Engine -eq 'azure') { $ttsConfig.AzureVoice = $previewVoice; $ttsConfig = Normalize-AzureVoiceStyle $ttsConfig } else { $ttsConfig.Voice = $previewVoice }
                            $speechStatus = Configure-SpeechBackends $synth $sapi $ttsConfig $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId
                            if ($ttsConfig.Engine -eq 'azure') {
                                $started = Start-AzureStream $ttsConfig $sapi $previewText $sequence ([ref]$azureProcess) ([ref]$azureRequestPath) ([bool]($previewText -ceq $VoicePreviewText))
                                if ($started) { Write-HelperLog "browser preview seq=$sequence voice=$($ttsConfig.AzureVoice) pitch=$($ttsConfig.Pitch) style=$($ttsConfig.VoiceStyle) backend=azure_stream chars=$($previewText.Length)" }
                            } else {
                                $previewSpoken = Speak-Active $synth $sapi $speechStatus $previewText $ttsConfig $sapiSystemDefaultVoiceId
                                if ($previewSpoken) {
                                    Write-HelperLog "browser preview seq=$sequence voice=$($speechStatus.VoiceName) pitch=$($ttsConfig.Pitch) backend=$($speechStatus.Backend) chars=$($previewText.Length)"
                                } else {
                                    Write-HelperLog "browser preview failed seq=$sequence backend=$($speechStatus.Backend) chars=$($previewText.Length)"
                                }
                            }
                        } elseif ($command -eq 'TEST') {
                            Add-SessionStat 'TestRequests'
                            Clear-SpeechQueue $speechQueue 'voice test'
                            Stop-AllSpeech $synth $sapi
                            Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                            $previousRegion = $lastAzureRegion
                            $previousEngine = $lastEngine
                            $ttsConfig = Get-TTSConfig
                            $azureContextChanged = (([string]$ttsConfig.AzureRegion -ne $previousRegion) -or (([string]$ttsConfig.Engine -eq 'azure') -and $previousEngine -ne 'azure'))
                            if ((Get-AzureKeySource) -ne 'missing' -and $azureContextChanged) {
                                $refreshed = Publish-AzureVoiceList $ttsConfig
                                if ($refreshed -ge 0) { $azureVoiceCount = $refreshed }
                            }
                            if ($ttsConfig.Engine -eq 'azure') {
                                $ttsConfig = Resolve-AzureVoiceFromCatalog $ttsConfig
                                $ttsConfig = Normalize-AzureVoiceStyle $ttsConfig
                            }
                            $speechStatus = Configure-SpeechBackends $synth $sapi $ttsConfig $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId
                            $lastAzureRegion = [string]$ttsConfig.AzureRegion
                            $lastEngine = [string]$ttsConfig.Engine
                            Publish-EngineStatus $ttsConfig $azureVoiceCount 'Configuration synchronized for voice test.'
                            if ([string]::IsNullOrWhiteSpace($text)) { $text = $VoicePreviewText }
                            if ($ttsConfig.Engine -eq 'azure') {
                                $started = Start-AzureStream $ttsConfig $sapi $text $sequence ([ref]$azureProcess) ([ref]$azureRequestPath) ([bool]($text -ceq $VoicePreviewText))
                                if ($started) { Write-HelperLog "test seq=$sequence voice=$($ttsConfig.AzureVoice) rate=$($ttsConfig.Rate) volume=$($ttsConfig.Volume) pitch=$($ttsConfig.Pitch) style=$($ttsConfig.VoiceStyle) backend=azure_stream audioOutput=$($speechStatus.OutputName) chars=$($text.Length)" }
                            } else {
                                $testSpoken = Speak-Active $synth $sapi $speechStatus $text $ttsConfig $sapiSystemDefaultVoiceId
                                if ($testSpoken) {
                                    Write-HelperLog "test seq=$sequence voice=$($speechStatus.VoiceName) rate=$($ttsConfig.Rate) volume=$($ttsConfig.Volume) pitch=$($ttsConfig.Pitch) backend=$($speechStatus.Backend) audioOutput=$($speechStatus.OutputName) chars=$($text.Length)"
                                } else {
                                    Write-HelperLog "test failed seq=$sequence backend=$($speechStatus.Backend) chars=$($text.Length)"
                                }
                            }
                        } elseif ($command -eq 'AZURE_KEY_CLIPBOARD') {
                            Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                            $clipboard = Get-ClipboardTextSafe
                            $cleanKey = Test-AzureKeyValue $clipboard
                            if ([string]::IsNullOrWhiteSpace($cleanKey)) {
                                Publish-EngineStatus $ttsConfig $azureVoiceCount 'Clipboard does not contain a plausible Azure Speech key.'
                                Write-HelperLog "Azure key clipboard import rejected; no key value logged"
                            } else {
                                Protect-AzureKey $cleanKey
                                $cleared = Clear-ClipboardIfMatches $cleanKey
                                $refreshed = Publish-AzureVoiceList $ttsConfig
                                if ($refreshed -lt 0) {
                                    $azureVoiceCount = Get-AzureVoiceCatalogCount
                                    $message = if ($cleared) { 'Azure key stored with Windows DPAPI and clipboard cleared, but Azure voice refresh failed. Verify key and region.' } else { 'Azure key stored with Windows DPAPI, but Azure voice refresh failed. Verify key and region.' }
                                } else {
                                    $azureVoiceCount = $refreshed
                                    $message = if ($cleared) { 'Azure key stored with Windows DPAPI. Current clipboard cleared.' } else { 'Azure key stored with Windows DPAPI. Clipboard could not be cleared.' }
                                }
                                Publish-EngineStatus $ttsConfig $azureVoiceCount $message
                                Write-HelperLog "Azure key imported from clipboard; storage=DPAPI CurrentUser clipboardCleared=$cleared voices=$azureVoiceCount refreshOk=$($refreshed -ge 0)"
                                $cleanKey = $null
                            }
                        } elseif ($command -eq 'AZURE_KEY_CLEAR') {
                            Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)
                            try { Remove-Item -LiteralPath $AzureSecretPath -Force -ErrorAction SilentlyContinue } catch {}
                            try { Remove-Item -LiteralPath $AzureSecretBackupPath -Force -ErrorAction SilentlyContinue } catch {}
                            try { [IO.File]::WriteAllText($AzureVoiceListPath, '', $Utf8NoBom) } catch {}
                            $azureVoiceCount = 0
                            Publish-EngineStatus $ttsConfig $azureVoiceCount 'Stored Azure key cleared.'
                            Write-HelperLog 'Azure DPAPI key store cleared'
                        } elseif ($command -eq 'AZURE_REFRESH') {
                            $ttsConfig = Get-TTSConfig
                            $refreshed = Publish-AzureVoiceList $ttsConfig
                            if ($refreshed -ge 0) { $azureVoiceCount = $refreshed }
                            Publish-EngineStatus $ttsConfig $azureVoiceCount $(if ($refreshed -ge 0) {'Azure voice list refreshed.'} else {'Azure voice-list refresh failed. Check helper log.'})
                        } else {
                            Write-HelperLog "unknown TTS IPC command ignored seq=$sequence"
                        }
                    }
                }
            }
        } catch {
            $commandReadError = "command read error: $($_.Exception.Message)"
            if ($commandReadError -ne $lastCommandReadError) {
                Add-SessionStat 'CommandReadErrors'
                Write-HelperLog $commandReadError
                $lastCommandReadError = $commandReadError
            }
        }

        if ($null -ne $azureProcess) {
            try {
                if ($azureProcess.HasExited) {
                    $azureExitCode = 0
                    try { $azureExitCode = [int]$azureProcess.ExitCode } catch {}
                    if ($azureExitCode -ne 0) {
                        Add-SessionStat 'AzureChildFailures'
                        Write-HelperLog "Azure stream process exited with code $azureExitCode; see azure-stream log lines above"
                    }
                    try { $azureProcess.Dispose() } catch {}
                    $azureProcess = $null
                    if (-not [string]::IsNullOrWhiteSpace([string]$azureRequestPath)) {
                        try { Remove-Item -LiteralPath $azureRequestPath -Force -ErrorAction SilentlyContinue } catch {}
                    }
                    $azureRequestPath = $null
                }
            } catch {}
        }

        if ($speechQueue.Count -gt 0 -and -not (Test-SpeechActive $synth $sapi $azureProcess)) {
            try {
                $nextSpeech = $speechQueue.Dequeue()
                Add-SessionStat 'QueueAdvanced'
                Write-HelperLog "speech queue advancing seq=$($nextSpeech.Sequence) remaining=$($speechQueue.Count) chars=$(([string]$nextSpeech.Text).Length)"
                $null = Invoke-SpeechItem ([string]$nextSpeech.Text) ([string]$nextSpeech.Sequence) $synth $sapi $voiceNames $systemDefaultVoice $sapiSystemDefaultVoiceId ([ref]$speechStatus) ([ref]$azureProcess) ([ref]$azureRequestPath) ([ref]$azureVoiceCount) ([ref]$lastAzureRegion) ([ref]$lastEngine)
            } catch {
                Write-HelperLog ("speech queue advance failed; " + (Get-ExceptionSignature $_.Exception))
            }
        }

        $helperLoopDelayMs = $HelperIdlePollIntervalMs
        if ($speechQueue.Count -gt 0 -or $null -ne $azureProcess) {
            $helperLoopDelayMs = $HelperActivePollIntervalMs
            $activeWaits++
        } else {
            $idleWaits++
        }
        Start-Sleep -Milliseconds $helperLoopDelayMs
    }
} catch {
    $fatalLine = 0
    $fatalCommand = ''
    $fatalErrorId = ''
    try { $fatalLine = [int]$_.InvocationInfo.ScriptLineNumber } catch {}
    try { $fatalCommand = [string]$_.InvocationInfo.MyCommand.Name } catch {}
    try { $fatalErrorId = [string]$_.FullyQualifiedErrorId } catch {}
    Write-HelperLog ("fatal helper exception; " + (Get-ExceptionSignature $_.Exception) + " line=$fatalLine command=$fatalCommand errorId=$fatalErrorId")
} finally {
    Stop-AllSpeech $synth $sapi
    Stop-AzureStream ([ref]$azureProcess) ([ref]$azureRequestPath)

    # tts_command.txt is live IPC and can contain the most recent narration text.
    # Once this helper is terminating it is no longer needed; remove command and
    # sequence snapshots so a normal game exit does not leave narration on disk.
    # Lua writes a fresh STOP/sequence before launching the helper next session.
    try { Remove-Item -LiteralPath $CommandPath -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $SequencePath -Force -ErrorAction SilentlyContinue } catch {}
    $heartbeatRemoved = Remove-OwnHelperHeartbeat
    Write-HelperLog "helper heartbeat cleanup removed=$heartbeatRemoved atomicSnapshot=true"

    $sessionDurationSeconds = 0
    try { $sessionDurationSeconds = [Math]::Max(0, [int][Math]::Round(([DateTime]::UtcNow - $script:SessionStartUtc).TotalSeconds)) } catch {}
    Write-HelperLog ("session health durationSeconds={0} commands={1} speakRequests={2} testRequests={3} previewRequests={4} stopCommands={5} configCommands={6} localStarts={7} azureStarts={8} queueEnqueued={9} queueAdvanced={10} queueDropped={11} ignoreDropped={12} sapiFallbacks={13} audioFallbacks={14} azureChildFailures={15} commandReadErrors={16} loopIterations={17} gameLivenessChecks={18} sequenceStampChecks={19} sequenceReads={20} sequenceFallbackReads={21} activeWaits={22} idleWaits={23} pronunciationLoads={24} pronunciationApplied={25} pronunciationReplacements={26} pronunciationErrors={27}" -f $sessionDurationSeconds,[int]$script:SessionStats.Commands,[int]$script:SessionStats.SpeakRequests,[int]$script:SessionStats.TestRequests,[int]$script:SessionStats.PreviewRequests,[int]$script:SessionStats.StopCommands,[int]$script:SessionStats.ConfigCommands,[int]$script:SessionStats.LocalStarts,[int]$script:SessionStats.AzureStarts,[int]$script:SessionStats.QueueEnqueued,[int]$script:SessionStats.QueueAdvanced,[int]$script:SessionStats.QueueDropped,[int]$script:SessionStats.IgnoreDropped,[int]$script:SessionStats.SapiFallbacks,[int]$script:SessionStats.AudioFallbacks,[int]$script:SessionStats.AzureChildFailures,[int]$script:SessionStats.CommandReadErrors,[int]$loopIterations,[int]$gameLivenessChecks,[int]$sequenceStampChecks,[int]$sequenceReads,[int]$sequenceFallbackReads,[int]$activeWaits,[int]$idleWaits,[int]$script:SessionStats.PronunciationLoads,[int]$script:SessionStats.PronunciationApplied,[int]$script:SessionStats.PronunciationReplacements,[int]$script:SessionStats.PronunciationErrors)
    Write-HelperLog "helper shutdown cleanup complete mode=$bindingMode gamePid=$gameProcessId"

    if ($null -ne $synth) {
        try { $synth.Dispose() } catch {}
    }

    if ($null -ne $sapi) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($sapi) } catch {}
        $sapi = $null
    }

    if ($null -ne $script:LogMutex) {
        try { $script:LogMutex.Dispose() } catch {}
        $script:LogMutex = $null
    }

    if ($null -ne $mutex) {
        if ($createdNew) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        try { $mutex.Dispose() } catch {}
    }
}
