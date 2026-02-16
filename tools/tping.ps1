#Requires -Version 5.1
<#
.SYNOPSIS
    Timestamp-Ping - log ping-timestamps of a target host

.DESCRIPTION
    PowerShell port of tping.sh with identical featureset, functionality and argument handling.
    v6.3 - matches tping.sh v6.3
    Uses Test-Connection cmdlet (locale-independent .NET objects, no ping.exe output parsing).

.PARAMETER Target
    Target IP address or DNS name to ping

.PARAMETER IPv4
    Use IPv4-only for DNS lookup (default: IPv6 with fallback to IPv4)

.PARAMETER Deadtime
    Timeout in seconds for ping (default: 1)

.PARAMETER Interval
    Time between pings in seconds (default: 1)

.PARAMETER Fuzzy
    Number of failed pings before marking down; 0 disables (default: 0)

.PARAMETER Static
    Use legacy static mode without RTT live-updates when host is up

.PARAMETER DebugMode
    Enable debug output (use -d as short form)

.PARAMETER Version
    Show version and exit

.PARAMETER Help
    Show usage and exit
#>

param(
    [Parameter(Position = 0)]
    [string]$Target,

    [Alias('4')]
    [switch]$IPv4,
    [Alias('W')]
    [int]$Deadtime = 1,
    [Alias('i')]
    [int]$Interval = 1,
    [Alias('f')]
    [int]$Fuzzy = 0,
    [Alias('s')]
    [switch]$Static,
    [Alias('d')]
    [switch]$DebugMode,
    [Alias('v')]
    [switch]$Version,
    [Alias('h')]
    [switch]$Help
)

# Version
$VER = "6.3"

# Default values (matching tping.sh)
$script:ipv = if ($IPv4) { 4 } else { 6 }
$script:debug = [bool]$DebugMode
$script:deadtime = $Deadtime
$script:interval = $Interval
$script:fuzzy_limit = $Fuzzy
$script:follow = -not $Static

# State variables
$script:health = 2   # 0=dead, 1=alive, 2=startup
$script:ip = $null
$script:statint = 10
$script:mainLoopStarted = $false

# Statistics
$script:fuzzy_lost = 0
$script:fuzzy_total = 0
$script:fuzzy_cnt = 0
$script:transmitted = 0
$script:received = 0
$script:downtotal = 0
$script:downsec = 0
$script:uptotal = 0
$script:upsec = 0
$script:lastuptime = 0
$script:lastdowntime = 0
$script:flap = 0
$script:rtt = @($null) * 10  # statint slots
$script:rtt_min = $null
$script:rtt_max = 0.0
$script:rtt_avg = 0.0

# Colors (ANSI escape codes, work in Windows 10+)
$script:RED = "`e[0;31m"
$script:GREEN = "`e[0;32m"
$script:YELLOW = "`e[0;33m"
$script:RESET = "`e[0m"

function Write-Usage {
    Write-Host @"
usage: tping.ps1 [-vhd] [-W deadtime] [-i interval]
       [-f fuzzy-pings (# failed pings before marking down)]
       [-4 (use IPv4-only for DNS-lookup)]
       [-s (use legacy static mode without rtt live-updates)]
       <Target IP or DNS-Name>

"@
}

function Get-DisplayTime {
    param([long]$T)
    $D = [math]::Floor($T / 86400)
    $H = [math]::Floor(($T / 3600) % 24)
    $M = [math]::Floor(($T / 60) % 60)
    $S = $T % 60
    $parts = @()
    if ($D -gt 0) { $parts += "$D d" }
    if ($H -gt 0) { $parts += "$H h" }
    if ($M -gt 0) { $parts += "$M min" }
    if ($D -gt 0 -or $H -gt 0 -or $M -gt 0) {
        "$($parts -join ' ') and $S sec"
    } else {
        "$S sec"
    }
}

function Get-IPv4Address {
    param([string]$InputString)
    $pattern = '^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
    $InputString -match $pattern
}

function Get-IPv6Address {
    param([string]$InputString)
    $patterns = @(
        '^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}$',
        '^([0-9a-fA-F]{1,4}:){1,7}:$',
        '^([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}$',
        '^([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}$',
        '^([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}$',
        '^([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}$',
        '^([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}$',
        '^[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})$',
        '^:((:[0-9a-fA-F]{1,4}){1,7}|:)$',
        '^fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}$',
        '^::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$',
        '^([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$'
    )
    foreach ($p in $patterns) {
        if ($InputString -match $p) { return $true }
    }
    return $false
}

function Invoke-CalcStatistics {
    # Match bash logic: accumulate across intervals using running average (tping.sh line 148-168)
    $validRtt = $script:rtt | Where-Object { $null -ne $_ }
    if ($validRtt.Count -lt 2) { return }

    # Batch-level aggregation for this statistics interval
    $batchSum = 0.0
    $batchCount = 0
    foreach ($t in $validRtt) {
        $val = if ($t -eq '<1') { 0.5 } else { [double]$t }
        if ($null -eq $script:rtt_min -or $val -lt $script:rtt_min) { $script:rtt_min = $val }
        if ($val -gt $script:rtt_max) { $script:rtt_max = $val }
        $batchSum += $val
        $batchCount++
    }
    if ($batchCount -eq 0) { return }
    # Initialize cumulative aggregation variables on first use
    if ($null -eq $script:rtt_totalSum)   { $script:rtt_totalSum   = 0.0 }
    if ($null -eq $script:rtt_totalCount) { $script:rtt_totalCount = 0 }
    # Accumulate batch into global totals to match bash running-average behavior
    $script:rtt_totalSum   += $batchSum
    $script:rtt_totalCount += $batchCount
    # Keep rtt_sum aligned with the cumulative sum for any existing consumers
    $script:rtt_sum = $script:rtt_totalSum
    # Compute average using all RTT samples seen so far
    if ($script:rtt_totalCount -gt 0) {
        $script:rtt_avg = $script:rtt_totalSum / $script:rtt_totalCount
    }
    # Clear batch for next cycle
    for ($i = 0; $i -lt $script:statint; $i++) { $script:rtt[$i] = $null }
}

function Write-PrintStatistics {
    $hostParam = $script:targetHost
    $hostdigParam = $script:targetHostdig

    if ($script:health -eq 1) {
        $script:upsec = [int][double]::Parse((Get-Date -UFormat %s)) - $script:lastuptime
        $script:uptotal += $script:upsec
    } elseif ($script:health -eq 0) {
        $script:downsec = [int][double]::Parse((Get-Date -UFormat %s)) - $script:lastdowntime
        $script:downtotal += $script:downsec
    }

    Write-Host ""
    Write-Host "--- $hostParam ($hostdigParam) tping statistics ---"
    Write-Host "flapped $($script:flap) times, was up for $(Get-DisplayTime $script:uptotal) and down for $(Get-DisplayTime $script:downtotal)"

    if ($script:fuzzy_limit -gt 0 -and $script:fuzzy_total -gt 0) {
        Write-Host "fuzzy detection was used $($script:fuzzy_total) times, with a total of $($script:fuzzy_lost) lost pings"
    }

    if ($script:transmitted -gt 0) {
        $loss = [math]::Round(100 - ($script:received / $script:transmitted) * 100, 2)
        Write-Host "$($script:transmitted) packets transmitted, $($script:received) packets received, $loss% packet loss"
        Invoke-CalcStatistics
        if ($null -ne $script:rtt_min) {
            Write-Host "round-trip min/avg/max = $($script:rtt_min)/$([math]::Round($script:rtt_avg, 3))/$($script:rtt_max) ms"
        }
    }

    exit 0
}

# Register Ctrl+C handler (only when running in interactive console)
try {
    if ([Environment]::UserInteractive) {
        [Console]::TreatControlCAsInput = $false
        [Console]::CancelKeyPress.Add({
            param($eventSender, $e)
            $e.Cancel = $true
            Write-PrintStatistics
        })
    }
} catch {
    # Non-interactive or no console - Ctrl+C will terminate without stats
}

# --- Argument handling ---
if ($Help) {
    Write-Usage
    exit 0
}
if ($Version) {
    Write-Host "tping.ps1 v$VER"
    exit 0
}
if (-not $Target) {
    Write-Usage
    exit 1
}

$script:targetHost = $Target

# --- DNS resolution ---
if (Get-IPv4Address -InputString $script:targetHost) {
    $script:targetHostdig = $script:targetHost
    $script:ip = $script:targetHost
    $script:ipv = 4
} elseif (Get-IPv6Address -InputString $script:targetHost) {
    $script:targetHostdig = $script:targetHost
    $script:ip = $script:targetHost
    $script:ipv = 6
} else {
    $hostdigs = @()
    if ($script:ipv -eq 6) {
        try {
            $hostdigs = @((Resolve-DnsName $script:targetHost -Type AAAA -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress }).IPAddress)
        } catch {}
        if ($hostdigs.Count -gt 1) {
            Write-Host "$($script:YELLOW)Warning: $($script:targetHost) has multiple IPv6 addresses ($($hostdigs -join ', ')) - using first one.$($script:RESET)"
        }
        if ($hostdigs.Count -eq 0) {
            Write-Host "$($script:YELLOW)Warning: No v6 DNS for $($script:targetHost) - trying v4 DNS...$($script:RESET)"
            $script:ipv = 4
        }
    }
    if ($script:ipv -eq 4) {
        try {
            $hostdigs = @((Resolve-DnsName $script:targetHost -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress }).IPAddress)
        } catch {}
        if ($hostdigs.Count -gt 1) {
            Write-Host "$($script:YELLOW)Warning: $($script:targetHost) has multiple IPv4 addresses ($($hostdigs -join ', ')) - using first one.$($script:RESET)"
        }
        if ($hostdigs.Count -eq 0) {
            Write-Host "$($script:RED)Error: No v4 DNS for $($script:targetHost) - exiting now.$($script:RESET)"
            exit 1
        }
    }
    $script:targetHostdig = $hostdigs[0]
    $script:ip = $hostdigs[0]
}

# --- Build Test-Connection params (locale-independent, uses .NET objects) ---
# PS 5.1: -ComputerName, Win32_PingStatus (ResponseTime, StatusCode); no -IPv4/-IPv6, no -TimeoutSeconds
# PS 6+:  -TargetName, PingStatus (Latency/ResponseTime, Status); -IPv4/-IPv6, -TimeoutSeconds
$targetParam = if ((Get-Command Test-Connection).Parameters['TargetName']) { 'TargetName' } else { 'ComputerName' }
$script:tcParams = @{
    $targetParam = $script:ip
    Count        = 1
}
if ((Get-Command Test-Connection).Parameters['IPv4']) {
    if ($script:ipv -eq 6) { $script:tcParams['IPv6'] = $true } else { $script:tcParams['IPv4'] = $true }
}
if ((Get-Command Test-Connection).Parameters['TimeoutSeconds']) {
    $script:tcParams['TimeoutSeconds'] = $script:deadtime
    $script:effectiveDeadtime = $script:deadtime
} else {
    $script:effectiveDeadtime = 4  # PS 5.1 Win32_PingStatus default
}

if ($script:debug) {
    Write-Host "`t####### DEBUG #######"
    Write-Host "`targs = [ $($PSBoundParameters.Count) ]"
    Write-Host "`tdeadtime  = [ $($script:deadtime) ]"
    Write-Host "`tinterval = [ $($script:interval) ]"
    Write-Host "`tfuzzy = [ $($script:fuzzy_limit) ]"
    Write-Host "`tfollow = [ $($script:follow) ]"
    Write-Host "`thost = [ $($script:targetHost) ]"
    Write-Host "`tip = [ $($script:ip) ]"
    $tcStr = ($script:tcParams.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
    Write-Host "`tTest-Connection params = [ $tcStr ]"
    Write-Host "`t####### DEBUG #######"
}

if ($script:fuzzy_limit -gt 0) {
    Write-Host ""
    Write-Host "Note: fuzzy dead-detection in effect, will ignore up to $($script:fuzzy_limit) failed pings (you will see a --FUZZY-- indicator if in action). Use for unreliable connections only."
    Write-Host ""
}

# --- Main ping loop ---
# Save cursor position (ANSI: \e[s)
Write-Host -NoNewline "`e[s"

$script:mainLoopStarted = $true
try {
while ($true) {
    $script:transmitted++
    $success = $false
    $rttVal = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = @(Test-Connection @script:tcParams -ErrorAction Stop)[0]
        # PS 5.1 Win32_PingStatus: ResponseTime, StatusCode (0=success)
        # PS 6+ PingStatus: Latency/ResponseTime, Status ('Success')
        $isSuccess = if ($null -ne $result.Status) { $result.Status -eq 'Success' } else { $result.StatusCode -eq 0 }
        if ($result -and $isSuccess) {
            $rttMs = if ($null -ne $result.Latency) { $result.Latency } elseif ($null -ne $result.ResponseTime) { $result.ResponseTime } else { 0 }
            $success = $true
            $rttVal = if ($rttMs -eq 0) { '<1' } else { [string]$rttMs }
        }
    } catch {
        # Connection failed or timed out
    } finally {
        $sw.Stop()
    }

    if (-not $success) {
        $script:fuzzy_cnt++
        if ($script:fuzzy_cnt -gt $script:fuzzy_limit) {
            if ($script:health -eq 2) {
                $script:lastdowntime = [int][double]::Parse((Get-Date -UFormat %s))
                Write-Host -NoNewline "`e[u`e[K"
                if ($script:debug) { Write-Host -NoNewline "debug:STD;result=fail;health=$($script:health) " }
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | host $($script:targetHost) ($($script:targetHostdig)) is $($script:RED)down$($script:RESET)"
                Write-Host -NoNewline "`e[s"
                $script:health = 0
            } elseif ($script:health -eq 1) {
                $script:lastdowntime = [int][double]::Parse((Get-Date -UFormat %s))
                $script:upsec = [int][double]::Parse((Get-Date -UFormat %s)) - $script:lastuptime
                $script:uptotal += $script:upsec
                $script:flap++
                Write-Host -NoNewline "`e[u`e[K"
                if ($script:debug) { Write-Host -NoNewline "debug:UTD;result=fail;health=$($script:health) " }
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | host $($script:targetHost) ($($script:targetHostdig)) is $($script:RED)down$($script:RESET) [ok for $(Get-DisplayTime $script:upsec)]"
                Write-Host -NoNewline "`e[s"
                $script:health = 0
            } elseif ($script:health -eq 0 -and $script:follow -eq $true) {
                $script:downsec = [int][double]::Parse((Get-Date -UFormat %s)) - $script:lastdowntime
                Write-Host -NoNewline "`e[u`e[K"
                if ($script:debug) { Write-Host -NoNewline "debug:DTD;result=fail;health=$($script:health) " }
                Write-Host -NoNewline "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | host $($script:targetHost) ($($script:targetHostdig)) is $($script:RED)down$($script:RESET) for $(Get-DisplayTime $script:downsec)"
            }
        } else {
            if ($script:fuzzy_cnt -eq 1) {
                Write-Host -NoNewline " --FUZZY--"
            }
        }
        # Sleep only on instant errors (e.g. host unreachable); timeout already waited deadtime
        if ($sw.Elapsed.TotalSeconds -lt ($script:effectiveDeadtime * 0.8)) {
            Start-Sleep -Seconds $script:interval
        }
    } else {
        $script:received++
        $stat_cnt = $script:received % $script:statint
        if ($stat_cnt -eq 0) { $stat_cnt = $script:statint }
        $script:rtt[($script:received - 1) % $script:statint] = $rttVal

        if ($script:health -eq 2) {
            $script:lastuptime = [int][double]::Parse((Get-Date -UFormat %s))
            Write-Host -NoNewline "`e[u`e[K"
            if ($script:debug) { Write-Host -NoNewline "debug:STU;result=ok;health=$($script:health) " }
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | host $($script:targetHost) ($($script:targetHostdig)) is $($script:GREEN)ok$($script:RESET) | RTT ${rttVal}ms"
            Write-Host -NoNewline "`e[s"
            $script:health = 1
        } elseif ($script:health -eq 0) {
            Write-Host -NoNewline "`e[u`e[K"
            $script:downsec = [int][double]::Parse((Get-Date -UFormat %s)) - $script:lastdowntime
            $script:downtotal += $script:downsec
            $script:flap++
            if ($script:debug) { Write-Host -NoNewline "debug:DTU;result=ok;health=$($script:health) " }
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | host $($script:targetHost) ($($script:targetHostdig)) is $($script:GREEN)ok$($script:RESET) [down for $(Get-DisplayTime $script:downsec)] | RTT ${rttVal}ms"
            Write-Host -NoNewline "`e[s"
            $script:lastuptime = [int][double]::Parse((Get-Date -UFormat %s))
            $script:health = 1
        } elseif ($script:health -eq 1 -and $script:follow -eq $true) {
            $script:upsec = [int][double]::Parse((Get-Date -UFormat %s)) - $script:lastuptime
            Write-Host -NoNewline "`e[u`e[K"
            if ($script:debug) { Write-Host -NoNewline "debug:UTU;result=ok;health=$($script:health) " }
            Write-Host -NoNewline "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | host $($script:targetHost) ($($script:targetHostdig)) is $($script:GREEN)ok$($script:RESET) for $(Get-DisplayTime $script:upsec) | RTT ${rttVal}ms"
        }

        if ($stat_cnt -eq 0) {
            Invoke-CalcStatistics
        }

        if ($script:fuzzy_limit -gt 0 -and $script:fuzzy_cnt -gt 0) {
            $script:fuzzy_total++
            $script:fuzzy_lost += $script:fuzzy_cnt
        }
        $script:fuzzy_cnt = 0

        Start-Sleep -Seconds $script:interval
    }
}
} finally {
    if ($script:mainLoopStarted) {
        Write-PrintStatistics
    }
}