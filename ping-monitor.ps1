# Ping monitor pro dashboard – pinguje servery a zapisuje výsledek do ping.js vedle dashboardu.
# Spouštěj přes start-ping.cmd (běží skrytě na pozadí).

$Servers = [ordered]@{
  'NVMEDICALC1'       = '10.196.2.66'
  'NVMEDICALCAPP1'    = '10.196.2.68'
  'AmisPACS'          = '10.196.2.69'
  'eGateway - Mindray'= '10.196.2.70'
  'PACS plovoucí'     = '10.196.13.2'
  'PACS 1'            = '10.196.13.3'
  'PACS 2'            = '10.196.13.4'
  'ePACS'             = '10.196.13.5'
  'ORCZ PACS 2'       = '10.196.13.8'
  'ORCZ PACS 3'       = '10.196.13.9'
}
# Servery, na které z naší sítě nejde ping (ICMP jen z MGMT) – hlídají se přes TCP port
$TcpOnly   = @()
$TcpPorts  = @(3389, 445, 135, 139, 80, 443, 104, 11112, 22, 1433, 1521, 8080, 8443, 5985)
$TcpTimeoutMs = 1500
$RediscoverMin = 10    # jak často znovu hledat port u serverů, kde se žádný nenašel

$IntervalSec  = 15     # jak často pingat
$TimeoutMs    = 1500   # timeout jednoho pingu
$FailsToAlarm = 2      # kolikrát po sobě musí selhat, než se hlásí výpadek

# jen jedna instance
$mutex = New-Object System.Threading.Mutex($false, 'Local\DashboardPingMonitor')
if (-not $mutex.WaitOne(0)) { exit }

$OutFile = Join-Path $PSScriptRoot 'ping.js'
$TmpFile = "$OutFile.tmp"
$fails = @{}; $since = @{}; $tcpPort = @{}; $lastDiscover = @{}

# Spustí TCP připojení na více (ip,port) najednou a vrátí ty, které se připojily
function Test-TcpMany($pairs, $timeoutMs) {
  $att = foreach ($pr in $pairs) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [pscustomobject]@{ Ip = $pr.Ip; Port = $pr.Port; Client = $c; Task = $c.ConnectAsync($pr.Ip, [int]$pr.Port); Sw = $sw }
  }
  if (-not $att) { return @() }
  try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]($att.Task), $timeoutMs) } catch { }
  $ok = foreach ($a in $att) {
    if ($a.Task.IsCompleted -and -not $a.Task.IsFaulted -and $a.Client.Connected) {
      [pscustomobject]@{ Ip = $a.Ip; Port = $a.Port; Ms = [int]$a.Sw.ElapsedMilliseconds }
    }
  }
  foreach ($a in $att) { try { $a.Client.Close() } catch { } }
  return @($ok)
}

while ($true) {
  # --- TCP: hledání portu (u serverů bez známého portu) ---
  $now = Get-Date
  $toDiscover = @($TcpOnly | Where-Object { -not $tcpPort.ContainsKey($_) -and ((-not $lastDiscover.ContainsKey($_)) -or (($now - $lastDiscover[$_]).TotalMinutes -ge $RediscoverMin)) })
  if ($toDiscover.Count) {
    $pairs = foreach ($ip in $toDiscover) { foreach ($pt in $TcpPorts) { [pscustomobject]@{ Ip = $ip; Port = $pt } } }
    $found = Test-TcpMany $pairs $TcpTimeoutMs
    foreach ($ip in $toDiscover) {
      $lastDiscover[$ip] = $now
      $hit = $found | Where-Object { $_.Ip -eq $ip } | Select-Object -First 1
      if ($hit) { $tcpPort[$ip] = $hit.Port }
    }
  }
  # --- TCP: kontrola známých portů ---
  $tcpRes = @{}
  $known = @($TcpOnly | Where-Object { $tcpPort.ContainsKey($_) })
  if ($known.Count) {
    $res = Test-TcpMany @(foreach ($ip in $known) { [pscustomobject]@{ Ip = $ip; Port = $tcpPort[$ip] } }) $TcpTimeoutMs
    foreach ($ip in $known) { $tcpRes[$ip] = $res | Where-Object { $_.Ip -eq $ip } | Select-Object -First 1 }
  }

  # --- ICMP ping pro ostatní ---
  $jobs = foreach ($s in $Servers.GetEnumerator()) {
    if ($TcpOnly -contains $s.Value) { [pscustomobject]@{ Name = $s.Key; Ip = $s.Value; Task = $null }; continue }
    $p = New-Object System.Net.NetworkInformation.Ping
    [pscustomobject]@{ Name = $s.Key; Ip = $s.Value; Task = $p.SendPingAsync($s.Value, $TimeoutMs) }
  }
  $pingTasks = @($jobs | Where-Object { $_.Task } | ForEach-Object { $_.Task })
  if ($pingTasks.Count) { try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$pingTasks) } catch { } }

  $hosts = foreach ($j in $jobs) {
    $ok = $false; $ms = $null; $method = 'ping'; $port = $null
    if ($TcpOnly -contains $j.Ip) {
      $method = 'tcp'
      if (-not $tcpPort.ContainsKey($j.Ip)) {
        [ordered]@{ name = $j.Name; ip = $j.Ip; ok = $true; unknown = $true; method = 'tcp'; ms = $null; port = $null; since = $null }
        continue
      }
      $port = $tcpPort[$j.Ip]; $r = $tcpRes[$j.Ip]
      if ($r) { $ok = $true; $ms = $r.Ms }
    }
    elseif (-not $j.Task.IsFaulted -and $j.Task.Result.Status -eq 'Success') { $ok = $true; $ms = [int]$j.Task.Result.RoundtripTime }
    if ($ok) { $fails[$j.Ip] = 0; $since.Remove($j.Ip) }
    else {
      $fails[$j.Ip] = 1 + [int]$fails[$j.Ip]
      if (-not $since.ContainsKey($j.Ip)) { $since[$j.Ip] = (Get-Date).ToString('o') }
    }
    $isDown = (-not $ok) -and ($fails[$j.Ip] -ge $FailsToAlarm)
    [ordered]@{ name = $j.Name; ip = $j.Ip; ok = (-not $isDown); method = $method; port = $port; ms = $ms; since = $(if ($isDown) { $since[$j.Ip] } else { $null }) }
  }

  $json = [ordered]@{ updated = (Get-Date).ToString('o'); hosts = @($hosts) } | ConvertTo-Json -Depth 4 -Compress
  [System.IO.File]::WriteAllText($TmpFile, "window.PING_DATA = $json;", (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Force $TmpFile $OutFile
  Start-Sleep -Seconds $IntervalSec
}
