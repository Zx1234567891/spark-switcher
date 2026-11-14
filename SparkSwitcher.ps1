param([switch]$Check,[string]$PreviewPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
if($Check){
    $request=Start-SwitcherRequest status
    if(!$request.process.WaitForExit(12000)){Stop-SwitcherProcess $request;throw 'Spark did not return status'}
    Read-SwitcherRequest $request | ConvertTo-Json -Depth 12
    exit
}

. (Join-Path $PSScriptRoot 'clients\Harness.ps1')
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Net.Http

$layoutPath=Join-Path $PSScriptRoot 'SwitcherWindow.xaml'
$reader=[Xml.XmlReader]::Create($layoutPath)
try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}

$cards=[ordered]@{
    glm=$window.FindName('GlmCard')
    deepseek=$window.FindName('DeepseekCard')
    qwen=$window.FindName('QwenCard')
}
$modelStates=@{
    glm=$window.FindName('GlmState')
    deepseek=$window.FindName('DeepseekState')
    qwen=$window.FindName('QwenState')
}
$launchButtons=@(
    $window.FindName('ZcodeButton')
    $window.FindName('HarnessButton')
    $window.FindName('OpencodeButton')
)
$activeLabel=$window.FindName('ActiveLabel')
$linkLabel=$window.FindName('ConnectionLabel')
$linkDot=$window.FindName('LinkDot')
$notice=$window.FindName('Notice')
$working=$window.FindName('Working')
$switchButton=$window.FindName('SwitchButton')
$stopButton=$window.FindName('StopButton')
$refreshButton=$window.FindName('RefreshButton')
$chooseButton=$window.FindName('ChooseButton')
$projectLabel=$window.FindName('ProjectLabel')
$logos=[ordered]@{
    XidianLogo='xidian'
    CyberLogo='cyberchangan'
    GlmLogo='glm'
    DeepseekLogo='deepseek'
    QwenLogo='qwen'
    ZcodeLogo='zcode'
    HarnessLogo='deepseek-harness'
    OpencodeLogo='opencode'
}
foreach($name in $logos.Keys){
    $image=$window.FindName($name)
    $path=Join-Path $PSScriptRoot ('assets\'+$logos[$name]+'.png')
    if(Test-Path -LiteralPath $path -PathType Leaf){
        $bitmap=[Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit()
        $bitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource=[Uri]::new($path,[UriKind]::Absolute)
        $bitmap.EndInit()
        $bitmap.Freeze()
        $image.Source=$bitmap
        if($name -eq 'XidianLogo'){$window.Icon=$bitmap}
    }else{
        $image.Visibility='Collapsed'
    }
}
$brush=[Windows.Media.BrushConverter]::new()
$linkReady=$brush.ConvertFromString('#8CE0BB')
$linkIdle=$brush.ConvertFromString('#E4A9C0')
$phaseLabels=@{
    queued='等待启动任务'
    validating='检查两台 Spark 和本地模型文件'
    draining='等待当前请求结束'
    stopping='释放原模型占用的内存'
    starting='正在两台 Spark 上加载模型'
    verifying='验证模型能否正常回复'
    rollback='正在恢复原模型'
}
$jobErrors=@{
    failed='操作失败'
    rolled_back='切换失败，已恢复原模型'
    interrupted='操作中断，请查看状态'
}
$toolNames=@{ZCode='ZCode';DeepSeekHarness='DeepSeek Harness';OpenCode='OpenCode'}

$script:status=$null
$script:req=$null
$script:requestKind=''
$script:tunnel=$null
$script:nextPoll=[DateTime]::MinValue
$script:nextTunnel=[DateTime]::MinValue
$script:optimisticUntil=[DateTime]::MinValue
$script:tunnelError=''
$script:lastNotice=''
$script:lastError=''
$script:lastActive=$null
$script:workspace=$null
$script:apiModel=$null
$script:apiReady=$false
$script:apiProbe=$null
$script:nextApiProbe=[DateTime]::MinValue

function Update-SwitcherApi([DateTime]$Now) {
    $model=$script:status.active
    if(!$script:tunnel -or $script:tunnel.process.HasExited -or $script:status.job.state -eq 'running'){$model=$null}
    if($model -ne $script:apiModel){
        $script:apiModel=$model
        $script:apiReady=$false
        $script:apiProbe=$null
        $script:nextApiProbe=[DateTime]::MinValue
    }
    if(!$model){return}
    $profile=Get-SwitcherProfile $model
    if($script:apiProbe -and $script:apiProbe.IsCompleted){
        $script:apiReady=$false
        if($script:apiProbe.Status -eq 'RanToCompletion'){
            try{$script:apiReady=($script:apiProbe.Result | ConvertFrom-Json).data.id -ccontains $profile.id}catch{}
        }
        $script:apiProbe=$null
        $script:nextApiProbe=$Now.AddSeconds(3)
    }
    if(!$script:apiProbe -and $Now -ge $script:nextApiProbe){
        $script:apiProbe=$apiClient.GetStringAsync(('http://127.0.0.1:{0}/v1/models' -f $profile.port))
    }
}

function Get-SelectedModel {
    foreach($key in $cards.Keys){
        if($cards[$key].IsChecked){return $key}
    }
}

function Set-SwitchButtons {
    $active=$script:status.active
    $job=$script:status.job
    $running=$job -and $job.state -eq 'running'
    $pending=($script:req -and $script:requestKind -ne 'status') -or ([DateTime]::UtcNow -lt $script:optimisticUntil)
    $busy=$running -or $pending
    $connected=$null -ne $script:status
    $tunnelUp=$script:tunnel -and !$script:tunnel.process.HasExited
    $selected=Get-SelectedModel
    $activeChanged=$active -ne $script:lastActive
    $script:lastActive=$active
    if($active -and (!$selected -or $activeChanged)){
        $cards[$active].IsChecked=$true
        $selected=$active
    }
    foreach($key in $cards.Keys){
        $cards[$key].IsEnabled=$connected -and !$busy
        $modelStates[$key].Text=if(!$connected){'等待连接'}
            elseif($running -and $job.target -eq $key){'正在切换'}
            elseif($active -eq $key){'当前运行'}
            elseif($script:status.models.$key.state -eq 'stopped'){'已停止'}
            else{'未就绪'}
    }
    $switchButton.IsEnabled=$connected -and !$busy -and [bool]$selected -and $selected -ne $active
    $switchButton.Content=if($busy){'正在处理…'}
        elseif($selected -and $selected -eq $active){'当前模型已运行'}
        elseif($active){'切换模型'}
        else{'启动模型'}
    $stopButton.IsEnabled=[bool]$active -and !$busy
    foreach($button in $launchButtons){$button.IsEnabled=[bool]$active -and !$busy -and $tunnelUp -and $script:apiReady}

    $linkLabel.Text=if($connected -and $tunnelUp -and (!$active -or $script:apiReady)){'网线已连接'}
        elseif($connected){'正在连接模型接口'}
        else{'正在连接 Spark'}
    $linkDot.Fill=if($linkLabel.Text -eq '网线已连接'){$linkReady}else{$linkIdle}
    $working.Visibility=if($busy){'Visible'}else{'Collapsed'}
    $activeLabel.Text=if($running){
        if($job.target){'正在切换到 '+(Get-SwitcherProfile $job.target).name}else{'正在停止模型'}
    }elseif($pending){'正在提交操作…'}
    elseif($active){'当前模型 · '+(Get-SwitcherProfile $active).name}
    elseif($connected){'暂无运行中的模型'}
    else{'直连未就绪'}

    $notice.ToolTip=$null
    if($running){
        $lead=$phaseLabels[$job.phase]
        if(!$lead){$lead='正在处理'}
        $created=[DateTimeOffset]::Parse($job.created_at)
        $elapsed=[DateTimeOffset]::UtcNow-$created
        $notice.Text=('{0} · 已用 {1:00}:{2:00}' -f $lead,[Math]::Max(0,[int][Math]::Floor($elapsed.TotalMinutes)),[Math]::Max(0,$elapsed.Seconds))
        if($job.target -eq 'qwen' -and $job.phase -eq 'starting'){$notice.Text+=' · Qwen 的权重加载需要几分钟'}
        $notice.ToolTip=$job.message
    }elseif($pending){$notice.Text='等待 Spark 接收请求。'}
    elseif($script:lastError){$notice.Text=$script:lastError}
    elseif($job -and $jobErrors[$job.state]){
        $notice.Text=$jobErrors[$job.state]+'。'
        $notice.ToolTip=($job.message,$job.error -join ' ').Trim()
    }elseif($script:tunnelError){$notice.Text=$script:tunnelError}
    elseif($active -and !$script:apiReady){$notice.Text='正在验证笔记本能否访问模型接口…'}
    elseif($script:lastNotice){$notice.Text=$script:lastNotice}
    elseif($active){$notice.Text='双机服务已就绪。'}
    elseif($connected){$notice.Text='选择一个模型后启动。'}
    else{$notice.Text='检查网线是否接好、两台 Spark 是否开机。'}
}

if($PreviewPath){
    $window.WindowStartupLocation='Manual'
    $window.Left=-12000
    $window.Top=0
    $window.ShowInTaskbar=$false
    $window.ShowActivated=$false
    $script:status=[pscustomobject]@{
        active='glm'
        models=[pscustomobject]@{
            glm=[pscustomobject]@{state='ready'}
            deepseek=[pscustomobject]@{state='stopped'}
            qwen=[pscustomobject]@{state='stopped'}
        }
    }
    $script:tunnel=[pscustomobject]@{process=[pscustomobject]@{HasExited=$false}}
    $script:apiReady=$true
    Set-SwitchButtons
    $window.Show()
    try{
        $window.UpdateLayout()
        $visual=[Windows.Media.Visual]$window.Content
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Content.ActualWidth,[int]$window.Content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $output=[IO.File]::Create($PreviewPath)
        try{$encoder.Save($output)}finally{$output.Dispose()}
    }finally{$window.Close()}
    exit
}

$created=$false
$lock=[Threading.Mutex]::new($true,'Local\SparkSwitcher',[ref]$created)
if(!$created){
    $lock.Dispose()
    [void][Windows.MessageBox]::Show('Spark 切换器已经在运行。','Spark Switcher')
    exit
}
$apiHandler=[Net.Http.HttpClientHandler]::new()
$apiHandler.UseProxy=$false
$apiClient=[Net.Http.HttpClient]::new($apiHandler)
$apiClient.Timeout=[TimeSpan]::FromMilliseconds(2400)
function Push-SwitchAction([string]$Action,[string]$Model){
    try{
        if($script:req){
            if($script:requestKind -ne 'status'){return}
            Stop-SwitcherProcess $script:req
            $script:req=$null
        }
        if($Action -eq 'switch'){$script:req=Start-SwitcherRequest switch $Model}
        else{$script:req=Start-SwitcherRequest $Action}
        $script:requestKind=$Action
        $script:optimisticUntil=[DateTime]::UtcNow.AddSeconds(3)
        $script:lastError=''
    }catch{
        $script:lastError=$_.Exception.Message
        $script:req=$null
    }
    Set-SwitchButtons
}
foreach($card in $cards.Values){$card.Add_Checked({Set-SwitchButtons})}
$switchButton.Add_Click({Push-SwitchAction 'switch' (Get-SelectedModel)})
$stopButton.Add_Click({
    if([Windows.MessageBox]::Show($window,'停止当前正在运行的模型？','Spark Switcher','YesNo','Question') -eq 'Yes'){
        Push-SwitchAction 'stop' ''
    }
})
$refreshButton.Add_Click({$script:nextPoll=[DateTime]::MinValue;$script:nextApiProbe=[DateTime]::MinValue})
$chooseButton.Add_Click({
    $picker=[Windows.Forms.FolderBrowserDialog]::new()
    try{
        $picker.Description='为新开的工具选择本地项目文件夹'
        $picker.ShowNewFolderButton=$false
        if($script:workspace){$picker.SelectedPath=$script:workspace}
        if($picker.ShowDialog() -eq 'OK'){
            $script:workspace=$picker.SelectedPath
            $projectLabel.Text=$script:workspace
            $projectLabel.ToolTip=$script:workspace
        }
    }finally{$picker.Dispose()}
})
foreach($button in $launchButtons){
    $button.Add_Click({
        param($sender,$eventArgs)
        try{
            $current=$script:status.active
            if(!$current -or !$script:apiReady){return}
            $profile=Get-SwitcherProfile $current
            $tool=[string]$sender.Tag
            Start-SparkHarness -Harness $tool -ModelId $profile.id -Profiles $script:Profiles -Workspace $script:workspace | Out-Null
            $script:lastNotice=('已打开 {0} · {1}' -f $toolNames[$tool],$profile.name)
            $script:lastError=''
        }catch [Net.WebException]{
            $script:apiReady=$false
            $script:nextApiProbe=[DateTime]::MinValue
            $script:lastNotice=''
            $script:lastError=''
        }catch{
            $script:lastError=$_.Exception.Message
            $script:lastNotice=''
        }
        Set-SwitchButtons
    })
}

$timer=[Windows.Threading.DispatcherTimer]::new()
$timer.Interval=[TimeSpan]::FromMilliseconds(350)
$timer.Add_Tick({
    $now=[DateTime]::UtcNow
    if($script:tunnel -and $script:tunnel.process.HasExited){
        $script:tunnelError='模型接口转发正在重连。'
        Stop-SwitcherProcess $script:tunnel
        $script:tunnel=$null
        $script:nextTunnel=$now.AddSeconds(5)
    }
    if(!$script:tunnel -and $now -ge $script:nextTunnel){
        try{$script:tunnel=Start-SwitcherTunnel;$script:tunnelError=''}
        catch{$script:tunnelError=$_.Exception.Message;$script:nextTunnel=$now.AddSeconds(5)}
    }
    if($script:req){
        if($script:req.process.HasExited){
            try{
                $data=Read-SwitcherRequest $script:req
                if($script:requestKind -eq 'status'){
                    $script:status=$data
                    if($script:lastError -like 'Spark 未连接*'){$script:lastError=''}
                }elseif($data.job -and $script:status){
                    $script:status.job=$data.job
                    $script:lastNotice=''
                }
            }catch{
                if($script:requestKind -eq 'status'){$script:status=$null}
                $script:lastError=$_.Exception.Message
            }
            $script:req=$null
            $script:nextPoll=$now.AddSeconds(1)
        }elseif(($now-$script:req.started).TotalSeconds -gt 17){
            Stop-SwitcherProcess $script:req
            $script:req=$null
            $script:status=$null
            $script:lastError='Spark 未连接或未及时回应。'
            $script:nextPoll=$now.AddSeconds(4)
        }
    }
    if(!$script:req -and $now -ge $script:nextPoll){
        try{$script:req=Start-SwitcherRequest status;$script:requestKind='status'}
        catch{$script:lastError=$_.Exception.Message;$script:nextPoll=$now.AddSeconds(4)}
    }
    Update-SwitcherApi $now
    Set-SwitchButtons
})

try{
    Set-SwitchButtons
    $timer.Start()
    [void]$window.ShowDialog()
}finally{
    $timer.Stop()
    $apiClient.Dispose()
    Stop-SwitcherProcess $script:req
    Stop-SwitcherProcess $script:tunnel
    $lock.ReleaseMutex()
    $lock.Dispose()
}
