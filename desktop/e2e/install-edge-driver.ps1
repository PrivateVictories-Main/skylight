# WebView2's driver must match its runtime, which can differ from installed Edge.
# Download only Microsoft's driver; no browser profiles or credentials are read.
$ErrorActionPreference = 'Stop'
$client = 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$version = $null
foreach ($prefix in @('HKLM:\SOFTWARE\WOW6432Node\', 'HKLM:\SOFTWARE\', 'HKCU:\SOFTWARE\WOW6432Node\', 'HKCU:\SOFTWARE\')) {
    $item = Get-ItemProperty -Path ($prefix + $client) -ErrorAction SilentlyContinue
    if ($item.pv -match '^\d+\.\d+\.\d+\.\d+$' -and $item.pv -ne '0.0.0.0') {
        $version = $item.pv
        break
    }
}
if (-not $version) { throw 'WebView2 runtime not found' }
$driverDirectory = Join-Path $env:RUNNER_TEMP 'skylight-edge-driver'
New-Item -ItemType Directory -Force -Path $driverDirectory | Out-Null
$archive = Join-Path $driverDirectory 'driver.zip'
Write-Host "Matching WebView2 $version"
Invoke-WebRequest -Uri "https://msedgedriver.microsoft.com/$version/edgedriver_win64.zip" -OutFile $archive
Expand-Archive -Path $archive -DestinationPath $driverDirectory -Force
$driverDirectory | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
& (Join-Path $driverDirectory 'msedgedriver.exe') --version
