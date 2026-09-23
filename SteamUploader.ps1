[CmdletBinding()]
param(
    [ValidateSet('Wizard','Upload','BuildUpload','CheckOnly','BuildOnly')]
    [string]$Mode = 'Wizard',
    [string]$ProfileId = '',
    [switch]$NoBrowser,
    [switch]$Help,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
Import-Module (Join-Path $PSScriptRoot 'Uploader.Core.psm1') -Force -DisableNameChecking
$script:DataRoot = Get-UploaderDataRoot $PSScriptRoot
$script:Operations = @('Upload','BuildUpload','BuildOnly','CheckOnly')
$script:OperationLabels = @('上传现成包体','构建并上传','仅构建','仅检查')

# 启动字标颜色：支持 00adee 或 #00adee，保存后重新启动工具生效。
$script:BannerColors = @{
    Face = 'FFFFFF'      # STEAM 字面
    Side = '00adee'      # STEAM 立体侧边
    Subtitle = '00adee'  # UPLOADER 副标题
}

function Enable-UploaderTrueColor {
    if ([Console]::IsOutputRedirected) { return $null }
    try {
        if (!('SteamUploader.ConsoleMode' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SteamUploader {
    public static class ConsoleMode {
        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int id);
        [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
    }
}
'@
        }
        $handle = [SteamUploader.ConsoleMode]::GetStdHandle(-11)
        [uint32]$mode = 0
        if ([SteamUploader.ConsoleMode]::GetConsoleMode($handle, [ref]$mode) -and
            [SteamUploader.ConsoleMode]::SetConsoleMode($handle, ($mode -bor 5))) {
            return [pscustomobject]@{ Handle=$handle; Mode=$mode }
        }
    } catch { }
    return $null
}

function Write-HexColor([string]$Text, [string]$Hex, [switch]$NoNewline, [switch]$TrueColor) {
    $hex = $Hex.Trim().TrimStart('#')
    if ($hex -notmatch '\A[0-9a-fA-F]{6}\z') { throw '字标颜色需要填写6位十六进制值，例如 00adee 或 #00adee。' }
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    if ($TrueColor) {
        $esc = [char]27
        Write-Host "${esc}[38;2;$r;$g;${b}m${Text}${esc}[39m" -NoNewline:$NoNewline
    } else {
        # 老控制台使用最接近的基础色；重定向输出不会包含 ANSI 控制符。
        $palette = @(0x000000,0x000080,0x008000,0x008080,0x800000,0x800080,0x808000,0xC0C0C0,
                     0x808080,0x0000FF,0x00FF00,0x00FFFF,0xFF0000,0xFF00FF,0xFFFF00,0xFFFFFF)
        $nearest = 0; $bestDistance = [int]::MaxValue
        for ($i=0; $i -lt $palette.Count; $i++) {
            $dr = $r - (($palette[$i] -shr 16) -band 255)
            $dg = $g - (($palette[$i] -shr 8) -band 255)
            $db = $b - ($palette[$i] -band 255)
            $distance = $dr*$dr + $dg*$dg + $db*$db
            if ($distance -lt $bestDistance) { $bestDistance=$distance; $nearest=$i }
        }
        Write-Host $Text -ForegroundColor ([ConsoleColor]$nearest) -NoNewline:$NoNewline
    }
}

function Show-UploaderBanner {
    $logo = @'
███████╗████████╗███████╗ █████╗ ███╗   ███╗
██╔════╝╚══██╔══╝██╔════╝██╔══██╗████╗ ████║
███████╗   ██║   █████╗  ███████║██╔████╔██║
╚════██║   ██║   ██╔══╝  ██╔══██║██║╚██╔╝██║
███████║   ██║   ███████╗██║  ██║██║ ╚═╝ ██║
╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝
'@
    $consoleMode = Enable-UploaderTrueColor
    try {
        Write-Host ''
        foreach ($line in $logo -split '\r?\n') {
            Write-Host '  ' -NoNewline
            foreach ($part in [regex]::Matches($line, '█+|[^█]+')) {
                $color = if ($part.Value[0] -eq [char]'█') { $script:BannerColors.Face } else { $script:BannerColors.Side }
                Write-HexColor $part.Value $color -NoNewline -TrueColor:($null -ne $consoleMode)
            }
            Write-Host ''
        }
        Write-Host ''
        Write-HexColor '              U P L O A D E R' $script:BannerColors.Subtitle -TrueColor:($null -ne $consoleMode)
        Write-Host ''
    } finally {
        if ($null -ne $consoleMode) {
            $null = [SteamUploader.ConsoleMode]::SetConsoleMode($consoleMode.Handle, $consoleMode.Mode)
        }
    }
}

function Read-Text([string]$Label, [string]$Default = '', [switch]$Required) {
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host ($Label + $suffix + '（回车/s 保留，q 退出）')
        if ($answer -ieq 'q') { throw [OperationCanceledException]::new('用户取消。') }
        if ($answer -eq '-') { $answer = '' }
        elseif ($answer -ieq 's' -or [string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        $answer = $answer.Trim().Trim('"')
        if (!$Required -or $answer) { return $answer }
        Write-Host '此项不能为空。'
    }
}

function Read-Choice([string]$Label, [string[]]$Options, [int]$Default = 1) {
    Write-Host ''
    Write-Host $Label
    for ($i=0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1), $Options[$i]) }
    while ($true) {
        $answer = Read-Text '请选择编号（q 退出）' ([string]$Default)
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) { return $number }
        Write-Host '请输入列表中的编号。'
    }
}

function Show-Profile($Profile) {
    Write-Host ''
    Write-Host ("配置：{0}" -f $Profile.Name)
    $operationIndex = [array]::IndexOf($script:Operations, $Profile.Operation)
    Write-Host ("  操作：{0}" -f $(if ($operationIndex -ge 0) { $script:OperationLabels[$operationIndex] } else { '尚未设置' }))
    Write-Host ("  导出文件夹：{0}" -f $(if ($Profile.OutputRoot) { $Profile.OutputRoot } else { '尚未设置' }))
    $sourcePath = if ($Profile.SourceType -eq 'Unity') { $Profile.UnityProject } else { $Profile.SourcePath }
    Write-Host ("  包体来源：{0}  {1}" -f $Profile.SourceType, $sourcePath)
    Write-Host ("  Unity 项目：{0}" -f $Profile.UnityProject)
    Write-Host ("  Unity 编辑器：{0}" -f $Profile.UnityEditor)
    Write-Host ("  开发构建：{0}    主程序：{1}" -f $Profile.DevelopmentBuild, $Profile.Executable)
    Write-Host ("  Steam 账号：{0}    AppID：{1}    DepotID：{2}" -f $Profile.SteamAccount, $Profile.AppId, $Profile.DepotId)
    Write-Host ("  SteamCMD：{0}" -f $(if ($Profile.SteamCmdPath) {$Profile.SteamCmdPath} else {'工具内 local-data/steamcmd'}))
    Write-Host ("  Description：{0}" -f $Profile.Description)
    Write-Host ("  排除规则：{0}" -f (@($Profile.Exclusions) -join '; '))
}

function Select-Profile {
    $profiles = @(Get-UploaderProfiles $script:DataRoot)
    $profile = $null
    $isNew = $false
    if ($ProfileId) {
        $matches = @($profiles | Where-Object { $_.Id -eq $ProfileId -or $_.Name -eq $ProfileId })
        if ($matches.Count -ne 1) { throw '找不到唯一匹配的配置。请使用配置 Id，或不带参数启动。' }
        $profile = $matches[0]
    } elseif ($profiles.Count -gt 0) {
        $options = @($profiles | ForEach-Object { $_.Name + '  [' + $_.AppId + '/' + $_.DepotId + ']' }) + @('新建配置')
        $choice = Read-Choice '选择已保存配置，或新建' $options
        if ($choice -le $profiles.Count) { $profile = $profiles[$choice-1] }
    }
    $edit = $true
    if ($profile) {
        Show-Profile $profile
        $choice = Read-Choice '本次如何使用这套配置？' @('沿用','修改','另建一套')
        $edit = $choice -ne 1
        if ($choice -eq 3) {
            $profile.Id = [guid]::NewGuid().ToString('N')
            $profile.Name += ' 副本'
        }
    } else { $profile = New-UploaderProfile; $isNew = $true }
    return [pscustomobject]@{ Profile=$profile; Edit=$edit; IsNew=$isNew }
}

function Edit-ProfileField($Profile, [string]$Field) {
    switch ($Field) {
        'Name' { $Profile.Name = Read-Text '配置名称' $Profile.Name -Required }
        'Operation' {
            $default = [Math]::Max(1, [array]::IndexOf($script:Operations, $Profile.Operation) + 1)
            $Profile.Operation = $script:Operations[(Read-Choice '操作（保存到预设）' $script:OperationLabels $default)-1]
            if ($Profile.Operation -in @('BuildOnly','BuildUpload')) { $Profile.SourceType = 'Unity' }
        }
        'OutputRoot' { $Profile.OutputRoot = Read-UploaderPath '导出文件夹（每次在其下新建独立包体目录）' $Profile.OutputRoot -Kind OutputFolder -Required }
        'SourceType' {
            if ($Profile.Operation -in @('BuildOnly','BuildUpload')) {
                $Profile.SourceType = 'Unity'
                Write-Host '当前操作使用 Unity 项目；如需上传现成包体，请先修改操作。'
                break
            }
            $default = if ($Profile.SourceType -eq 'Zip') { 2 } elseif ($Profile.SourceType -eq 'Unity' -and $Profile.Operation -eq 'CheckOnly') { 3 } else { 1 }
            $types = @('已有包体文件夹','已有 ZIP')
            if ($Profile.Operation -eq 'CheckOnly') { $types += 'Unity 项目环境（不构建）' }
            $Profile.SourceType = @('Folder','Zip','Unity')[(Read-Choice '包体来源' $types $default)-1]
            if ($Profile.SourceType -ne 'Unity') { Edit-ProfileField $Profile 'SourcePath' }
        }
        'SourcePath' {
            $label = if ($Profile.SourceType -eq 'Zip') { '现成包体 ZIP 文件' } else { '现成包体文件夹（包含游戏 EXE 和依赖）' }
            $Profile.SourcePath = Read-UploaderPath $label $Profile.SourcePath -Kind $(if ($Profile.SourceType -eq 'Zip') {'Zip'} else {'Folder'}) -Required
        }
        'UnityProject' { $Profile.UnityProject = Read-UploaderPath 'Unity 项目根目录（包含 Assets 和 ProjectSettings）' $Profile.UnityProject -Kind Folder -Required }
        'UnityEditor' { $Profile.UnityEditor = Read-UploaderPath 'Unity.exe 编辑器文件（- 重置为自动寻找）' $Profile.UnityEditor -Kind Exe }
        'DevelopmentBuild' { $Profile.DevelopmentBuild = (Read-Choice '构建类型' @('普通构建','Development Build') $(if ($Profile.DevelopmentBuild) {2} else {1})) -eq 2 }
        'Executable' { $Profile.Executable = Read-Text '主程序相对路径（- 清空后自动选择）' $Profile.Executable }
        'Exclusions' {
            $rules = Read-Text '排除规则，使用分号分隔；- 表示不排除' (@($Profile.Exclusions) -join ';')
            $Profile.Exclusions = @($rules.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        'SteamAccount' { $Profile.SteamAccount = Read-Text 'Steam 登录账号（不是昵称）' $Profile.SteamAccount -Required }
        'AppId' { $Profile.AppId = Read-Text '目标 AppID' $Profile.AppId -Required }
        'DepotId' { $Profile.DepotId = Read-Text '目标 DepotID（请从后台确认）' $Profile.DepotId -Required }
        'Description' { $Profile.Description = Read-Text '构建 Description（仅在 Steamworks 后台显示）' $Profile.Description }
        'SteamCmdPath' { $Profile.SteamCmdPath = Read-UploaderPath 'SteamCMD 程序文件 steamcmd.exe（- 重置为工具内版本）' $Profile.SteamCmdPath -Kind Exe }
    }
}

function Initialize-Profile($Profile) {
    foreach ($field in @('Name','OutputRoot')) { Edit-ProfileField $Profile $field }
    if ($Profile.Operation -in @('BuildOnly','BuildUpload')) { $Profile.SourceType = 'Unity' }
    else { Edit-ProfileField $Profile 'SourceType' }
    if ($Profile.SourceType -eq 'Unity') {
        foreach ($field in @('UnityProject','UnityEditor','DevelopmentBuild')) { Edit-ProfileField $Profile $field }
    }
    foreach ($field in @('Executable','Exclusions')) { Edit-ProfileField $Profile $field }
    if ($Profile.Operation -ne 'BuildOnly') {
        $Profile.Description = 'Windows build ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        foreach ($field in @('SteamAccount','AppId','DepotId','SteamCmdPath')) { Edit-ProfileField $Profile $field }
    }
}

function Edit-Profile($Profile) {
    $fields = @('Name','Operation','OutputRoot','SourceType','SourcePath','UnityProject','UnityEditor','DevelopmentBuild','Executable','Exclusions','SteamAccount','AppId','DepotId','Description','SteamCmdPath')
    $labels = @('配置名称','操作','导出文件夹','包体来源类型','现成包体路径','Unity 项目目录','Unity.exe 编辑器文件','构建类型','主程序相对路径','排除规则','Steam 登录账号','AppID','DepotID','Description','SteamCMD 程序文件')
    while ($true) {
        $options = @('完成修改，继续（未选中的项目保持原值）')
        for ($i=0; $i -lt $fields.Count; $i++) {
            $value = $Profile.($fields[$i])
            if ($fields[$i] -eq 'Exclusions') { $value = @($value) -join '; ' }
            elseif ($fields[$i] -eq 'DevelopmentBuild') { $value = if ($value) { 'Development Build' } else { '普通构建' } }
            elseif ($fields[$i] -eq 'Operation' -and $value) { $value = $script:OperationLabels[[array]::IndexOf($script:Operations, $value)] }
            if ([string]::IsNullOrEmpty([string]$value)) { $value = '未设置 / 自动' }
            $options += $labels[$i] + '：' + $value
        }
        $choice = Read-Choice '选择要修改的项目；可连续修改多项，回车完成' $options
        if ($choice -eq 1) { return }
        Edit-ProfileField $Profile $fields[$choice-2]
    }
}

function Resolve-OutputSettings($Profile) {
    while ($true) {
        if (!$Profile.OutputRoot) {
            $Profile.OutputRoot = Read-UploaderPath '导出文件夹（每次在其下新建独立包体目录）' '' -Kind OutputFolder -Required
        }
        try { $Profile.OutputRoot = Get-UploaderOutputRoot $Profile.OutputRoot; return }
        catch { Write-Host $_.Exception.Message; $Profile.OutputRoot = '' }
    }
}

function Resolve-UnitySettings($Profile) {
    while ($true) {
        try { $info = Get-UnityProjectInfo $Profile.UnityProject; break }
        catch { Write-Host $_.Exception.Message; $Profile.UnityProject = Read-UploaderPath '重新选择 Unity 项目根目录' '' -Kind Folder -Required }
    }
    $Profile.UnityProject = $info.Root
    $editor = Find-UnityEditor $info.Version $Profile.UnityEditor
    Write-Host ("项目使用 Unity {0}，产品名称 {1}。" -f $info.Version, $info.ProductName)
    while ($true) {
        if (!$editor) { $editor = Read-UploaderPath ("请选择 Unity $($info.Version) 的 Unity.exe") '' -Kind Exe -Required }
        try { Assert-UnityReady $info.Root $editor $info.Version; break }
        catch {
            Write-Host $_.Exception.Message
            $choice = Read-Choice '处理 Unity 环境问题' @('处理完毕后重试','更换 Unity.exe 路径','取消')
            if ($choice -eq 3) { throw [OperationCanceledException]::new('用户取消构建。') }
            if ($choice -eq 2) { $editor = '' }
        }
    }
    $Profile.UnityEditor = $editor
}

function Resolve-SteamSettings($Profile) {
    while ($true) {
        try { Assert-SteamIds $Profile; break }
        catch {
            Write-Host $_.Exception.Message
            $Profile.SteamAccount = Read-Text 'Steam 登录账号' $Profile.SteamAccount -Required
            $Profile.AppId = Read-Text 'AppID' $Profile.AppId -Required
            $Profile.DepotId = Read-Text 'DepotID' $Profile.DepotId -Required
        }
    }
    $managed = Join-Path $script:DataRoot 'steamcmd/steamcmd.exe'
    $exe = if ($Profile.SteamCmdPath) { $Profile.SteamCmdPath } else { $managed }
    while (!(Test-Path -LiteralPath $exe -PathType Leaf)) {
        $choice = Read-Choice '未找到 SteamCMD' @('下载 Valve 官方 SteamCMD','指定已有 steamcmd.exe','取消')
        if ($choice -eq 3) { throw [OperationCanceledException]::new('用户取消。') }
        if ($choice -eq 1) { $exe = Install-UploaderSteam $script:DataRoot }
        else { $exe = Read-UploaderPath 'steamcmd.exe 完整路径' '' -Kind Exe -Required }
    }
    if ([IO.Path]::GetFileName($exe) -ine 'steamcmd.exe') { throw '所选程序必须是 steamcmd.exe。' }
    return [IO.Path]::GetFullPath($exe)
}

function Save-CurrentProfile($Profile, [string]$ActualSteam = '') {
    if ($ActualSteam) {
        $managed = [IO.Path]::GetFullPath((Join-Path $script:DataRoot 'steamcmd/steamcmd.exe'))
        $Profile.SteamCmdPath = if ($ActualSteam -ieq $managed) { '' } else { $ActualSteam }
    }
    Save-UploaderProfile $Profile $script:DataRoot
}

function Select-PackageRoot([string]$Root) {
    $candidates = @(Get-PackageCandidates $Root)
    if ($candidates.Count -eq 1) { Write-Host ("包体根目录：{0}" -f $candidates[0]); return $candidates[0] }
    $choice = Read-Choice '找到多个含 EXE 的目录，请选择完整包体根目录' (@($candidates) + @('手动指定根目录'))
    if ($choice -gt $candidates.Count) {
        $chosen = Read-UploaderPath '完整包体根目录（必须在所选来源内）' $Root -Kind Folder -Required
        if ([IO.Path]::GetFullPath($chosen) -ine [IO.Path]::GetFullPath($Root)) { $null = Assert-UnderRoot $chosen $Root }
        return $chosen
    }
    return $candidates[$choice-1]
}

function Select-Executable($Profile, [string]$Content) {
    if ($Profile.Executable) {
        try {
            $exe = Assert-UnderRoot (Join-Path $Content $Profile.Executable) $Content
            if ([IO.File]::Exists($exe)) { return }
        } catch { }
        Write-Host '保存的主程序路径已失效，请重新选择。'
    }
    $choices = @(Get-SafeFiles $Content | Where-Object { $_.Extension -ieq '.exe' -and $_.Name -notmatch '^(UnityCrashHandler|UnityCrashHandler64|unins\d*|crashpad_handler)\.exe$' } | ForEach-Object { $_.FullName.Substring($Content.TrimEnd('\','/').Length+1).Replace('\','/') })
    if ($choices.Count -eq 0) { throw '排除规则执行后没有可用游戏 EXE。' }
    $selection = if ($choices.Count -eq 1) { 1 } else { Read-Choice '选择游戏主程序' $choices }
    $Profile.Executable = $choices[$selection-1]
}

if ($Help) {
    Write-Host 'SteamUploader: 双击 BAT 或直接启动，按向导选择配置。'
    Write-Host '-Mode Upload/BuildUpload/BuildOnly/CheckOnly：指定并保存操作；-ProfileId：配置 Id 或唯一名称。'
    Write-Host '-SelfTest：离线测试；-NoBrowser：上传成功后只显示后台地址。q 退出；输入 - 清空文本字段。'
    exit 0
}
if ($SelfTest) {
    & (Join-Path $PSScriptRoot 'tests/Run-Tests.ps1')
    exit $LASTEXITCODE
}

$lock = $null
$runRoot = ''
$content = ''
$status = 'Failed'
$exitCode = 1
try {
    $lock = Enter-UploaderLock $script:DataRoot
    Assert-NoActiveSteam $script:DataRoot
    Repair-UploaderHelpers $script:DataRoot
    Show-UploaderBanner
    Write-Host 'SteamUploader — Unity 构建 & SteamPipe 上传工具'
    $selection = Select-Profile
    $profile = $selection.Profile
    if ($Mode -ne 'Wizard') { $profile.Operation = $Mode }
    if ($selection.IsNew) {
        if (!$profile.Operation) { Edit-ProfileField $profile 'Operation' }
        Initialize-Profile $profile
    }
    elseif ($selection.Edit) { Edit-Profile $profile }
    if (!$profile.Operation) { Edit-ProfileField $profile 'Operation' }
    $operation = $profile.Operation
    if ($operation -eq 'Upload' -and $profile.SourceType -eq 'Unity') { Edit-ProfileField $profile 'SourceType' }
    if ($operation -in @('BuildUpload','BuildOnly')) { $profile.SourceType = 'Unity' }
    if ($profile.SourceType -ne 'Unity' -and (!$profile.SourcePath -or !(Test-Path -LiteralPath $profile.SourcePath))) {
        $choice = Read-Choice '源包体不存在，如何继续？' @('重新选择包体','改为选择 Unity 项目','取消')
        if ($choice -eq 3) { throw [OperationCanceledException]::new('用户取消。') }
        if ($choice -eq 1) { $profile.SourcePath = Read-UploaderPath '包体路径' '' -Kind $(if ($profile.SourceType -eq 'Zip') {'Zip'} else {'Folder'}) -Required }
        else {
            $profile.SourceType = 'Unity'
            $profile.UnityProject = Read-UploaderPath 'Unity 项目根目录' $profile.UnityProject -Kind Folder -Required
            if ($operation -ne 'CheckOnly') { $operation = 'BuildUpload' }
        }
    }
    $profile.Operation = $operation
    Resolve-OutputSettings $profile
    Write-Host ("本次 Description：{0}" -f $(if ($profile.Description) { $profile.Description } else { '（空）' }))
    $profile.Description = Read-Text 'Description（输入新内容修改，直接回车不改）' $profile.Description
    Save-CurrentProfile $profile
    if ($profile.SourceType -eq 'Unity') { Resolve-UnitySettings $profile }
    $actualSteam = ''
    if ($operation -ne 'BuildOnly') { $actualSteam = Resolve-SteamSettings $profile }
    Save-CurrentProfile $profile $actualSteam
    $runRoot = Join-Path $script:DataRoot ('runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    if (!($operation -eq 'CheckOnly' -and $profile.SourceType -eq 'Unity')) {
        $content = New-UploaderContentRoot $profile $runRoot
    }
    Write-JsonFile (Join-Path $runRoot 'profile.json') $profile
    Write-Host ("本次记录：{0}" -f $runRoot)
    if ($content) { Write-Host ("本次包体目录：{0}" -f $content) }
    if ($operation -ne 'BuildOnly') {
        $profile.SteamCmdPath = $actualSteam
        Write-Host '正在验证 Steam 登录；如需密码或 Steam Guard，请直接按 SteamCMD 提示输入。'
        Connect-UploaderSteam $profile $script:DataRoot
    }
    if ($operation -eq 'CheckOnly' -and $profile.SourceType -eq 'Unity') {
        Write-Host 'Unity 项目环境和 Steam 登录检查通过。尚无包体，未进行构建或 SteamPipe 预览。'
        $status = 'EnvironmentChecked'
    } else {
        $raw = ''
        if ($profile.SourceType -eq 'Unity') {
            Show-Profile $profile
            if ((Read-Choice '开始本次 Unity 构建？' @('开始构建','取消') 2) -eq 2) { throw [OperationCanceledException]::new('用户取消。') }
            $raw = Join-Path $runRoot 'raw-content'
            $report = Invoke-UnityPackage $profile $raw $runRoot (Join-Path $PSScriptRoot 'UnityBuildHelper.cs')
            $profile.Executable = $report.executable
        } elseif ($profile.SourceType -eq 'Zip') {
            if (!(Test-Path -LiteralPath $profile.SourcePath -PathType Leaf) -or [IO.Path]::GetExtension($profile.SourcePath) -ine '.zip') { throw '请选择现有 ZIP 文件。' }
            $unpacked = Join-Path $runRoot 'unpacked'
            Expand-SafeZip $profile.SourcePath $unpacked
            $raw = Select-PackageRoot $unpacked
        } else {
            if (!(Test-Path -LiteralPath $profile.SourcePath -PathType Container)) { throw '请选择现有包体文件夹。' }
            $raw = Select-PackageRoot ([IO.Path]::GetFullPath($profile.SourcePath))
        }
        $excluded = Copy-Package $raw $content @($profile.Exclusions)
        Select-Executable $profile $content
        $validation = Test-Package $content $profile.Executable
        Write-JsonFile (Join-Path $runRoot 'validation.json') $validation
        Write-JsonFile (Join-Path $runRoot 'excluded-files.json') @($excluded)
        Save-CurrentProfile $profile $actualSteam
        Write-JsonFile (Join-Path $runRoot 'profile.json') $profile
        if ($actualSteam) { $profile.SteamCmdPath = $actualSteam }
        Show-Profile $profile
        Write-Host ("包体输出目录：{0}" -f $content)
        Write-Host ("文件：{0}；大小：{1:N2} MB；排除：{2} 项。" -f $validation.FileCount, ($validation.Bytes/1MB), @($excluded).Count)
        foreach ($file in @($excluded) | Select-Object -First 20) { Write-Host ("  排除：{0}" -f $file) }
        if (@($excluded).Count -gt 20) { Write-Host '完整排除清单见 excluded-files.json。' }
        if ($operation -eq 'BuildOnly') {
            $status = 'Built'
            Write-Host ''
            Write-Host '构建成功，本地检查通过。未上传 Steam。' -ForegroundColor Green
            Write-Host ("包体文件夹：{0}" -f $content)
            Write-Host ("启动程序：{0}" -f (Join-Path $content $profile.Executable))
            Write-Host '本次输出为文件夹，未生成 ZIP；分发时请保留整个包体文件夹。'
        } else {
            Write-Host '正在执行 SteamPipe 预览（不上传包体）……'
            $null = Invoke-SteamPackage $profile $content $script:DataRoot $runRoot -Preview
            if ($operation -eq 'CheckOnly') {
                $status = 'Checked'
                Write-Host '本地包体检查和 SteamPipe 预览通过，未进行正式上传。'
            } else {
                Write-Host ("目标 AppID {0} / DepotID {1}；Description：{2}" -f $profile.AppId, $profile.DepotId, $profile.Description)
                if ((Read-Choice '确认将上面的文件正式上传？（不会发布分支）' @('开始上传','取消') 2) -eq 2) { throw [OperationCanceledException]::new('用户取消上传，包体和记录已保留。') }
                $now = Get-PackageManifest $content
                if (($now | ConvertTo-Json -Depth 4 -Compress) -cne ($validation.Files | ConvertTo-Json -Depth 4 -Compress)) { throw '预览后暂存包体发生变化，已停止上传。请重新运行。' }
                $status = 'UploadUnconfirmed'
                $uploaded = Invoke-SteamPackage $profile $content $script:DataRoot $runRoot
                $receipt = [ordered]@{
                    AppId=$profile.AppId; DepotId=$profile.DepotId; BuildId=$uploaded.BuildId; ManifestId=$uploaded.ManifestId
                    Description=$profile.Description; UploadedAt=(Get-Date).ToString('o'); FileCount=$validation.FileCount
                    Bytes=$validation.Bytes; Executable=$profile.Executable; ContentRoot=$content; SetLive=''
                }
                Write-JsonFile (Join-Path $runRoot 'upload-receipt.json') $receipt
                $status = 'Uploaded'
                Write-Host ("上传成功，BuildID：{0}，ManifestID：{1}" -f $uploaded.BuildId, $uploaded.ManifestId)
                $url = 'https://partner.steamgames.com/apps/builds/' + $profile.AppId
                Write-Host ("请在后台选择分支生效：{0}" -f $url)
                if (!$NoBrowser) {
                    try { Start-Process $url -ErrorAction Stop | Out-Null } catch { Write-Warning '浏览器未能自动打开，请复制上面的地址。' }
                }
            }
        }
    }
    $exitCode = 0
} catch [OperationCanceledException] {
    $status = 'Cancelled'; $exitCode = 2
    Write-Host $_.Exception.Message
} catch {
    Write-Host ("操作停止：{0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($runRoot) { Write-Host ("保留本次目录供检查或重试：{0}" -f $runRoot) }
} finally {
    try {
        if ($runRoot) {
            Write-JsonFile (Join-Path $runRoot 'result.json') ([ordered]@{ Status=$status; ExitCode=$exitCode; FinishedAt=(Get-Date).ToString('o'); ContentRoot=$content })
        }
    } finally { if ($lock) { $lock.Dispose() } }
}
exit $exitCode
