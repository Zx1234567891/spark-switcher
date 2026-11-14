# Spark-only client profiles. Dot-source on Windows PowerShell 5.1+.
# Existing ZCode/DSH/OpenCode settings and account credentials are not read or edited.
$script:SparkHarnessClientDir = $PSScriptRoot
$script:SparkHarnessRoot = Split-Path -Parent $script:SparkHarnessClientDir
. (Join-Path $PSScriptRoot 'ZCodeThinking.ps1')
. (Join-Path $PSScriptRoot 'OpenCodeThinking.ps1')

function Get-SparkHarnessField {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name,$Default=$null)
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } else {
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    }
    return $Default
}

function Get-SparkHarnessProfiles {
    param([object[]]$Profiles)
    $defaults = [ordered]@{
        'GLM-5.3-Flash-EXL3' = @{ key='glm'; port=8888; context=1048576; maxOutput=131072; name='GLM-5.3 Flash' }
        'deepseek-v4.1-flash' = @{ key='deepseek'; port=18888; context=1048576; maxOutput=393216; name='DeepSeek V4.1 Flash' }
        'qwen3.8-flash-next' = @{ key='qwen'; port=18300; context=262144; maxOutput=131072; name='Qwen3.8 Flash Next' }
    }
    if (!$Profiles) {
        $Profiles = @(foreach ($id in $defaults.Keys) {
            @{ id=$id; port=$defaults[$id].port }
        })
    }
    $seen = @{}
    $ports = @{}
    foreach ($entry in $Profiles) {
        $id = [string](Get-SparkHarnessField $entry id)
        if (!($defaults.Keys -ccontains $id) -or $seen.ContainsKey($id)) { throw "Unknown or duplicate Spark model: $id" }
        $seen[$id] = $true
        $d = $defaults[$id]
        $port = [int](Get-SparkHarnessField $entry port $d.port)
        $ctx = [int](Get-SparkHarnessField $entry context $d.context)
        $out = [int](Get-SparkHarnessField $entry maxOutput $d.maxOutput)
        if ($port -lt 1 -or $port -gt 65535 -or $ports.ContainsKey($port) -or $ctx -lt 1024 -or $out -lt 1 -or $out -gt $ctx) { throw "Invalid capacity or localhost port for $id" }
        $ports[$port] = $true
        [pscustomobject]@{ id=$id; port=$port; context=$ctx; maxOutput=$out; name=[string](Get-SparkHarnessField $entry name $d.name); key=$d.key; uri="http://127.0.0.1:$port/v1"; provider="spark-$($d.key)" }
    }
}

function Resolve-SparkHarnessSelection {
    param([Parameter(Mandatory)][string]$ModelId, [object[]]$Profiles)
    $all = @(Get-SparkHarnessProfiles -Profiles $Profiles)
    $selected = @($all | Where-Object { $_.id -ceq $ModelId })
    if ($selected.Count -ne 1) { throw "Select a configured Spark model first: $ModelId" }
    [pscustomobject]@{ all=$all; selected=$selected[0] }
}

function Get-SparkHarnessData {
    param([ValidateSet('ZCode','DeepSeekHarness','OpenCode')][string]$Harness,[string]$ModelKey,[switch]$Test)
    $area = if ($Test) { 'acceptance' } else { 'profiles' }
    $base = Join-Path $env:LOCALAPPDATA "SparkModelSwitcher\$area\$Harness\$ModelKey"
    if ($Test) { $base = Join-Path $base ([guid]::NewGuid().ToString('N')) }
    $null = New-Item -ItemType Directory -Force -Path $base
    $base
}

function Write-SparkHarnessJson {
    param([string]$Path, $Data)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $Data -Depth 36),[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($tmp,$Path,[NullString]::Value)
        } else {
            [IO.File]::Move($tmp,$Path)
        }
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function ConvertTo-SparkWindowsArg {
    param([AllowEmptyString()][string]$Value)
    # CommandLineToArgvW escaping; no command shell is used.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','$1$1')
    '"' + $escaped + '"'
}

function New-SparkHarnessProcessInfo {
    param([string]$File,[string[]]$Arguments,[string]$Workspace,[hashtable]$Environment,[switch]$Capture,[switch]$Console)
    $i = New-Object System.Diagnostics.ProcessStartInfo
    $i.FileName = $File
    $i.Arguments = (@(foreach ($a in $Arguments) { ConvertTo-SparkWindowsArg $a }) -join ' ')
    $i.WorkingDirectory = $Workspace
    $i.UseShellExecute = $false
    $i.CreateNoWindow = !$Console
    if ($Capture) {
        $i.RedirectStandardInput = $true
        $i.RedirectStandardOutput = $true
        $i.RedirectStandardError = $true
        $i.StandardOutputEncoding = [Text.Encoding]::UTF8
        $i.StandardErrorEncoding = [Text.Encoding]::UTF8
    }
    foreach ($n in $Environment.Keys) {
        if ($null -eq $Environment[$n]) { $i.EnvironmentVariables.Remove($n) }
        else { $i.EnvironmentVariables[$n] = [string]$Environment[$n] }
    }
    $i
}

function Test-SparkHarnessEndpoint {
    param([Parameter(Mandatory)]$Model)
    $request = [Net.HttpWebRequest]::Create("$($Model.uri)/models")
    $request.Proxy = $null
    $request.Timeout = 3500
    $request.ReadWriteTimeout = 3500
    try {
        $response = $request.GetResponse()
        try {
            $reader = [IO.StreamReader]::new($response.GetResponseStream(),[Text.Encoding]::UTF8)
            try { $data = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop }
            finally { $reader.Dispose() }
        } finally { $response.Dispose() }
    } catch {
        throw [Net.WebException]::new("Spark model $($Model.id) is not ready at $($Model.uri). Check the Ethernet SSH tunnel and wait for the model to finish loading.", $_.Exception)
    }
    if (@($data.data | ForEach-Object id) -cnotcontains $Model.id) {
        throw "Unexpected model at $($Model.uri); refused to open a different model."
    }
}

function Get-SparkHarnessProgram {
    param([ValidateSet('ZCode','DeepSeekHarness','OpenCode')][string]$Harness,[string]$InstallRoot=$script:SparkHarnessRoot)
    switch ($Harness) {
        'ZCode' {
            $candidates = @(
                (Join-Path $InstallRoot 'tools\zcode\ZCode.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\ZCode\ZCode.exe'),
                (Join-Path $env:ProgramFiles 'ZCode\ZCode.exe')
            )
            $exe = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
            if (!$exe.Count) { throw 'ZCode desktop is not installed.' }
            $cli = Join-Path (Split-Path -Parent $exe[0]) 'resources\glm\zcode.cjs'
            return @{ File=$exe[0]; Entry=$cli }
        }
        'DeepSeekHarness' {
            $node = Join-Path $InstallRoot 'tools\harness\node.exe'
            $cli = Join-Path $InstallRoot 'tools\harness\node_modules\@deepseek-ai\dsh\lib\bin.js'
            if (!(Test-Path -LiteralPath $node -PathType Leaf) -or !(Test-Path -LiteralPath $cli -PathType Leaf)) {
                throw 'The offline DeepSeek Harness runtime is missing; reinstall the Spark client package.'
            }
            return @{ File=$node; Entry=$cli }
        }
        'OpenCode' {
            $exe = Join-Path $InstallRoot 'tools\opencode\opencode.exe'
            if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The pinned offline OpenCode executable is missing; reinstall the Spark client package.' }
            return @{ File=$exe; Entry=$null }
        }
    }
}

function Get-SparkHarnessDesktopProgram {
    param([string]$InstallRoot=$script:SparkHarnessRoot)
    $candidates=@((Join-Path $InstallRoot 'tools\harness-desktop\DeepSeek Harness.exe'))
    $candidates+=@(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object {$_.DisplayName -eq 'DeepSeek Harness' -and $_.InstallLocation} |
        ForEach-Object {Join-Path $_.InstallLocation 'DeepSeek Harness.exe'})
    $candidates+=Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
    $exe=$candidates | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf} | Select-Object -First 1
    if(!$exe){throw 'DeepSeek Harness Desktop is not installed for this Windows user.'}
    $exe
}

function New-SparkHarnessConfiguration {
    param(
        [Parameter(Mandatory)][ValidateSet('ZCode','DeepSeekHarness','OpenCode')][string]$Harness,
        [Parameter(Mandatory)][string]$ModelId,[object[]]$Profiles,[switch]$Test,[switch]$Desktop
    )
    $s = Resolve-SparkHarnessSelection -ModelId $ModelId -Profiles $Profiles
    $m = $s.selected
    $all = $s.all
    $base = Get-SparkHarnessData -Harness $Harness -ModelKey $m.key -Test:$Test
    $envMap = @{
        NO_PROXY='localhost,127.0.0.1,::1'; HTTP_PROXY=$null; HTTPS_PROXY=$null; ALL_PROXY=$null
        OPENAI_API_KEY=$null; ANTHROPIC_API_KEY=$null; DEEPSEEK_API_KEY=$null; ZAI_API_KEY=$null; BIGMODEL_API_KEY=$null
        SPARK_LOCAL_API_KEY='local'
    }
    switch ($Harness) {
        'ZCode' {
            $zv2 = Join-Path $base '.zcode\v2'
            $rules = @(foreach ($p in $all) {
                @{
                    providerId=$p.provider; providerName="Spark $($p.name)"
                    config=@{ group='standard-personal'; access=@{type='api-key';apiKey='local'}; api=@{type='openai-chat-completions';baseUrl=$p.uri}; personalModelIds=@($p.id); modelOrder=@($p.id) }
                }
            })
            $modelRules = @(foreach ($p in $all) {
                @{
                    providerId=$p.provider; modelId=$p.id
                    config=@{
                        enabled=$true
                        properties=@{contextWindow=$p.context;supportsJsonSchemaOutput=$false}
                        optionSpecs=(Get-SparkZCodeOptionSpecs -ModelKey $p.key -MaxOutputTokens $p.maxOutput)
                    }
                }
            })
            $cfg = Join-Path $zv2 'provider_config.json'
            Write-SparkHarnessJson $cfg @{
                schemaVersion=1
                config=@{
                    providerOrder=@($all.provider)
                    providerConfigRules=@{providerRules=$rules}
                    modelConfigRules=@{providerModelRules=$modelRules;manualProviderModelRules=@()}
                    defaultModelSelection=@{providerId=$m.provider;modelId=$m.id}
                }
            }
            $setting = Join-Path $zv2 'setting.json'
            if (!(Test-Path -LiteralPath $setting)) {
                # Equivalent to "Use API key > Skip for now"; local providers satisfy the usable model check.
                Write-SparkHarnessJson $setting @{ providerFamilyDomain='bigmodel'; providerFamilyDomainMigrated=$true; providerFamilyDomainUpdatedAt=0; settingsSyncFirstRunPromptHandled=$true; autoDownloadAndInstallUpdates=$false; closeToTrayOnWindows=$false; locale='zh-CN'; localePreference='zh-CN' }
            }
            $envMap.ZCODE_DATA_BASE_DIR=$base
            $envMap.ZCODE_DESKTOP_HOME_DIR=$base
            $envMap.ZCODE_DESKTOP_USER_DATA_DIR=(Join-Path $base 'desktop')
            $envMap.ZCODE_DESKTOP_SESSION_DATA_DIR=(Join-Path $base 'desktop\session')
            $envMap.ZCODE_DESKTOP_APPLICATION_NAME="ZCode Spark $($m.key)"
            $envMap.ZCODE_PERSONAL_PROVIDER_CONFIG_FILE=$cfg
            $envMap.ZCODE_NO_PROXY='localhost,127.0.0.1,::1'
            if ($Test) {
                Write-SparkHarnessJson (Join-Path $base '.zcode\cli\config.json') @{
                    features=@{mcp=$false;subagent=$false;memory=$false;skill=$false}
                    memory=@{use=$false};plugins=@{enabled=$false};skills=@{enabled=$false};hooks=@{enabled=$false}
                }
                $envMap.ZCODE_STORAGE_DIR=(Join-Path $base 'agent')
            }
        }
        'DeepSeekHarness' {
            $providers = [ordered]@{}
            $thinkingLevels=@{
                glm=@{off=$null;low='low';high='high';max='max'}
                deepseek=@{off=$null;low='low';medium='medium';high='high';max='max'}
                qwen=@{off=$null;low='low';medium='medium';xhigh='xhigh'}
            }
            $thinkingDefaults=@{glm='high';deepseek='high';qwen='xhigh'}
            foreach ($p in $all) {
                $providers[$p.provider] = @{
                    displayName="Spark $($p.name)";apiKeyEnv='SPARK_LOCAL_API_KEY'; api='openai-completions';baseURL=$p.uri
                    reasoning=$thinkingDefaults[$p.key]
                    compat=@{
                        supportsDeveloperRole=$false;maxTokensField='max_tokens';thinkingFormat='chat-template'
                        chatTemplateKwargs=@{
                            enable_thinking=@{'$var'='thinking.enabled'}
                            reasoning_effort=@{'$var'='thinking.effort';omitWhenOff=$true}
                        }
                    }
                    models=@(@{id=$p.id;name=$p.name;contextWindow=$p.context;maxTokens=$p.maxOutput;input=@('text','image');reasoningEfforts=$thinkingLevels[$p.key]})
                    retryPolicy=@{mode='normal';maxRetries=0}
                }
            }
            $cfg = if($Desktop){Join-Path $base 'profiles\desktop\cordis.patch.yml'}else{Join-Path $base 'spark.cordis.yml'}
            # JSON is YAML 1.2; this avoids an external YAML emitter dependency.
            $patch = @(
                @{id='llm-pi-ai';config=@{providers=$providers}},
                @{id='agent-default-model';config=@{provider=$m.provider;model=$m.id}},
                @{id='llm-deepseek';disabled=$true},
                @{id='llm-deepseek-account';disabled=$true},
                @{id='session-log-deepseek';disabled=$true},
                @{id='session-telemetry-otel';disabled=$true},
                @{id='session-title-llm';disabled=$true}
            )
            if (!$Desktop -or !(Test-Path -LiteralPath $cfg -PathType Leaf)) {
                Write-SparkHarnessJson $cfg $patch
            }
            $envMap.DSH_HOME=$base
            $envMap.DSH_TELEMETRY_DISABLED='1'
        }
        'OpenCode' {
            $providers = [ordered]@{}
            foreach ($p in $all) {
                $models = @{}
                $models[$p.id] = @{
                    name=$p.name;tool_call=$true;reasoning=$true
                    limit=@{context=$p.context;output=$p.maxOutput}
                    variants=(Get-SparkOpenCodeThinkingVariants $p.key)
                }
                $providers[$p.provider] = @{name="Spark $($p.name)";npm='@ai-sdk/openai-compatible';options=@{baseURL=$p.uri;apiKey='local'};models=$models}
            }
            $cfg = Join-Path $base 'opencode.json'
            $options = @{
                '$schema'='https://opencode.ai/config.json';autoupdate=$false; model="$($m.provider)/$($m.id)"
                small_model="$($m.provider)/$($m.id)"; provider=$providers; enabled_providers=@($all.provider)
            }
            if ($Test) { $options.permission=@{'*'='deny'} }
            Write-SparkHarnessJson $cfg $options
            foreach ($pair in @(@('XDG_CONFIG_HOME','config'),@('XDG_DATA_HOME','data'),@('XDG_STATE_HOME','state'),@('XDG_CACHE_HOME','cache'))) {
                $envMap[$pair[0]]=Join-Path $base $pair[1]
            }
            $envMap.OPENCODE_CONFIG=$cfg
            $envMap.OPENCODE_CONFIG_CONTENT=$null
            $envMap.OPENCODE_CONFIG_DIR=$null
            $envMap.OPENCODE_DISABLE_MODELS_FETCH='1'
            $envMap.OPENCODE_DISABLE_AUTOUPDATE='1'
            $envMap.OPENCODE_DISABLE_PROJECT_CONFIG='1'
            $envMap.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=[string](($all | Measure-Object maxOutput -Maximum).Maximum)
            $envMap.OPENCODE_PURE='1'
        }
    }
    [pscustomobject]@{ model=$m; data=$base; config=$cfg; env=$envMap }
}

function Resolve-SparkHarnessWorkspace {
    param([string]$Workspace,[string]$Data)
    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace=Join-Path $Data 'workspace'
        $null=New-Item -ItemType Directory -Force -Path $Workspace
    }
    if (!(Test-Path -LiteralPath $Workspace -PathType Container)) { throw 'The selected workspace directory no longer exists.' }
    (Get-Item -LiteralPath $Workspace).FullName
}

function Start-SparkHarness {
    param(
        [Parameter(Mandatory)][ValidateSet('ZCode','DeepSeekHarness','OpenCode')][string]$Harness,
        [Parameter(Mandatory)][string]$ModelId,[string]$Workspace,[object[]]$Profiles,[string]$InstallRoot=$script:SparkHarnessRoot
    )
    $cfg = New-SparkHarnessConfiguration -Harness $Harness -ModelId $ModelId -Profiles $Profiles -Desktop:($Harness -eq 'DeepSeekHarness')
    Test-SparkHarnessEndpoint $cfg.model
    $folder = Resolve-SparkHarnessWorkspace -Workspace $Workspace -Data $cfg.data
    if($Harness -ne 'DeepSeekHarness'){$app=Get-SparkHarnessProgram -Harness $Harness -InstallRoot $InstallRoot}
    switch ($Harness) {
        'ZCode' {
            $cfg.env.ELECTRON_RUN_AS_NODE=$null
            $args=@('--open-workspace',$folder)
            $p=[Diagnostics.Process]::Start((New-SparkHarnessProcessInfo $app.File $args $folder $cfg.env))
        }
        'OpenCode' {
            # Visible console is the real OpenCode TUI.
            $args=@($folder,'--model',"$($cfg.model.provider)/$($cfg.model.id)")
            # Use ShellExecute to get a new console, even when the WinForms
            # launcher was started without a visible parent console.
            $prior=@{}
            try {
                foreach ($n in $cfg.env.Keys) {
                    $prior[$n]=[Environment]::GetEnvironmentVariable($n,'Process')
                    [Environment]::SetEnvironmentVariable($n,$cfg.env[$n],'Process')
                }
                $p=Start-Process -FilePath $app.File -ArgumentList (@(foreach($a in $args){ ConvertTo-SparkWindowsArg $a }) -join ' ') -WorkingDirectory $folder -WindowStyle Normal -PassThru
            } finally {
                foreach ($n in $prior.Keys) { [Environment]::SetEnvironmentVariable($n,$prior[$n],'Process') }
            }
        }
        'DeepSeekHarness' {
            $exe=Get-SparkHarnessDesktopProgram -InstallRoot $InstallRoot
            $userData=Join-Path $cfg.data 'desktop-shell'
            # Electron's instance lock is per user data directory; each model owns its profile and window.
            $args=@("--user-data-dir=$userData")
            $cfg.env.ELECTRON_RUN_AS_NODE=$null
            $p=[Diagnostics.Process]::Start((New-SparkHarnessProcessInfo $exe $args $folder $cfg.env))
        }
    }
    [pscustomobject]@{ harness=$Harness; model=$cfg.model.id; processId=$p.Id }
}

function Test-SparkHarness {
    param(
        [Parameter(Mandatory)][ValidateSet('ZCode','DeepSeekHarness','OpenCode')][string]$Harness,
        [Parameter(Mandatory)][string]$ModelId,[object[]]$Profiles,[ValidateRange(20,900)][int]$TimeoutSeconds=150,
        [string]$InstallRoot=$script:SparkHarnessRoot
    )
    $cfg = New-SparkHarnessConfiguration -Harness $Harness -ModelId $ModelId -Profiles $Profiles -Test
    Test-SparkHarnessEndpoint $cfg.model
    $app = Get-SparkHarnessProgram -Harness $Harness -InstallRoot $InstallRoot
    $folder = Resolve-SparkHarnessWorkspace -Data $cfg.data
    $tag='SPARK_OK_'+[guid]::NewGuid().ToString('N').Substring(0,9).ToUpperInvariant()
    $prompt="Connectivity test only. Reply exactly $tag. Do not call any tools or read files."
    switch ($Harness) {
        'ZCode' {
            if (!(Test-Path -LiteralPath $app.Entry -PathType Leaf)) { throw 'The installed ZCode does not contain the expected bundled agent CLI.' }
            $cfg.env.ELECTRON_RUN_AS_NODE='1'
            $builtin=Join-Path (Split-Path -Parent $app.File) 'resources\config\provider\zcode-builtin.json'
            if (!(Test-Path -LiteralPath $builtin -PathType Leaf)) { throw 'The installed ZCode is missing its bundled provider catalog.' }
            $cfg.env.ZCODE_BUILTIN_PROVIDER_CONFIG_FILE=$builtin
            $args=@($app.Entry,'--prompt',$prompt,'--cwd',$folder,'--mode','plan','--toolsearch-mode','off','--json','--no-color')
        }
        'DeepSeekHarness' {
            $cfg.env.PATH="$(Split-Path -Parent $app.File);$env:PATH"
            $args=@($app.Entry,'--profile','headless','--patch',$cfg.config,'--permission-mode','read-only','--approval-policy','never',$prompt)
        }
        'OpenCode' {
            $args=@('run','--pure','--model',"$($cfg.model.provider)/$($cfg.model.id)",'--agent','plan','--format','json','--dir',$folder,$prompt)
        }
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $process=[Diagnostics.Process]::Start((New-SparkHarnessProcessInfo $app.File $args $folder $cfg.env -Capture))
    if($process.StartInfo.RedirectStandardInput){$process.StandardInput.Close()}
    $output=$process.StandardOutput.ReadToEndAsync()
    $errors=$process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit($TimeoutSeconds*1000)) { try { $process.Kill() } catch {}; throw "$Harness test timed out after $TimeoutSeconds seconds." }
    $clock.Stop()
    if (!$output.Wait(4000) -or !$errors.Wait(4000)) { throw "$Harness test left its output streams open." }
    $stdout=$output.Result; $stderr=$errors.Result
    if ($process.ExitCode -ne 0) {
        $reason=($stderr -split '[\r\n]+' | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' '
        if ($reason.Length -gt 1700) { $reason=$reason.Substring(0,1700) }
        if (!$reason) { $reason=($stdout -split '[\r\n]+' | Select-Object -Last 4) -join ' '; if($reason.Length -gt 1300){$reason=$reason.Substring(0,1300)} }
        throw "$Harness test failed (exit $($process.ExitCode)): $reason"
    }
    $answer=''
    switch ($Harness) {
        'ZCode' {
            try { $j=ConvertFrom-Json -InputObject $stdout -ErrorAction Stop } catch { $j=$null }
            if ($null -ne $j) {
                $r=Get-SparkHarnessField $j response
                if ($r -is [string]) { $answer=$r }
            }
        }
        'DeepSeekHarness' { $answer=$stdout.Trim() }
        'OpenCode' {
            $parts=@(foreach ($line in ($stdout -split '[\r\n]+')) {
                try { $j=ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
                if ($j.type -eq 'text') { $j.part.text }
            })
            $answer=$parts -join ''
        }
    }
    if ($answer.Trim().Trim([char[]]@(96,34,39,46)) -cne $tag) {
        $show=$answer; if ($show.Length -gt 350) { $show=$show.Substring(0,350) }
        throw "$Harness gave an unexpected reply (expected $tag): $show"
    }
    $report=[pscustomobject]@{ ok=$true; harness=$Harness; model=$cfg.model.id; reply=$answer.Trim(); elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,2); verifiedAt=[DateTime]::Now.ToString('o') }
    Write-SparkHarnessJson (Join-Path $cfg.data 'acceptance.json') $report
    $report
}
