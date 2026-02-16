param(
    [Parameter(Mandatory = $true)]
    [Alias("u")]
    [string]$Url,

    [Alias("s")]
    [int]$Status = 200,

    [Alias("t")]
    [string]$Text = "",

    [Alias("d")]
    [int]$Delay = 5,

    # 0 = retry forever (until success)
    [Alias("m")]
    [int]$MaxAttempts = 0,

    # How many redirects to follow (final status will be checked)
    [Alias("r")]
    [int]$MaxRedirections = 10
)

# ---- Setup & Validation ----
if ($Status -lt 100 -or $Status -gt 599) {
    throw "Status must be a valid HTTP status code (100-599)."
}
if ($Delay -lt 0) {
    throw "Delay must be >= 0."
}
if ($MaxAttempts -lt 0) {
    throw "MaxAttempts must be >= 0 (0 means infinite)."
}

$IsPS7 = $PSVersionTable.PSVersion.Major -ge 7

# TTY/interactive detection for single-line updates
$IsInteractive = $Host.Name -eq 'ConsoleHost'
try {
    if ([Console]::IsOutputRedirected) { $IsInteractive = $false }
} catch { } # Not all hosts expose Console

# ANSI escape for clearing line (works in typical terminals)
$esc = [char]27
function Show-Status([string]$msg) {
    if ($IsInteractive) {
        # \r carriage return then ESC[2K to clear the entire line; no newline
        Write-Host "`r$($esc)[2K$msg" -NoNewline
    } else {
        Write-Host $msg
    }
}

# Final stats always printed (success or failure)
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$attempt = 0
$retries = 0
$lastHttpCode = $null

# ---- Insecure TLS handling (PowerShell 5.1 fallback) ----
if (-not $IsPS7) {
    # Allow TLS 1.2 (avoid legacy protocols)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    # Trust all certificates (process-wide). Only do this if not already set.
    if (-not ("TrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

# ---- Single request invocation (returns status + body) ----
function Invoke-Request {
    param(
        [Parameter(Mandatory = $true)][string]$U
    )
    if ($IsPS7) {
        # In PS 7+ we can avoid throwing on non-success and skip cert checks
        $resp = Invoke-WebRequest -Uri $U -Method GET -MaximumRedirection $MaxRedirections `
                                  -SkipHttpErrorCheck `
                                  -SkipCertificateCheck `
                                  -ErrorAction Stop
        return [pscustomobject]@{
            Status  = [int]$resp.StatusCode
            Content = [string]$resp.Content
        }
    } else {
        try {
            $resp = Invoke-WebRequest -Uri $U -Method GET -MaximumRedirection $MaxRedirections -ErrorAction Stop
            return [pscustomobject]@{
                Status  = [int]$resp.StatusCode
                Content = [string]$resp.Content
            }
        } catch {
            # On error, extract HTTP status & body from the WebException.Response if present
            $webResp = $_.Exception.Response
            if ($null -ne $webResp -and $webResp -is [System.Net.HttpWebResponse]) {
                $status = [int]$webResp.StatusCode
                $body = ""
                try {
                    $stream = $webResp.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $body = $reader.ReadToEnd()
                        $reader.Dispose()
                        $stream.Dispose()
                    }
                } catch { }
                return [pscustomobject]@{ Status = $status; Content = $body }
            }
            # If we can't read a response at all, treat as unknown
            return [pscustomobject]@{ Status = -1; Content = "" }
        }
    }
}

# ---- Main loop ----
while ($true) {
    $attempt++
    $r = Invoke-Request -U $Url
    $lastHttpCode = $r.Status

    $statusOk = ($r.Status -eq $Status)
    $textOk = $true
    if ([string]::IsNullOrEmpty($Text) -eq $false) {
        # Literal contains (case-sensitive to mirror 'grep -Fq' default). Change to .IndexOf(..., OrdinalIgnoreCase) >= 0 if you want case-insensitive.
        $textOk = ($r.Content -ne $null -and $r.Content.Contains($Text))
    }

    if ($statusOk -and $textOk) {
        if ($IsInteractive) { Write-Host "" } # end the live-updating line with a newline
        Write-Host "Success: received expected status $Status" -ForegroundColor Green
        if ($Text) { Write-Host "Success: required text found" -ForegroundColor Green }
        break
    }

    # Compose failure reason for live status
    if (-not $statusOk -and -not $textOk -and $Text) {
        Show-Status "[attempt $attempt] HTTP $($r.Status) (expected $Status) and missing required text — retrying in ${Delay}s..."
    } elseif (-not $statusOk) {
        Show-Status "[attempt $attempt] HTTP $($r.Status) (expected $Status) — retrying in ${Delay}s..."
    } elseif (-not $textOk) {
        Show-Status "[attempt $attempt] Required text not found — retrying in ${Delay}s..."
    }

    # Stop if max attempts reached
    if ($MaxAttempts -ne 0 -and $attempt -ge $MaxAttempts) {
        if ($IsInteractive) { Write-Host "" } # finalize the live line
        Write-Host "Giving up after $attempt attempts. Last HTTP status: $lastHttpCode" -ForegroundColor Red
        $stopwatch.Stop()
        $retries = [Math]::Max(0, $attempt - 1)
        $elapsed = $stopwatch.Elapsed
        Write-Host "=== Statistics ==="
        Write-Host ("Attempts : {0}" -f $attempt)
        Write-Host ("Retries  : {0}" -f $retries)
        Write-Host ("Runtime  : {0:hh\:mm\:ss} ({1:N0}s)" -f $elapsed, [int][Math]::Round($elapsed.TotalSeconds))
        exit 1
    }

    Start-Sleep -Seconds $Delay
}

# ---- Final statistics (success path) ----
$stopwatch.Stop()
$retries = [Math]::Max(0, $attempt - 1)
$elapsed = $stopwatch.Elapsed
Write-Host "=== Statistics ==="
Write-Host ("Attempts : {0}" -f $attempt)
Write-Host ("Retries  : {0}" -f $retries)
Write-Host ("Runtime  : {0:hh\:mm\:ss} ({1:N0}s)" -f $elapsed, [int][Math]::Round($elapsed.TotalSeconds))
exit 0
