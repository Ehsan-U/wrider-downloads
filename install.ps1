# Run from PowerShell:
# irm https://raw.githubusercontent.com/Ehsan-U/wrider-downloads/main/install.ps1 | iex
# Keep the outer block and final blank line: piped PowerShell must receive the
# complete script before it performs any installation steps.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $temporary = $null
    try {
        if ($env:OS -ne 'Windows_NT') { throw 'WRider requires Windows.' }
        if (Get-Service -Name WRider -ErrorAction SilentlyContinue) {
            return
        }

        Add-Type -AssemblyName System.Net.Http
        function Get-WRiderDownload {
            param([Uri]$Uri, [string]$Destination, [Int64]$MaximumBytes, [int]$TimeoutSeconds)
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(20)
            $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
            $expired = [Threading.Tasks.Task]::Delay(-1, $deadline.Token)
            $response = $null
            $source = $null
            $output = $null
            try {
                for ($redirects = 0; $redirects -le 10; $redirects++) {
                    if ($Uri.Scheme -ne 'https' -or $Uri.UserInfo -ne '') {
                        throw 'Downloads require HTTPS without embedded credentials.'
                    }
                    $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
                    if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                        if ($redirects -eq 10 -or -not $response.Headers.Location) {
                            throw 'Invalid download redirect.'
                        }
                        $Uri = [Uri]::new($Uri, $response.Headers.Location)
                        $response.Dispose()
                        $response = $null
                        continue
                    }
                    $response.EnsureSuccessStatusCode() | Out-Null
                    if ($null -ne $response.Content.Headers.ContentLength -and
                        $response.Content.Headers.ContentLength -gt $MaximumBytes) {
                        throw 'Download exceeds its size limit.'
                    }
                    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $output = [IO.File]::Create($Destination)
                    $buffer = New-Object byte[] 65536
                    [Int64]$total = 0
                    while ($true) {
                        $read = $source.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token)
                        # Framework streams may ignore cancellation after starting a read.
                        [Threading.Tasks.Task]::WhenAny([Threading.Tasks.Task[]]@($read, $expired)).GetAwaiter().GetResult() | Out-Null
                        $deadline.Token.ThrowIfCancellationRequested()
                        $count = $read.GetAwaiter().GetResult()
                        if ($count -eq 0) { break }
                        $total += $count
                        if ($total -gt $MaximumBytes) { throw 'Download exceeds its size limit.' }
                        $output.Write($buffer, 0, $count)
                    }
                    return
                }
            } finally {
                if ($output) { $output.Dispose() }
                if ($source) { $source.Dispose() }
                if ($response) { $response.Dispose() }
                $client.Dispose()
                $deadline.Dispose()
            }
        }
        if (-not ('WRider.Bootstrap.Native' -as [Type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WRider.Bootstrap {
    public static class Native {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    }
}
'@
        }
        [UInt16]$processMachine = 0
        [UInt16]$nativeMachine = 0
        if (-not [WRider.Bootstrap.Native]::IsWow64Process2([IntPtr]::new(-1), [ref]$processMachine, [ref]$nativeMachine)) {
            throw 'Could not detect the Windows architecture.'
        }
        $runtime = switch ($nativeMachine) {
            0x8664 { 'win-x64' }
            0xaa64 { 'win-arm64' }
            default { throw 'WRider supports x64 and ARM64 Windows only.' }
        }

        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('WRider-Install-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary | Out-Null
        $manifestFile = Join-Path $temporary 'install.json'
        $manifestUrl = 'https://raw.githubusercontent.com/Ehsan-U/wrider-downloads/main/install.json'
        try {
            Get-WRiderDownload -Uri $manifestUrl -Destination $manifestFile -MaximumBytes 65536 -TimeoutSeconds 60
        } catch { throw 'Could not download the WRider release information. Please retry.' }
        $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1) { throw 'Unsupported WRider install manifest.' }
        $asset = $manifest.assets.$runtime
        [Uri]$url = $null
        [Int64]$length = 0
        if (-not $asset -or -not [Int64]::TryParse([string]$asset.length, [ref]$length) -or
            $length -lt 1024 -or $length -gt 536870912 -or
            [string]$asset.sha256 -notmatch '\A[a-fA-F0-9]{64}\z' -or
            -not [Uri]::TryCreate([string]$asset.url, [UriKind]::Absolute, [ref]$url) -or
            $url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.UserInfo -ne '' -or
            $url.Query -ne '' -or $url.Fragment -ne '' -or
            -not $url.AbsolutePath.StartsWith('/Ehsan-U/wrider-downloads/releases/download/', [StringComparison]::Ordinal) -or
            [IO.Path]::GetFileName($url.AbsolutePath) -ne "WRider-Setup-$runtime.exe") {
            throw 'The WRider release information is invalid.'
        }

        $installer = Join-Path $temporary "WRider-Setup-$runtime.exe"
        try {
            Get-WRiderDownload -Uri $url -Destination $installer -MaximumBytes $length -TimeoutSeconds 600
        } catch { throw 'Could not download WRider. Please retry.' }
        if ((Get-Item -LiteralPath $installer).Length -ne $length -or
            (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $asset.sha256) {
            throw 'WRider installer verification failed. Nothing was installed.'
        }

        $setup = Start-Process -FilePath $installer -ArgumentList '--wait' -PassThru -Wait
        if ($setup.ExitCode -ne 0) { throw 'WRider installation failed or administrator approval was cancelled.' }
        foreach ($name in @('WRider', 'WRiderUpdater')) {
            $service = Get-Service -Name $name -ErrorAction Stop
            if ($service.Status -ne 'Running') { throw "The $name service did not start." }
        }
    } catch {
        [Console]::Error.WriteLine('WRider: ' + $_.Exception.Message)
        exit 1
    } finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# End of bootstrap.
