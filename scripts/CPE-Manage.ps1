# CPE-Manage.ps1 — Detect & open TP-Link CPE, with safe PC IP prep/restore
# Location: C:\Users\Lenovo\PROJECTS\wifi_toolkit\scripts\CPE-Manage.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Info([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Cyan }
function Write-Ok  ([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Yellow }
function Write-Err ([string]$m){ Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Red }

$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptRoot
$LogsDir     = Join-Path $ProjectRoot 'logs'
if(-not (Test-Path $LogsDir)){ New-Item -ItemType Directory -Path $LogsDir | Out-Null }
$LogFile     = Join-Path $LogsDir ("CPE-Manage_{0}.log" -f (Get-Date -f yyyyMMdd))

Start-Transcript -Path $LogFile -Append -ErrorAction SilentlyContinue | Out-Null
try{
  Write-Host "=== CPE710 Manage Mode ===" -ForegroundColor White

  # 1) Choose the likely wired adapter (user usually plugs laptop -> injector -> CPE)
  $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -match 'Ethernet' } | Select-Object -First 1
  if(-not $adapter){
    Write-Err "No active Ethernet adapter found. Plug into the CPE injector 'LAN' port and try again."
    return
  }
  Write-Info ("Using adapter: {0}" -f $adapter.Name)

  # 2) Ensure we’re on the 192.168.0.0/24 subnet (most TP-Link CPE default: 192.168.0.254)
  $nicIp = (Get-NetIPConfiguration -InterfaceAlias $adapter.Name).IPv4Address.IPAddress
  $hadDhcp = $false
  $original = $null

  if($nicIp -notlike '192.168.0.*'){
    Write-Warn "Adapter is not on 192.168.0.x; temporarily assigning a static IP 192.168.0.111/24..."
    $cfg = Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4
    if($cfg.Dhcp -eq 'Enabled'){ $hadDhcp = $true }

    $original = @{
      Dhcp = $cfg.Dhcp
      Address = $nicIp
      Prefix = (Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike '169.254.*'} | Select-Object -First 1).PrefixLength
      Gw = (Get-NetIPConfiguration -InterfaceAlias $adapter.Name).IPv4DefaultGateway.NextHop
    }

    # Remove old IPv4s (except link-local) to avoid duplicate bindings
    Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -notlike '169.254.*' } |
      Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress '192.168.0.111' -PrefixLength 24 -DefaultGateway '192.168.0.254' | Out-Null
    Write-Ok "Static IP applied on Ethernet temporarily."
    Start-Sleep -Milliseconds 500
  }else{
    Write-Ok "Adapter already on 192.168.0.x"
  }

  # 3) Ping the default CPE IP quickly; PS7 requires TimeoutSeconds >= 1
  $CpeIp = '192.168.0.254'
  Write-Info "Checking if CPE is answering at $CpeIp ..."
  $cpeUp = Test-Connection -Quiet -Count 1 -TimeoutSeconds 1 -Destination $CpeIp
  if(-not $cpeUp){
    Write-Warn "CPE not answering at $CpeIp – scanning 192.168.0.0/24 for live hosts (1–254)..."
    $live = @()
    1..254 | ForEach-Object {
      $ip = "192.168.0.$_"
      if(Test-Connection -Quiet -Count 1 -TimeoutSeconds 1 -Destination $ip){
        $live += $ip
        Write-Host ("  + Live: {0}" -f $ip) -ForegroundColor DarkGray
      }
    }
    if(-not $live){
      Write-Err "No live hosts found on 192.168.0.0/24. Check cabling/PoE/LEDs and try again."
      return
    }
    Write-Ok ("Found live host(s): {0}" -f ($live -join ', '))

    # Try to pick likely CPE by ARP vendor (TP-Link) — best-effort only
    $arp = arp -a | Select-String -Pattern 'dynamic|static' | ForEach-Object {
      $t = ($_ -replace '\s+',' ').Trim().Split(' ')
      [pscustomobject]@{ IP=$t[0]; MAC=$t[1].ToUpper() }
    }
    $tplinkOui = @('50-C7-BF','F4-F2-6D','E4-8D-8C','B0-4E-26','98-DE-D0','7C-8B-CA','28-D1-27','E8-94-F6','D8-0D-17')
    $cpeGuess = ($arp | Where-Object { $_.IP -in $live -and $_.MAC.Length -ge 8 -and $tplinkOui -contains $_.MAC.Substring(0,8) } | Select-Object -First 1).IP
    if($cpeGuess){ $CpeIp = $cpeGuess; Write-Ok "Guessing CPE = $CpeIp (by MAC vendor match)" }
    else{ $CpeIp = $live | Select-Object -First 1; Write-Warn "No TP-Link OUI match; using first live host: $CpeIp" }
  }else{
    Write-Ok "CPE responded at $CpeIp"
  }

  # 4) Open Web UI (recommended)
  $uiUrl = "http://$CpeIp"
  Write-Info "Opening CPE Web UI → $uiUrl"
  Start-Process $uiUrl

  Write-Host ""
  Write-Host "If you prefer SSH:" -ForegroundColor Yellow
  Write-Host "  ssh admin@$CpeIp" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Reminder:" -ForegroundColor Yellow
  Write-Host "• Keep the device set to your real country/region (e.g., Canada). Don't attempt to bypass regulatory limits." -ForegroundColor Yellow
  Write-Host "• If the park AP uses a channel your device can't use legally, they need to move to a permitted channel." -ForegroundColor Yellow

} finally {
  # 5) Offer to restore original NIC settings
  Write-Host ""
  $answer = Read-Host "Press Enter to restore your Ethernet settings (or type N to keep current)"
  if($answer -ne 'N' -and $answer -ne 'n'){
    try{
      if($original){
        Write-Info "Restoring previous IPv4 addresses..."
        Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike '169.254.*' } |
          Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        if($original.Dhcp -eq 'Enabled'){
          Set-NetIPInterface -InterfaceAlias $adapter.Name -Dhcp Enabled | Out-Null
          ipconfig /renew | Out-Null
          Write-Ok "DHCP restored."
        }else{
          # Best-effort restore
          New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $original.Address -PrefixLength ($original.Prefix ?? 24) -DefaultGateway $original.Gw -ErrorAction SilentlyContinue | Out-Null
          Write-Ok "Static IP restored."
        }
      }else{
        Write-Ok "No change was made earlier; nothing to restore."
      }
    }catch{
      Write-Err "Restore encountered an error: $($_.Exception.Message)"
    }
  }else{
    Write-Warn "Leaving current Ethernet settings as-is."
  }
  Stop-Transcript | Out-Null
}
