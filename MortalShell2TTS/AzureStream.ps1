# MortalShell2TTS Azure streaming child - v0.9.260 Pass 183 shared-controller-contract metadata; ordinary narration path unchanged
# Pass 84 leaves the Pass-83 capability-aware IPA/fallback transport unchanged; TTSHelper now decides whether normalization is enabled before this child is launched.
# Pass 83 keeps the bounded IPA marker/SSML transport intact. TTSHelper now sends phoneme mappings only for selected voice families classified as supporting <phoneme>; unsupported/unknown voices receive plain-text fallback before this child starts. Executable source remains ASCII-only for Windows PowerShell 5.1.
param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$SecretPath,
    [Parameter(Mandatory=$true)][string]$LogPath,
    [Parameter(Mandatory=$false)][int]$ParentHelperPid = 0,
    [Parameter(Mandatory=$false)][long]$ParentHelperStartFileTimeUtc = 0,
    [Parameter(Mandatory=$false)][int]$GameProcessId = 0,
    [Parameter(Mandatory=$false)][long]$GameStartFileTimeUtc = 0
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$EntropyText = 'MortalShell2TTS.AzureSpeech.v1'
$PlayerCacheDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MortalShell2TTS'
$PlayerAssembly = Join-Path $PlayerCacheDir 'AzureWaveOutPlayer.v1.dll'
$PlayerHashPath = $PlayerAssembly + '.sha256'
$LogMaxEntryChars = 4096
$LogMaxBytes = 2MB
$LogGenerations = 2
$LogMutexName = 'Local\MortalShell2TTS_Log_v1'
$script:LogMutex = $null
$SpeechTextLimitChars = 65536
$SecretFileMaxBytes = 65536
$AzureAudioMaxBytes = 256MB
$AzureStreamReadTimeoutMs = 30000
$AzureHttpMaxAttempts = 2
$AzureRetryDefaultDelayMs = 450
$AzureRetryMaxDelayMs = 2000
$OwnerCheckIntervalMs = 250
$script:NextOwnerCheckUtc = [DateTime]::MinValue

function ConvertTo-SafeAzureLogText([string]$Message) {
    if ($null -eq $Message) { return '' }
    $safe = [string]$Message
    try {
        $replacements = @(
            @([string]$PSScriptRoot, '<MOD_DIR>'),
            @([string]$PlayerCacheDir, '<TTS_DATA>'),
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
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(Azure(?:Speech)?Key\s*[:=]\s*)[A-Za-z0-9+/=_-]{24,}', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)([?&](?:sig|key|token|code)=)[^&\s]+', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?i)(DPAPI(?:Blob)?\s*[:=]\s*)[A-Za-z0-9+/=_-]{24,}', '$1<REDACTED>')
        $safe = [Text.RegularExpressions.Regex]::Replace($safe, '(?is)<speak\b.*?</speak>', '<SSML_REDACTED>')
    } catch {}
    $safe = ($safe -replace '[\r\n]+', ' ')
    if ($safe.Length -gt $LogMaxEntryChars) { $safe = $safe.Substring(0, $LogMaxEntryChars) + '...[truncated]' }
    return $safe
}

function Enable-AzureTls12Compatibility {
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

$script:Tls12Compatibility = Enable-AzureTls12Compatibility

function Get-AzureExceptionSignature($Exception) {
    if ($null -eq $Exception) { return 'type=Unknown hresult=unknown' }
    $typeName = 'Exception'
    $hresult = 'unknown'
    try { $typeName = [string]$Exception.GetType().FullName } catch {}
    try { $hresult = ('0x{0:X8}' -f ([uint32]$Exception.HResult)) } catch {}
    return ('type=' + $typeName + ' hresult=' + $hresult)
}

function Get-FriendlyAzureException($Exception) {
    if ($null -eq $Exception) { return 'Azure synthesis failed for an unknown reason.' }

    # Preserve only messages generated by this child itself. PowerShell wraps
    # `throw 'text'` as RuntimeException, so without this allow-list HTTP 401/429,
    # invalid request/cache states, etc. degraded into an unhelpful generic
    # RuntimeException signature. The allow-list contains no narration payload.
    try {
        $controlled = ([string]$Exception.Message).Replace("`r", ' ').Replace("`n", ' ').Trim()
        if ($controlled -match '^(?i:Azure synthesis .+\bHTTP\s+\d{3}\b|Azure Speech key .+|Azure WinMM player .+|Timed out waiting for another MortalShell2TTS Azure player-cache build .+|Runtime C# compilation for Azure playback .+|Compiled Azure player .+|expected AzureWaveOutPlayer type .+|Azure stream request .+|Azure Speech region is invalid\.|Azure Speech voice is invalid\.|Azure Speech style value is invalid\.|Azure audio output name exceeded .+|Azure narration request exceeded .+|Azure audio response exceeded .+|Azure stream read timed out .+|Azure Speech key store exceeded .+|Azure stream canceled because .+|Azure pronunciation .+|Azure synthesis request did not return .+|Azure synthesis returned a successful response but no audio bytes\.)') {
            return $controlled
        }
    } catch {}

    $cursor = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $cursor; $depth++) {
        $typeName = ''
        $message = ''
        try { $typeName = [string]$cursor.GetType().FullName } catch {}
        try { $message = ([string]$cursor.Message).Replace("`r", ' ').Replace("`n", ' ').Trim() } catch {}
        if ($typeName -match 'InvalidOperationException' -and $message -match '^waveOutOpen failed') {
            return 'Azure playback could not open the requested Windows audio output. Reconnect/select another output or use System Default. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'InvalidOperationException' -and $message -match '^waveOutPrepareHeader failed') {
            return 'Azure playback could not prepare an audio buffer for Windows waveOut. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'InvalidOperationException' -and $message -match '^waveOutWrite failed') {
            return 'Azure playback could not send an audio buffer to Windows waveOut. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'ObjectDisposedException') {
            return 'Azure playback ended while the Windows audio output was shutting down. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'TaskCanceledException|OperationCanceledException') {
            return 'Azure synthesis timed out or was canceled before the service completed the request.'
        }
        if ($typeName -match 'HttpRequestException') {
            return 'Azure synthesis could not reach the Speech service. Check internet access, DNS, proxy/firewall rules, TLS, and the configured Azure region. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'WebException') {
            $status = ''
            try { $status = [string]$cursor.Status } catch {}
            $statusText = if ($status -ne '') { ' status=' + $status } else { '' }
            return 'Azure synthesis network request failed' + $statusText + '. Check internet/proxy/firewall connectivity. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'SocketException') {
            return 'Azure synthesis network/DNS connection failed. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'CryptographicException|FormatException') {
            return 'Stored Azure Speech credentials could not be decoded/decrypted for the current Windows user. Re-import the Azure key. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'UnauthorizedAccessException') {
            return 'Azure playback could not access a required local file/cache path. Check Windows permissions or security software. ' + (Get-AzureExceptionSignature $cursor)
        }
        if ($typeName -match 'SecurityException') {
            return 'Azure playback was blocked by a Windows/PowerShell security policy. Windows/local TTS remains available. ' + (Get-AzureExceptionSignature $cursor)
        }
        try { $cursor = $cursor.InnerException } catch { $cursor = $null }
    }
    return 'Azure synthesis failed; ' + (Get-AzureExceptionSignature $Exception)
}

function Test-ProcessIdentityAlive([int]$ProcessId, [long]$ExpectedStartFileTimeUtc) {
    if ($ProcessId -le 0) { return $true }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($null -eq $process -or $process.HasExited) { return $false }
        if ($ExpectedStartFileTimeUtc -gt 0) {
            $actualStart = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
            if ([long]$actualStart -ne [long]$ExpectedStartFileTimeUtc) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Assert-OwnerAlive([string]$Stage, [bool]$Force = $false) {
    $now = [DateTime]::UtcNow
    if (-not $Force -and $now -lt $script:NextOwnerCheckUtc) { return }
    $script:NextOwnerCheckUtc = $now.AddMilliseconds($OwnerCheckIntervalMs)

    if ($ParentHelperPid -gt 0 -and -not (Test-ProcessIdentityAlive $ParentHelperPid $ParentHelperStartFileTimeUtc)) {
        throw ('Azure stream canceled because parent helper ended stage=' + $Stage + '.')
    }
    if ($GameProcessId -gt 0 -and -not (Test-ProcessIdentityAlive $GameProcessId $GameStartFileTimeUtc)) {
        throw ('Azure stream canceled because bound game process ended stage=' + $Stage + '.')
    }
}

function Get-SharedAzureLogMutex {
    if ($null -ne $script:LogMutex) { return $script:LogMutex }
    try { $script:LogMutex = New-Object System.Threading.Mutex($false, $LogMutexName) } catch { $script:LogMutex = $null }
    return $script:LogMutex
}

function Invoke-WithSharedAzureLogMutex([scriptblock]$Action) {
    $mutex = Get-SharedAzureLogMutex
    $acquired = $false
    try {
        if ($null -ne $mutex) {
            try { $acquired = $mutex.WaitOne(2000) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            catch { $acquired = $false }
            if (-not $acquired) { return $false }
        }
        & $Action
        return $true
    } finally {
        if ($acquired -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
    }
}

function Rotate-AzureSharedLogIfNeeded([int64]$IncomingBytes = 0) {
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) { return }
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

function Write-AzureLog([string]$Message) {
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $safe = ConvertTo-SafeAzureLogText $Message
        $line = "[$stamp] azure-stream $safe`r`n"
        $lineBytes = [Text.Encoding]::UTF8.GetByteCount($line)
        [void](Invoke-WithSharedAzureLogMutex {
            Rotate-AzureSharedLogIfNeeded $lineBytes
            [IO.File]::AppendAllText($LogPath, $line, [Text.Encoding]::UTF8)
        })
    } catch {
    }
}

function Get-TextSha256([string]$Text) {
    $sha = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $sha) { try { $sha.Dispose() } catch {} }
    }
}

function Get-FriendlyAzureHttpFailure([int]$StatusCode, [string]$Reason) {
    switch ($StatusCode) {
        400 { return 'Azure synthesis rejected the request (HTTP 400). Check the selected voice/style/region.' }
        401 { return 'Azure synthesis authentication failed (HTTP 401). The Speech key is invalid or not authorized.' }
        403 { return 'Azure synthesis was forbidden (HTTP 403). Check the Speech resource, key permissions, and region.' }
        404 { return 'Azure synthesis endpoint/voice was not found (HTTP 404). Check region and selected voice.' }
        408 { return 'Azure synthesis timed out at the service (HTTP 408). Check connectivity and retry.' }
        429 { return 'Azure synthesis was throttled (HTTP 429). Wait briefly before retrying.' }
        500 { return 'Azure synthesis service returned HTTP 500. Retry later.' }
        502 { return 'Azure synthesis service returned HTTP 502. Retry later.' }
        503 { return 'Azure synthesis service is temporarily unavailable (HTTP 503). Retry later.' }
        504 { return 'Azure synthesis timed out upstream (HTTP 504). Retry later.' }
        default {
            $clean = ([string]$Reason).Replace("`r", ' ').Replace("`n", ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($clean)) { return "Azure synthesis failed with HTTP $StatusCode." }
            return "Azure synthesis failed with HTTP $StatusCode $clean."
        }
    }
}


function Test-RetriableAzureHttpStatus([int]$StatusCode) {
    return ($StatusCode -eq 408 -or $StatusCode -eq 429 -or $StatusCode -eq 500 -or $StatusCode -eq 502 -or $StatusCode -eq 503 -or $StatusCode -eq 504)
}

function Test-RetriableAzureException($Exception) {
    $cursor = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $cursor; $depth++) {
        $typeName = ''
        try { $typeName = [string]$cursor.GetType().FullName } catch {}
        if ($typeName -match 'HttpRequestException|WebException|SocketException|TaskCanceledException|TimeoutException') { return $true }
        try { $cursor = $cursor.InnerException } catch { $cursor = $null }
    }
    return $false
}

function Get-AzureRetryDelayMs($Response) {
    $delay = [int]$AzureRetryDefaultDelayMs
    if ($null -ne $Response) {
        try {
            $retryAfter = $Response.Headers.RetryAfter
            if ($null -ne $retryAfter) {
                if ($null -ne $retryAfter.Delta) {
                    $delay = [int][Math]::Ceiling($retryAfter.Delta.TotalMilliseconds)
                } elseif ($null -ne $retryAfter.Date) {
                    $delay = [int][Math]::Ceiling(($retryAfter.Date.UtcDateTime - [DateTime]::UtcNow).TotalMilliseconds)
                }
            }
        } catch {}
    }
    if ($delay -lt 100) { $delay = 100 }
    if ($delay -gt $AzureRetryMaxDelayMs) { $delay = $AzureRetryMaxDelayMs }
    return $delay
}

function Wait-AzureRetry([int]$DelayMs, [string]$Reason) {
    if ($DelayMs -lt 0) { $DelayMs = 0 }
    if ($DelayMs -gt $AzureRetryMaxDelayMs) { $DelayMs = $AzureRetryMaxDelayMs }
    Write-AzureLog ("transient Azure synthesis failure; retrying once after {0}ms reason={1}" -f $DelayMs, $Reason)
    $remaining = $DelayMs
    while ($remaining -gt 0) {
        Assert-OwnerAlive 'http-retry-wait' $true
        $slice = [Math]::Min(100, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    Assert-OwnerAlive 'http-retry-ready' $true
}

function Get-ProtectedAzureKey([string]$Path) {
    try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch {}
    $environmentKey = [string]$env:MORTALSHELL2TTS_AZURE_KEY
    if ([string]::IsNullOrWhiteSpace($environmentKey)) { $environmentKey = [string]$env:AZURE_SPEECH_KEY }
    if (-not [string]::IsNullOrWhiteSpace($environmentKey)) { return $environmentKey.Trim() }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'Azure Speech key is not configured.'
    }
    try {
        $secretLength = [IO.FileInfo]::new($Path).Length
        if ($secretLength -gt $SecretFileMaxBytes) {
            throw ('Azure Speech key store exceeded the ' + $SecretFileMaxBytes + ' byte safety limit.')
        }
    } catch [System.IO.FileNotFoundException] {
        throw 'Azure Speech key is not configured.'
    }

    $encoded = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($encoded)) {
        throw 'Azure Speech key store is empty.'
    }

    $protected = [Convert]::FromBase64String($encoded)
    $entropy = [Text.Encoding]::UTF8.GetBytes($EntropyText)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try {
        return [Text.Encoding]::UTF8.GetString($plain)
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function Get-AzurePlayerSource {
    return @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace MortalShell2TTS
{
    public sealed class AzureWaveOutPlayer : IDisposable
    {
        private const uint WAVE_MAPPER = 0xFFFFFFFF;
        private const uint CALLBACK_NULL = 0;
        private const uint WHDR_DONE = 0x00000001;
        private const int MMSYSERR_NOERROR = 0;
        private const int MAX_QUEUED_BUFFERS = 6;

        [StructLayout(LayoutKind.Sequential)]
        private struct WAVEFORMATEX
        {
            public ushort wFormatTag;
            public ushort nChannels;
            public uint nSamplesPerSec;
            public uint nAvgBytesPerSec;
            public ushort nBlockAlign;
            public ushort wBitsPerSample;
            public ushort cbSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WAVEHDR
        {
            public IntPtr lpData;
            public uint dwBufferLength;
            public uint dwBytesRecorded;
            public UIntPtr dwUser;
            public uint dwFlags;
            public uint dwLoops;
            public IntPtr lpNext;
            public UIntPtr reserved;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private struct WAVEOUTCAPS
        {
            public ushort wMid;
            public ushort wPid;
            public uint vDriverVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szPname;
            public uint dwFormats;
            public ushort wChannels;
            public ushort wReserved1;
            public uint dwSupport;
        }

        [DllImport("winmm.dll")]
        private static extern uint waveOutGetNumDevs();

        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        private static extern int waveOutGetDevCaps(UIntPtr uDeviceID, out WAVEOUTCAPS pwoc, uint cbwoc);

        [DllImport("winmm.dll")]
        private static extern int waveOutOpen(out IntPtr phwo, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);

        [DllImport("winmm.dll")]
        private static extern int waveOutPrepareHeader(IntPtr hwo, IntPtr pwh, uint cbwh);

        [DllImport("winmm.dll")]
        private static extern int waveOutUnprepareHeader(IntPtr hwo, IntPtr pwh, uint cbwh);

        [DllImport("winmm.dll")]
        private static extern int waveOutWrite(IntPtr hwo, IntPtr pwh, uint cbwh);

        [DllImport("winmm.dll")]
        private static extern int waveOutReset(IntPtr hwo);

        [DllImport("winmm.dll")]
        private static extern int waveOutClose(IntPtr hwo);

        private sealed class PendingBuffer
        {
            public byte[] Data;
            public GCHandle DataHandle;
            public IntPtr HeaderPtr;
            public bool Prepared;
        }

        private IntPtr handle = IntPtr.Zero;
        private readonly List<PendingBuffer> pending = new List<PendingBuffer>();
        private readonly double volumeScale;
        private bool disposed;

        public string DeviceName { get; private set; }

        public AzureWaveOutPlayer(string preferredDeviceName, int sampleRate, short channels, short bitsPerSample, int volume)
        {
            string resolvedName;
            uint deviceId = FindDevice(preferredDeviceName, out resolvedName);
            DeviceName = resolvedName;

            WAVEFORMATEX format = new WAVEFORMATEX();
            format.wFormatTag = 1;
            format.nChannels = (ushort)channels;
            format.nSamplesPerSec = (uint)sampleRate;
            format.wBitsPerSample = (ushort)bitsPerSample;
            format.nBlockAlign = (ushort)(channels * (bitsPerSample / 8));
            format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
            format.cbSize = 0;

            int result = waveOutOpen(out handle, deviceId, ref format, IntPtr.Zero, IntPtr.Zero, CALLBACK_NULL);
            if ((result != MMSYSERR_NOERROR || handle == IntPtr.Zero) && deviceId != WAVE_MAPPER)
            {
                // The preferred endpoint can disappear after discovery but before open
                // (Bluetooth/USB/virtual-device disconnect). Make one fail-soft attempt
                // through WAVE_MAPPER so Azure narration follows the current Windows
                // default device rather than failing the entire utterance.
                if (handle != IntPtr.Zero)
                {
                    try { waveOutClose(handle); } catch { }
                    handle = IntPtr.Zero;
                }
                int requestedResult = result;
                result = waveOutOpen(out handle, WAVE_MAPPER, ref format, IntPtr.Zero, IntPtr.Zero, CALLBACK_NULL);
                if (result == MMSYSERR_NOERROR && handle != IntPtr.Zero)
                {
                    DeviceName = "System Default";
                }
                else
                {
                    throw new InvalidOperationException("waveOutOpen failed with code " + requestedResult + " for requested device and fallback code " + result + " for System Default");
                }
            }
            else if (result != MMSYSERR_NOERROR || handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("waveOutOpen failed with code " + result + " for device " + DeviceName);
            }

            int clampedVolume = Math.Max(0, Math.Min(100, volume));
            volumeScale = clampedVolume / 100.0;
        }

        public static string[] ListDeviceNames()
        {
            List<string> names = new List<string>();
            uint count = waveOutGetNumDevs();
            for (uint i = 0; i < count; i++)
            {
                WAVEOUTCAPS caps;
                int result = waveOutGetDevCaps(new UIntPtr(i), out caps, (uint)Marshal.SizeOf(typeof(WAVEOUTCAPS)));
                if (result == MMSYSERR_NOERROR && !String.IsNullOrWhiteSpace(caps.szPname))
                {
                    names.Add(caps.szPname.Trim());
                }
            }
            return names.ToArray();
        }

        private static uint FindDevice(string preferred, out string resolvedName)
        {
            if (String.IsNullOrWhiteSpace(preferred) || preferred.Equals("System Default", StringComparison.OrdinalIgnoreCase) || preferred.Equals("default", StringComparison.OrdinalIgnoreCase))
            {
                resolvedName = "System Default";
                return WAVE_MAPPER;
            }

            string target = Normalize(preferred);
            uint count = waveOutGetNumDevs();
            uint fallbackId = WAVE_MAPPER;
            string fallbackName = "System Default";

            for (uint i = 0; i < count; i++)
            {
                WAVEOUTCAPS caps;
                int result = waveOutGetDevCaps(new UIntPtr(i), out caps, (uint)Marshal.SizeOf(typeof(WAVEOUTCAPS)));
                if (result != MMSYSERR_NOERROR || String.IsNullOrWhiteSpace(caps.szPname))
                    continue;

                string name = caps.szPname.Trim();
                string normalized = Normalize(name);
                if (normalized == target)
                {
                    resolvedName = name;
                    return i;
                }

                if (fallbackId == WAVE_MAPPER && (target.StartsWith(normalized, StringComparison.OrdinalIgnoreCase) || normalized.StartsWith(target, StringComparison.OrdinalIgnoreCase)))
                {
                    fallbackId = i;
                    fallbackName = name;
                }
            }

            resolvedName = fallbackName;
            return fallbackId;
        }

        private static string Normalize(string value)
        {
            if (String.IsNullOrEmpty(value)) return String.Empty;
            char[] buffer = new char[value.Length];
            int used = 0;
            foreach (char c in value.ToLowerInvariant())
            {
                if (Char.IsLetterOrDigit(c)) buffer[used++] = c;
            }
            return new string(buffer, 0, used);
        }

        public void Write(byte[] source, int count)
        {
            if (disposed) throw new ObjectDisposedException("AzureWaveOutPlayer");
            if (source == null || count <= 0) return;
            if (count > source.Length) count = source.Length;

            ReapCompleted(false);
            while (pending.Count >= MAX_QUEUED_BUFFERS)
            {
                ReapCompleted(true);
            }

            PendingBuffer buffer = new PendingBuffer();
            buffer.Data = new byte[count];
            Buffer.BlockCopy(source, 0, buffer.Data, 0, count);
            if (volumeScale < 0.9999)
            {
                for (int sampleIndex = 0; sampleIndex + 1 < count; sampleIndex += 2)
                {
                    short sample = (short)(buffer.Data[sampleIndex] | (buffer.Data[sampleIndex + 1] << 8));
                    int scaled = (int)Math.Round(sample * volumeScale);
                    if (scaled > short.MaxValue) scaled = short.MaxValue;
                    if (scaled < short.MinValue) scaled = short.MinValue;
                    buffer.Data[sampleIndex] = (byte)(scaled & 0xFF);
                    buffer.Data[sampleIndex + 1] = (byte)((scaled >> 8) & 0xFF);
                }
            }
            buffer.DataHandle = GCHandle.Alloc(buffer.Data, GCHandleType.Pinned);

            WAVEHDR header = new WAVEHDR();
            header.lpData = buffer.DataHandle.AddrOfPinnedObject();
            header.dwBufferLength = (uint)count;
            header.dwFlags = 0;
            header.dwLoops = 0;

            int headerSize = Marshal.SizeOf(typeof(WAVEHDR));
            buffer.HeaderPtr = Marshal.AllocHGlobal(headerSize);
            Marshal.StructureToPtr(header, buffer.HeaderPtr, false);

            int prepareResult = waveOutPrepareHeader(handle, buffer.HeaderPtr, (uint)headerSize);
            if (prepareResult != MMSYSERR_NOERROR)
            {
                CleanupBuffer(buffer, false);
                throw new InvalidOperationException("waveOutPrepareHeader failed with code " + prepareResult);
            }
            buffer.Prepared = true;

            int writeResult = waveOutWrite(handle, buffer.HeaderPtr, (uint)headerSize);
            if (writeResult != MMSYSERR_NOERROR)
            {
                CleanupBuffer(buffer, true);
                throw new InvalidOperationException("waveOutWrite failed with code " + writeResult);
            }

            pending.Add(buffer);
        }

        public void Drain()
        {
            while (pending.Count > 0)
            {
                ReapCompleted(true);
            }
        }

        private void ReapCompleted(bool waitForOne)
        {
            bool removedAny = false;
            do
            {
                removedAny = false;
                for (int i = 0; i < pending.Count; i++)
                {
                    WAVEHDR header = (WAVEHDR)Marshal.PtrToStructure(pending[i].HeaderPtr, typeof(WAVEHDR));
                    if ((header.dwFlags & WHDR_DONE) != 0)
                    {
                        PendingBuffer completed = pending[i];
                        pending.RemoveAt(i);
                        CleanupBuffer(completed, true);
                        removedAny = true;
                        break;
                    }
                }

                if (!waitForOne || removedAny || pending.Count == 0)
                    return;

                Thread.Sleep(4);
            } while (true);
        }

        private void CleanupBuffer(PendingBuffer buffer, bool unprepare)
        {
            if (buffer == null) return;
            if (unprepare && buffer.Prepared && handle != IntPtr.Zero && buffer.HeaderPtr != IntPtr.Zero)
            {
                for (int attempt = 0; attempt < 50; attempt++)
                {
                    int result = waveOutUnprepareHeader(handle, buffer.HeaderPtr, (uint)Marshal.SizeOf(typeof(WAVEHDR)));
                    if (result == MMSYSERR_NOERROR) break;
                    Thread.Sleep(2);
                }
            }
            if (buffer.HeaderPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(buffer.HeaderPtr);
                buffer.HeaderPtr = IntPtr.Zero;
            }
            if (buffer.DataHandle.IsAllocated) buffer.DataHandle.Free();
            buffer.Data = null;
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;

            if (handle != IntPtr.Zero)
            {
                waveOutReset(handle);
                for (int i = 0; i < pending.Count; i++)
                    CleanupBuffer(pending[i], true);
                pending.Clear();
                waveOutClose(handle);
                handle = IntPtr.Zero;
            }
        }
    }
}
'@
}

function Ensure-AzurePlayerAssembly {
    if (-not (Test-Path -LiteralPath $PlayerCacheDir)) {
        [IO.Directory]::CreateDirectory($PlayerCacheDir) | Out-Null
    }

    # Recover the tiny publish window if a previous Azure child was terminated
    # after moving the old cache aside but before the replacement became live.
    $orphanPreviousAssembly = $PlayerAssembly + '.previous'
    $orphanPreviousHash = $PlayerHashPath + '.previous'
    if (-not (Test-Path -LiteralPath $PlayerAssembly) -and (Test-Path -LiteralPath $orphanPreviousAssembly)) {
        try {
            Move-Item -LiteralPath $orphanPreviousAssembly -Destination $PlayerAssembly -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $PlayerHashPath) -and (Test-Path -LiteralPath $orphanPreviousHash)) {
                Move-Item -LiteralPath $orphanPreviousHash -Destination $PlayerHashPath -Force -ErrorAction Stop
            }
            Write-AzureLog 'recovered previous WinMM player cache after an interrupted publish'
        } catch {
            Write-AzureLog ('previous WinMM cache recovery failed; ' + (Get-AzureExceptionSignature $_.Exception))
        }
    }

    $source = Get-AzurePlayerSource
    $sourceHash = Get-TextSha256 $source

    $cacheMatches = $false
    if ((Test-Path -LiteralPath $PlayerAssembly) -and (Test-Path -LiteralPath $PlayerHashPath)) {
        try {
            $savedHash = [IO.File]::ReadAllText($PlayerHashPath, [Text.Encoding]::UTF8).Trim().ToLowerInvariant()
            $cacheMatches = ($savedHash -eq $sourceHash)
        } catch { $cacheMatches = $false }
    }

    if ($cacheMatches) {
        try {
            Add-Type -Path $PlayerAssembly -ErrorAction Stop
            $playerType = 'MortalShell2TTS.AzureWaveOutPlayer' -as [type]
            if ($null -eq $playerType) { throw 'expected AzureWaveOutPlayer type was not found' }
            return
        } catch {
            Write-AzureLog ('cached WinMM player was unusable; rebuild requested: ' + $_.Exception.Message)
        }
    } elseif (Test-Path -LiteralPath $PlayerAssembly) {
        Write-AzureLog 'cached WinMM player source signature is missing/stale; rebuild requested'
    }

    $languageMode = 'Unknown'
    try { $languageMode = [string]$ExecutionContext.SessionState.LanguageMode } catch {}
    if ($languageMode -ne 'FullLanguage') {
        throw "Azure WinMM player cache is missing/stale/unusable and PowerShell LanguageMode=$languageMode blocks the runtime C# build. Windows/local TTS remains available."
    }

    $buildMutex = $null
    $acquired = $false
    $tempAssembly = $PlayerAssembly + '.' + $PID + '.' + [Guid]::NewGuid().ToString('N') + '.tmp.dll'
    $tempHash = $PlayerHashPath + '.' + $PID + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $previousAssembly = $PlayerAssembly + '.previous'
    $previousHash = $PlayerHashPath + '.previous'
    try {
        $buildMutex = New-Object System.Threading.Mutex($false, 'Local\MortalShell2TTSAzurePlayerBuild_v1')
        $acquired = $buildMutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $acquired) { throw 'Timed out waiting for another MortalShell2TTS Azure player-cache build to finish.' }

        # Another stream process may have completed the exact-source build while
        # this process waited for the mutex.
        $cacheMatches = $false
        if ((Test-Path -LiteralPath $PlayerAssembly) -and (Test-Path -LiteralPath $PlayerHashPath)) {
            try {
                $savedHash = [IO.File]::ReadAllText($PlayerHashPath, [Text.Encoding]::UTF8).Trim().ToLowerInvariant()
                $cacheMatches = ($savedHash -eq $sourceHash)
            } catch { $cacheMatches = $false }
        }
        if ($cacheMatches) {
            try {
                Add-Type -Path $PlayerAssembly -ErrorAction Stop
                $playerType = 'MortalShell2TTS.AzureWaveOutPlayer' -as [type]
                if ($null -eq $playerType) { throw 'expected AzureWaveOutPlayer type was not found' }
                return
            } catch {
                Write-AzureLog ('concurrent cached WinMM player was invalid; rebuilding: ' + $_.Exception.Message)
            }
        }

        # Compile and validate the replacement before touching the previous cache.
        # v0.9.79 removed the stale cache first, which meant a transient compiler,
        # antivirus, disk, or policy failure could destroy a cache that was still
        # useful for rollback. Keep last-known-good cache files until publish succeeds.
        Write-AzureLog 'compiling one-time WinMM streaming player cache for current source signature'
        try {
            Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $tempAssembly -ErrorAction Stop
        } catch {
            throw ('Runtime C# compilation for Azure playback failed; ' + (Get-AzureExceptionSignature $_.Exception))
        }
        if (-not (Test-Path -LiteralPath $tempAssembly) -or [IO.FileInfo]::new($tempAssembly).Length -le 0) {
            throw 'Runtime C# compilation completed without producing a valid Azure player assembly.'
        }

        $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($tempAssembly)
        if ($null -eq $assemblyName) { throw 'Compiled Azure player assembly failed metadata validation.' }
        [IO.File]::WriteAllText($tempHash, $sourceHash, $Utf8NoBom)

        try { Remove-Item -LiteralPath $previousAssembly -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $previousHash -Force -ErrorAction SilentlyContinue } catch {}
        $movedPreviousAssembly = $false
        $movedPreviousHash = $false
        try {
            if (Test-Path -LiteralPath $PlayerAssembly) {
                Move-Item -LiteralPath $PlayerAssembly -Destination $previousAssembly -Force -ErrorAction Stop
                $movedPreviousAssembly = $true
            }
            if (Test-Path -LiteralPath $PlayerHashPath) {
                Move-Item -LiteralPath $PlayerHashPath -Destination $previousHash -Force -ErrorAction Stop
                $movedPreviousHash = $true
            }

            Move-Item -LiteralPath $tempAssembly -Destination $PlayerAssembly -Force -ErrorAction Stop
            Move-Item -LiteralPath $tempHash -Destination $PlayerHashPath -Force -ErrorAction Stop
            try {
                Add-Type -Path $PlayerAssembly -ErrorAction Stop
                $playerType = 'MortalShell2TTS.AzureWaveOutPlayer' -as [type]
                if ($null -eq $playerType) { throw 'expected AzureWaveOutPlayer type was not found' }
            } catch {
                throw ('Compiled Azure player cache failed load validation; ' + (Get-AzureExceptionSignature $_.Exception))
            }

            try { Remove-Item -LiteralPath $previousAssembly -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $previousHash -Force -ErrorAction SilentlyContinue } catch {}
        } catch {
            # Restore the previous cache whenever publication/load fails. The current
            # Azure request can fail safely, but the next run should not inherit a
            # half-published or unnecessarily deleted cache.
            try { Remove-Item -LiteralPath $PlayerAssembly -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $PlayerHashPath -Force -ErrorAction SilentlyContinue } catch {}
            if ($movedPreviousAssembly -and (Test-Path -LiteralPath $previousAssembly)) {
                try { Move-Item -LiteralPath $previousAssembly -Destination $PlayerAssembly -Force -ErrorAction Stop } catch {}
            }
            if ($movedPreviousHash -and (Test-Path -LiteralPath $previousHash)) {
                try { Move-Item -LiteralPath $previousHash -Destination $PlayerHashPath -Force -ErrorAction Stop } catch {}
            }
            throw
        }
        Write-AzureLog ('WinMM streaming player cache ready sourceHash=' + $sourceHash.Substring(0, 12))
    } finally {
        try { Remove-Item -LiteralPath $tempAssembly -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $tempHash -Force -ErrorAction SilentlyContinue } catch {}
        if ($null -ne $buildMutex) {
            if ($acquired) { try { $buildMutex.ReleaseMutex() } catch {} }
            try { $buildMutex.Dispose() } catch {}
        }
    }
}

$request = $null
$key = $null
$player = $null
$response = $null
$stream = $null
$client = $null

try {
    Assert-OwnerAlive 'startup' $true
    Write-AzureLog ("Azure child network compatibility tls12={0}" -f $script:Tls12Compatibility)
    if (-not (Test-Path -LiteralPath $RequestPath)) {
        throw 'Azure stream request file is missing.'
    }
    try {
        if ([IO.FileInfo]::new($RequestPath).Length -gt 2MB) {
            throw 'Azure stream request file exceeded the 2 MB safety limit.'
        }
    } catch [System.IO.FileNotFoundException] {
        throw 'Azure stream request file disappeared before it could be read.'
    }

    $requestJson = [IO.File]::ReadAllText($RequestPath, [Text.Encoding]::UTF8)
    try {
        $request = $requestJson | ConvertFrom-Json
    } catch {
        throw 'Azure stream request JSON could not be parsed.'
    } finally {
        $requestJson = $null
    }
    try { Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue } catch {}

    Assert-OwnerAlive 'before-credential-read' $true
    $key = Get-ProtectedAzureKey $SecretPath
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Azure Speech key could not be decrypted.' }

    $region = ([string]$request.Region).Trim().ToLowerInvariant()
    $voice = ([string]$request.Voice).Replace("`r", '').Replace("`n", '').Replace("`t", '').Trim()
    $text = [string]$request.Text
    $audioOutputName = ([string]$request.AudioOutputName).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
    $rate = 0
    try { $rate = [Math]::Max(-10, [Math]::Min(10, [int]$request.Rate)) } catch {}
    $volume = 100
    try { $volume = [Math]::Max(0, [Math]::Min(100, [int]$request.Volume)) } catch {}
    $pitch = 0
    try { $pitch = [Math]::Max(-6, [Math]::Min(6, [int]$request.Pitch)) } catch {}
    $style = ([string]$request.Style).Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($style)) { $style = 'default' }

    if ([string]::IsNullOrWhiteSpace($region) -or $region.Length -gt 64 -or $region -notmatch '^[a-z0-9-]+$') { throw 'Azure Speech region is invalid.' }
    if ([string]::IsNullOrWhiteSpace($voice) -or $voice.Length -gt 384) { throw 'Azure Speech voice is invalid.' }
    if ($style.Length -gt 96) { throw 'Azure Speech style value is invalid.' }
    if ($audioOutputName.Length -gt 512) { throw 'Azure audio output name exceeded the safety limit.' }
    if ($text.Length -gt $SpeechTextLimitChars) { throw ('Azure narration request exceeded the ' + $SpeechTextLimitChars + ' character safety limit.') }
    if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

    Ensure-AzurePlayerAssembly

    $escaped = [Security.SecurityElement]::Escape($text)

    # The helper never sends user-authored raw SSML. For exact IPA corrections it
    # replaces a matched source word with a helper-selected BMP Private Use Area
    # marker and sends the original word + IPA in this bounded side table. Escape
    # all ordinary narration first, then replace only those generated markers with
    # escaped <phoneme> markup. This preserves the human-readable source as SSML
    # fallback while preventing pronunciation-file content from becoming markup.
    $phonemeEntries = @()
    if ($null -ne $request.PronunciationPhonemes) { $phonemeEntries = @($request.PronunciationPhonemes) }
    if ($phonemeEntries.Count -gt 512) { throw 'Azure pronunciation phoneme mapping exceeded the safety limit.' }
    $seenPhonemeMarkers = @{}
    $phonemeCount = 0
    foreach ($entry in $phonemeEntries) {
        if ($null -eq $entry) { continue }
        $marker = [string]$entry.Marker
        $fallback = [string]$entry.Fallback
        $phoneme = [string]$entry.Phoneme
        if ($marker.Length -ne 1 -or [string]::IsNullOrWhiteSpace($fallback) -or [string]::IsNullOrWhiteSpace($phoneme) -or
            $fallback.Length -gt 256 -or $phoneme.Length -gt 512) {
            throw 'Azure pronunciation phoneme mapping is invalid.'
        }
        $markerCode = [int][char]$marker[0]
        if ($markerCode -lt 0xE000 -or $markerCode -gt 0xF8FF) { throw 'Azure pronunciation marker is outside the private-use range.' }
        if ($seenPhonemeMarkers.ContainsKey([string]$markerCode)) { throw 'Azure pronunciation marker is duplicated.' }
        $seenPhonemeMarkers[[string]$markerCode] = $true
        if ($text.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { throw 'Azure pronunciation marker is missing from narration.' }

        $markerEscaped = [Security.SecurityElement]::Escape($marker)
        $fallbackEscaped = [Security.SecurityElement]::Escape($fallback)
        $phonemeEscaped = [Security.SecurityElement]::Escape($phoneme)
        $phonemeMarkup = '<phoneme alphabet="ipa" ph="' + $phonemeEscaped + '">' + $fallbackEscaped + '</phoneme>'
        $escaped = $escaped.Replace($markerEscaped, $phonemeMarkup)
        $phonemeCount++
    }
    if ($phonemeCount -gt 0) { Write-AzureLog ("pronunciation IPA SSML prepared phonemes={0}" -f $phonemeCount) }

    # Preview-only MAI prosody bridge. Passes 101-102 proved that removing/zeroing
    # explicit SSML breaks does not fully remove Harper's residual pause before "Two".
    # That isolates the remaining behavior to model-inferred title/sequel prosody rather
    # than an explicit break. Preserve the exact audible lexical wording while changing
    # only hidden synthesis orthography: lowercase the inaudible capitalization of "two"
    # and use the normal written compound "text-to-speech" so the first sentence parses
    # as continuous prose rather than a title followed by a sequel number. Normal SPEAK
    # narration never sets PreviewCadence and is never rewritten by this profile.
    $previewCadence = $false
    try { if ($null -ne $request.PreviewCadence) { $previewCadence = [bool]$request.PreviewCadence } } catch {}
    $previewPhrase = 'Mortal Shell Two text to speech preview. The darkness remembers every name.'
    $isMaiPreview = $previewCadence -and ($voice -match ':MAI-Voice-') -and ($text -ceq $previewPhrase)
    if ($isMaiPreview) {
        $escaped = '<s>Mortal Shell two text-to-speech preview.</s><s>The darkness remembers every name.</s>'
        Write-AzureLog 'preview cadence profile=mai-orthographic-bridge hiddenCase=two hiddenCompound=text-to-speech phrase=canonical-two-sentence'
    } elseif ($previewCadence) {
        $previewVoiceFamily = if ($voice -match ':MAI-Voice-') { 'mai' } else { 'other' }
        $previewPhraseMatch = [bool]($text -ceq $previewPhrase)
        Write-AzureLog ("preview cadence profile=raw voiceFamily={0} phraseMatch={1}" -f $previewVoiceFamily, $previewPhraseMatch)
    }

    $language = 'en-US'
    $voiceParts = $voice.Split('-')
    if ($voiceParts.Length -ge 2) { $language = $voiceParts[0] + '-' + $voiceParts[1] }

    $ratePercent = [Math]::Max(-90, [Math]::Min(100, $rate * 10))
    if ($ratePercent -ge 0) { $rateText = '+' + $ratePercent + '%' } else { $rateText = $ratePercent.ToString() + '%' }

    $pitchAttribute = ''
    if ($pitch -ne 0 -and $voice -notmatch 'DragonHD') {
        $pitchText = if ($pitch -gt 0) { '+' + $pitch + 'st' } else { [string]$pitch + 'st' }
        $pitchAttribute = ' pitch="' + $pitchText + '"'
    }

    $styleActive = ($style -ne 'default' -and -not [string]::IsNullOrWhiteSpace($style))
    $isDragonHD = ($voice -match 'DragonHD')
    $isDragonHDOmni = ($voice -match 'DragonHDOmni')
    $isMaiVoice = ($voice -match ':MAI-Voice-')
    if ($isDragonHD) {
        # Azure HD models do not expose prosody pitch/rate. Dragon HD Omni accepts
        # mstts:express-as; base DragonHD/Flash voices use Microsoft's bracketed style
        # marker form when a live StyleList reports that the chosen style exists.
        $body = $escaped
        if ($styleActive -and -not $isDragonHDOmni) {
            $body = '[' + [Security.SecurityElement]::Escape($style) + '] ' + $body
        }
    } elseif ($isMaiVoice -and $phonemeCount -gt 0) {
        # MAI-Voice-2 is a preview model with a constrained SSML surface. Microsoft's
        # documented MAI examples place text/express-as directly under <voice>; they
        # do not wrap the body in generic <prosody>. When an exact pronunciation rule
        # is present, use that documented shape so an inline <phoneme> is not nested
        # inside an unsupported/undocumented prosody wrapper. Keep the legacy MAI
        # path unchanged for utterances with no phoneme correction.
        $body = $escaped
        Write-AzureLog ("SSML profile=mai-pronunciation-direct prosody=false phonemes={0} rateSetting={1} pitchSetting={2}" -f $phonemeCount, $rate, $pitch)
    } else {
        $body = '<prosody rate="' + $rateText + '"' + $pitchAttribute + '>' + $escaped + '</prosody>'
    }
    if ($styleActive -and (-not $isDragonHD -or $isDragonHDOmni)) {
        $body = '<mstts:express-as style="' + [Security.SecurityElement]::Escape($style) + '">' + $body + '</mstts:express-as>'
    }

    $ssml = '<speak version="1.0" xml:lang="' + $language + '" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts">' +
            '<voice name="' + [Security.SecurityElement]::Escape($voice) + '">' + $body + '</voice></speak>'

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    $endpoint = 'https://' + $region + '.tts.speech.microsoft.com/cognitiveservices/v1'
    $started = [Diagnostics.Stopwatch]::StartNew()
    $httpSucceeded = $false
    $lastHttpException = $null

    for ($attempt = 1; $attempt -le $AzureHttpMaxAttempts; $attempt++) {
        $message = $null
        $attemptResponse = $null
        $sendCancellation = $null
        try {
            Assert-OwnerAlive ('before-http-request-' + $attempt) $true
            $message = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $endpoint)
            $message.Headers.TryAddWithoutValidation('Ocp-Apim-Subscription-Key', $key) | Out-Null
            $message.Headers.TryAddWithoutValidation('X-Microsoft-OutputFormat', 'raw-24khz-16bit-mono-pcm') | Out-Null
            $message.Headers.TryAddWithoutValidation('User-Agent', 'MortalShell2TTS') | Out-Null
            $message.Content = New-Object System.Net.Http.StringContent($ssml, [Text.Encoding]::UTF8, 'application/ssml+xml')

            # Do not block blindly inside GetResult(): poll the asynchronous send so
            # parent/game ownership can cancel an in-flight request promptly instead
            # of leaving an Azure child around until the HttpClient timeout expires.
            $sendCancellation = New-Object System.Threading.CancellationTokenSource
            $sendTask = $client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $sendCancellation.Token)
            while (-not $sendTask.IsCompleted) {
                Assert-OwnerAlive 'http-request' $true
                Start-Sleep -Milliseconds 100
            }
            $attemptResponse = $sendTask.GetAwaiter().GetResult()

            if ($attemptResponse.IsSuccessStatusCode) {
                $response = $attemptResponse
                $attemptResponse = $null
                $httpSucceeded = $true
                if ($attempt -gt 1) { Write-AzureLog ("Azure synthesis retry succeeded attempt={0}" -f $attempt) }
                break
            }

            $statusCode = [int]$attemptResponse.StatusCode
            $reasonPhrase = [string]$attemptResponse.ReasonPhrase
            if ($attempt -lt $AzureHttpMaxAttempts -and (Test-RetriableAzureHttpStatus $statusCode)) {
                $delayMs = Get-AzureRetryDelayMs $attemptResponse
                try { $attemptResponse.Dispose() } catch {}
                $attemptResponse = $null
                Wait-AzureRetry $delayMs ('HTTP ' + $statusCode)
                continue
            }

            # Do not log the response body: a service/proxy error page could echo
            # request content. Status-specific guidance is enough for support.
            throw (Get-FriendlyAzureHttpFailure $statusCode $reasonPhrase)
        } catch {
            $lastHttpException = $_.Exception
            if ($attempt -lt $AzureHttpMaxAttempts -and (Test-RetriableAzureException $_.Exception)) {
                Wait-AzureRetry $AzureRetryDefaultDelayMs (Get-AzureExceptionSignature $_.Exception)
                continue
            }
            throw
        } finally {
            if ($null -ne $sendCancellation) {
                if (-not $httpSucceeded) { try { $sendCancellation.Cancel() } catch {} }
                try { $sendCancellation.Dispose() } catch {}
            }
            if ($null -ne $attemptResponse) { try { $attemptResponse.Dispose() } catch {} }
            if ($null -ne $message) { try { $message.Dispose() } catch {} }
        }
    }

    if (-not $httpSucceeded -or $null -eq $response) {
        if ($null -ne $lastHttpException) { throw $lastHttpException }
        throw 'Azure synthesis request did not return a usable HTTP response.'
    }

    $declaredAudioLength = $null
    try { $declaredAudioLength = $response.Content.Headers.ContentLength } catch {}
    if ($null -ne $declaredAudioLength -and [int64]$declaredAudioLength -gt $AzureAudioMaxBytes) {
        throw ('Azure audio response exceeded safety limit bytes=' + $declaredAudioLength + ' limit=' + $AzureAudioMaxBytes + '.')
    }

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    try {
        if ($stream.CanTimeout) { $stream.ReadTimeout = $AzureStreamReadTimeoutMs }
    } catch {}
    $player = New-Object MortalShell2TTS.AzureWaveOutPlayer($audioOutputName, 24000, 1, 16, $volume)

    $buffer = New-Object byte[] 16384
    $total = 0
    $first = $true
    while ($true) {
        Assert-OwnerAlive 'audio-stream' $false
        try {
            $read = $stream.Read($buffer, 0, $buffer.Length)
        } catch [System.IO.IOException] {
            throw ('Azure stream read timed out or failed after audioBytes=' + $total + '. ' + (Get-AzureExceptionSignature $_.Exception))
        }
        if ($read -le 0) { break }
        $nextTotal = [int64]$total + [int64]$read
        if ($nextTotal -gt $AzureAudioMaxBytes) {
            throw ('Azure audio response exceeded safety limit bytes>' + $AzureAudioMaxBytes + '.')
        }
        if ($first) {
            $first = $false
            Write-AzureLog ("first audio chunk after {0}ms voice={1} region={2} requestedOutput={3} waveOut={4}" -f [int]$started.ElapsedMilliseconds, $voice, $region, ($audioOutputName -replace '[\r\n]', ' '), $player.DeviceName)
        }
        $player.Write($buffer, $read)
        $total = $nextTotal
    }

    if ($total -le 0) {
        throw 'Azure synthesis returned a successful response but no audio bytes.'
    }
    Assert-OwnerAlive 'before-drain' $true
    $player.Drain()
    Write-AzureLog ("completed chars={0} bytes={1} elapsed={2}ms voice={3} waveOut={4}" -f $text.Length, $total, [int]$started.ElapsedMilliseconds, $voice, $player.DeviceName)
} catch {
    $friendlyError = Get-FriendlyAzureException $_.Exception
    Write-AzureLog ('error: ' + $friendlyError)
    exit 1
} finally {
    if ($null -ne $player) { try { $player.Dispose() } catch {} }
    if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    if ($null -ne $response) { try { $response.Dispose() } catch {} }
    if ($null -ne $client) { try { $client.Dispose() } catch {} }
    if ($null -ne $key) { $key = $null }
    try { Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue } catch {}
    if ($null -ne $script:LogMutex) {
        try { $script:LogMutex.Dispose() } catch {}
        $script:LogMutex = $null
    }
}
