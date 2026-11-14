$ErrorActionPreference='Stop'
$script:SwitcherHome = Split-Path -Parent $PSCommandPath
$script:Profiles = @((Get-Content -LiteralPath (Join-Path $script:SwitcherHome 'models.json') -Raw | ConvertFrom-Json))
$script:ConnectionPath=Join-Path $script:SwitcherHome 'connection.json'
$script:SshDir=Join-Path $env:LOCALAPPDATA 'SparkSwitcher\ssh'
$script:SwitchSsh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
function Get-SwitcherProfile([string]$Key) {
  @($script:Profiles | Where-Object key -eq $Key)[0]
}
function Get-SwitcherConnection {
  if(!(Test-Path -LiteralPath $script:ConnectionPath -PathType Leaf)){
    throw '请复制 connection.example.json 为 connection.json，并填写双机直连配置。'
  }
  try{
    $settings=Get-Content -LiteralPath $script:ConnectionPath -Raw | ConvertFrom-Json
  }catch{
    throw '无法读取 connection.json。请检查 JSON 格式。'
  }
  $head=[string]$settings.headAddress
  $local=[string]$settings.localAddress
  $user=[string]$settings.sshUser
  $parsedHead=$null
  $parsedLocal=$null
  if($head -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
     $local -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
     ![Net.IPAddress]::TryParse($head,[ref]$parsedHead) -or
     ![Net.IPAddress]::TryParse($local,[ref]$parsedLocal) -or
     $parsedHead.ToString() -ne $head -or $parsedLocal.ToString() -ne $local -or
     $head -eq $local){
    throw '请在 connection.json 中填写两个不同的直连 IPv4 地址。'
  }
  if($user -cnotmatch '^[a-z_][a-z0-9_-]*$'){throw 'connection.json 中的 Spark SSH 用户名无效。'}
  [pscustomobject]@{target="$user@$head";localAddress=$local}
}
function Get-SwitcherSshArgs($Connection) {
  $kh=Join-Path $script:SshDir 'spark_known_hosts'
  $id=Join-Path $script:SshDir 'id_ed25519'
  if(!(Test-Path -LiteralPath $kh) -or !(Test-Path -LiteralPath $id)) { throw '没有安装直连 SSH 密钥，请先完成初始化。' }
  @('-n','-b',$Connection.localAddress,'-o','BatchMode=yes','-o','ConnectTimeout=6','-o','IdentitiesOnly=yes',
    '-o','StrictHostKeyChecking=yes','-o','HostKeyAlgorithms=ssh-ed25519','-o',"UserKnownHostsFile=$kh",
    '-o','ServerAliveInterval=12','-o','ServerAliveCountMax=3','-i',$id)
}
function New-SwitcherProcess([string[]]$Arguments) {
  if(@($Arguments | Where-Object { $_ -match '"' }).Count) { throw 'Unexpected quotation in SSH arguments' }
  $arg=($Arguments | ForEach-Object { if ($_ -match '\s') { '"'+$_+'"' } else { $_ } }) -join ' '
  $folder=Join-Path $script:SshDir 'logs'
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  $prefix=Join-Path $folder ([guid]::NewGuid().ToString('N'))
  $out=$prefix+'.out'
  $err=$prefix+'.err'
  $process=Start-Process -FilePath $script:SwitchSsh -ArgumentList $arg -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
  [pscustomobject]@{process=$process; stdout=$out; stderr=$err; started=[DateTime]::UtcNow}
}
function Start-SwitcherRequest {
  param([ValidateSet('status','switch','stop')][string]$Action,[ValidateSet('glm','deepseek','qwen')][string]$Model)
  $connection=Get-SwitcherConnection
  $arguments=@(Get-SwitcherSshArgs $connection)+@($connection.target,'sparkctl',$Action)
  if($Action -eq 'switch'){ if(!$Model){throw 'Missing model'}; $arguments+=@($Model) }
  New-SwitcherProcess $arguments
}
function Read-SwitcherRequest($Request) {
  if(!$Request.process.HasExited){throw 'SSH has not returned a result'}
  $Request.process.WaitForExit()
  $raw=[string](Get-Content -Raw -LiteralPath $Request.stdout -ErrorAction SilentlyContinue); if($raw){$raw=$raw.Trim()}
  $err=[string](Get-Content -Raw -LiteralPath $Request.stderr -ErrorAction SilentlyContinue); if($err){$err=$err.Trim()}
  $exitCode=$Request.process.ExitCode
  Stop-SwitcherProcess $Request
  if(!$raw) { throw ('Spark 未连接。检查直连网线和两台 Spark 是否开机。'+$(if($err){" "+$err})) }
  try{$data=$raw|ConvertFrom-Json -ErrorAction Stop}catch{throw "Spark 返回的状态无法读取（SSH $exitCode）。"}
  if($data.ok -eq $false){throw $(if($data.message){$data.message}elseif($data.error){$data.error}else{"Spark 拒绝操作（SSH $exitCode）。"})}
  if($exitCode){throw "Spark 状态查询失败（SSH $exitCode）。"}
  $data
}
function Start-SwitcherTunnel {
  # One SSH child owns the three loopback listeners across model switches.
  $connection=Get-SwitcherConnection
  $arguments=@(Get-SwitcherSshArgs $connection)+@('-N','-o','ExitOnForwardFailure=yes')
  foreach($p in $script:Profiles){
    $port=[int]$p.port
    $arguments+=@('-L',("127.0.0.1:{0}:127.0.0.1:{0}" -f $port))
  }
  New-SwitcherProcess ($arguments+@($connection.target))
}
function Stop-SwitcherProcess($Request) {
  if($Request -and $Request.process){try{if(!$Request.process.HasExited){$Request.process.Kill()}}catch{}; try{$Request.process.Dispose()}catch{}; Remove-Item -LiteralPath $Request.stdout,$Request.stderr -ErrorAction SilentlyContinue}
}
function Test-SwitcherApi([string]$Model) {
  $p=Get-SwitcherProfile $Model
  try {
    $r=[Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}/v1/models' -f $p.port))
    $r.Proxy=$null; $r.Timeout=2400; $r.ReadWriteTimeout=2400
    $res=$r.GetResponse()
    try {
      $reader=New-Object IO.StreamReader($res.GetResponseStream())
      try { $listing=$reader.ReadToEnd()|ConvertFrom-Json } finally { $reader.Dispose() }
      return ($listing.data.id -ccontains $p.id)
    } finally { $res.Dispose() }
  } catch { return $false }
}
