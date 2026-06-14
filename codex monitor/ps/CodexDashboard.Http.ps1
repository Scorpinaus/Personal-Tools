# Dot-sourced by codex_usage_dashboard.ps1. Keep this file free of entry-point side effects.

function Open-DashboardUrl {
    param([string]$Url)

    $candidates = @(
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:ProgramFiles "Mozilla Firefox\firefox.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox\firefox.exe")
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            Start-Process -FilePath $candidate -ArgumentList @($Url)
            return $true
        }
    }

    foreach ($commandName in @("msedge.exe", "chrome.exe", "firefox.exe")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            Start-Process -FilePath $command.Source -ArgumentList @($Url)
            return $true
        }
    }

    return $false
}

function Write-TcpHttpResponse {
    param(
        [System.Net.Sockets.TcpClient]$Client,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Body
    )

    $reason = switch ($StatusCode) {
        200 { "OK" }
        404 { "Not Found" }
        405 { "Method Not Allowed" }
        500 { "Internal Server Error" }
        default { "OK" }
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    try {
        if (-not $Client.Connected) {
            return
        }

        $stream = $Client.GetStream()
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()
    }
    catch [System.InvalidOperationException] {
        return
    }
    catch [System.IO.IOException] {
        return
    }
    catch [System.Net.Sockets.SocketException] {
        return
    }
}

function Test-TcpTimeoutException {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Get-TcpHttpRequest {
    param([System.Net.Sockets.TcpClient]$Client)

    $stream = $Client.GetStream()
    $Client.ReceiveTimeout = 75
    $firstByte = $stream.ReadByte()
    if ($firstByte -lt 0) {
        return $null
    }

    $isAsciiLetter = ($firstByte -ge 65 -and $firstByte -le 90) -or ($firstByte -ge 97 -and $firstByte -le 122)
    if (-not $isAsciiLetter) {
        return $null
    }

    $Client.ReceiveTimeout = 1000
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    $bytes.Add([byte]$firstByte) | Out-Null
    $maxHeaderBytes = 16384
    while ($bytes.Count -lt $maxHeaderBytes) {
        $nextByte = $stream.ReadByte()
        if ($nextByte -lt 0) {
            break
        }

        $bytes.Add([byte]$nextByte) | Out-Null
        $count = $bytes.Count
        if (
            ($count -ge 4 -and $bytes[($count - 4)] -eq 13 -and $bytes[($count - 3)] -eq 10 -and $bytes[($count - 2)] -eq 13 -and $bytes[($count - 1)] -eq 10) -or
            ($count -ge 2 -and $bytes[($count - 2)] -eq 10 -and $bytes[($count - 1)] -eq 10)
        ) {
            break
        }
    }

    $requestText = [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
    $requestLine = ($requestText -split "\r?\n", 2)[0]
    if ([string]::IsNullOrWhiteSpace($requestLine)) {
        return $null
    }

    $parts = $requestLine -split "\s+"
    if ($parts.Count -lt 2) {
        return [pscustomobject]@{
            Method = "GET"
            Path = "/"
        }
    }

    $path = "/"
    try {
        $path = ([System.Uri]::new(("http://localhost" + $parts[1]))).AbsolutePath
    }
    catch {
        $path = "/"
    }

    return [pscustomobject]@{
        Method = $parts[0].ToUpperInvariant()
        Path = $path
    }
}
