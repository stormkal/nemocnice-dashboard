# Ping monitor pro dashboard – pinguje servery a zapisuje výsledek do ping.js vedle dashboardu.
# Spouštěj přes start-ping.cmd (běží skrytě na pozadí).

$Servers = [ordered]@{
  'NVMEDICALC1'       = '10.196.2.66'
  'NVMEDICALC2'       = '10.196.2.67'
  'NVMEDICALCAPP1'    = '10.196.2.68'
  'AmisPACS'          = '10.196.2.69'
  'eGateway - Mindray'= '10.196.2.70'
  'ISAC'              = '10.196.2.71'
  'PACS plovoucí'     = '10.196.13.2'
  'PACS 1'            = '10.196.13.3'
  'PACS 2'            = '10.196.13.4'
  'ePACS'             = '10.196.13.5'
  'eHealth'           = '10.196.13.6'
  'ORCZ PACS 1'       = '10.196.13.7'
  'ORCZ PACS 2'       = '10.196.13.8'
  'ORCZ PACS 3'       = '10.196.13.9'
}
$IntervalSec  = 15     # jak často pingat
$TimeoutMs    = 1500   # timeout jednoho pingu
$FailsToAlarm = 2      # kolikrát po sobě musí selhat, než se hlásí výpadek

# jen jedna instance
$mutex = New-Object System.Threading.Mutex($false, 'Local\DashboardPingMonitor')
if (-not $mutex.WaitOne(0)) { exit }

$OutFile = Join-Path $PSScriptRoot 'ping.js'
$TmpFile = "$OutFile.tmp"
$fails = @{}; $since = @{}

while ($true) {
  $jobs = foreach ($s in $Servers.GetEnumerator()) {
    $p = New-Object System.Net.NetworkInformation.Ping
    [pscustomobject]@{ Name = $s.Key; Ip = $s.Value; Task = $p.SendPingAsync($s.Value, $TimeoutMs) }
  }
  try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]($jobs.Task)) } catch { }

  $hosts = foreach ($j in $jobs) {
    $ok = $false; $ms = $null
    if (-not $j.Task.IsFaulted -and $j.Task.Result.Status -eq 'Success') { $ok = $true; $ms = [int]$j.Task.Result.RoundtripTime }
    if ($ok) { $fails[$j.Ip] = 0; $since.Remove($j.Ip) }
    else {
      $fails[$j.Ip] = 1 + [int]$fails[$j.Ip]
      if (-not $since.ContainsKey($j.Ip)) { $since[$j.Ip] = (Get-Date).ToString('o') }
    }
    $isDown = (-not $ok) -and ($fails[$j.Ip] -ge $FailsToAlarm)
    [ordered]@{ name = $j.Name; ip = $j.Ip; ok = (-not $isDown); ms = $ms; since = $(if ($isDown) { $since[$j.Ip] } else { $null }) }
  }

  $json = [ordered]@{ updated = (Get-Date).ToString('o'); hosts = @($hosts) } | ConvertTo-Json -Depth 4 -Compress
  [System.IO.File]::WriteAllText($TmpFile, "window.PING_DATA = $json;", (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Force $TmpFile $OutFile
  Start-Sleep -Seconds $IntervalSec
}
