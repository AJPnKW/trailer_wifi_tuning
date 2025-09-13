# CPE-HealthSnapshot.ps1 — Capture local + LAN health for quick triage
# Location: C:\Users\Lenovo\PROJECTS\wifi_toolkit\scripts\CPE-HealthSnapshot.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Cyan }
function Write-Ok  ([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Yellow }
function Write-Err ([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Red }

$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptRoot
$ReportsDir  = Join-Path $ProjectRoot 'reports'
$LogsDir     = Join-Path $ProjectRoot 'logs'
if(-not (Test-Path $ReportsDir)){ New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
if(-not (Test-Path $LogsDir)){ New-Item -ItemType Directory -Path $LogsDir | Out-Null }

$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
$report   = Join-Path $ReportsDir ("CPE_Health_$ts.txt")
$histlog  = Join-Path $LogsDir 'health_history.log'

Write-Info "Capturing CPE/Network health -> $report"

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("WiFi Toolkit — CPE Health Snapshot")
$null = $sb.AppendLine("Time: $(Get-Date)")
$null = $sb.AppendLine("------------------------------------------------------------")

# Active adapters
$null = $sb.AppendLine("== Adapters (Up) ==")
(Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Sort-Object Name | Format-Table -AutoSize | Out-String).Trim() | ForEach-Object { $null = $sb.AppendLine($_) }

# IP config
$null = $sb.AppendLine("")
$null = $sb.AppendLine("== ipconfig /all =="")
(ipconfig /all | Out-String).Trim() | ForEach-Object { $null = $sb.AppendLine($_) }

# Routes
$null = $sb.AppendLine("")
$null = $sb.AppendLine("== Route print =="")
(route print | Out-String).Trim() | ForEach-Object { $null = $sb.AppendLine($_) }

# ARP table
$null = $sb.AppendLine("")
$null = $sb.AppendLine("== ARP -a =="")
(arp -a | Out-String).Trim() | ForEach-Object { $null = $sb.AppendLine($_) }

# Optional WLAN info if present
try{
  $null = $sb.AppendLine("")
  $null = $sb.AppendLine("== netsh wlan show interfaces =="")
  (netsh wlan show interfaces | Out-String).Trim() | ForEach-Object { $null = $sb.AppendLine($_) }

  $null = $sb.AppendLine("")
  $null = $sb.AppendLine("== netsh wlan show networks mode=bssid =="")
  (netsh wlan show networks mode=bssid | Out-String).Trim() | ForEach-Object { $null = $sb.AppendLine($_) }
}catch{}

# Quick reachability tests
function TryPing($host){
  try {
    if(Test-Connection -Quiet -Count 1 -TimeoutSeconds 2 -Destination $host){ "OK" } else { "FAIL" }
  } catch { "ERR" }
}

$null = $sb.AppendLine("")
$null = $sb.AppendLine("== Quick Pings ==")
$targets = @(
  @{ Name='CPE default'; Host='192.168.0.254' },
  @{ Name='Gateway 1';   Host='192.168.1.1'   },
  @{ Name='Gateway 2';   Host='192.168.2.1'   }
)
foreach($t in $targets){
  $status = TryPing $t.Host
  $null = $sb.AppendLine(("{0,-14} {1,-16} : {2}" -f $t.Name,$t.Host,$status))
}

# DNS test
$null = $sb.AppendLine("")
$null = $sb.AppendLine("== DNS quick test ==")
try{
  $name = "www.tp-link.com"
  $A = (Resolve-DnsName $name -ErrorAction Stop | Where-Object {$_.Type -eq 'A'} | Select-Object -First 1).IPAddress
  $null = $sb.AppendLine("$name -> $A")
}catch{
  $null = $sb.AppendLine("DNS resolve failed: $($_.Exception.Message)")
}

# Save
$sb.ToString() | Set-Content -Encoding UTF8 $report
Write-Ok "Report saved: $report"

# Append brief line to history
"[{0}] Health snapshot -> {1}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $report | Add-Content -Path $histlog -Encoding UTF8
