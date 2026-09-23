Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:DefaultExclusions = @('steam_appid.txt', '**/steam_appid.txt', '**/*DoNotShip*/**', '**/*DontShip*/**', '.git/**', '**/.git/**', '.svn/**', '**/.svn/**')

function New-UploaderPathDialog([string]$Label, [string]$Default, [ValidateSet('Folder','OutputFolder','Zip','Exe')][string]$Kind) {
    Add-Type -AssemblyName System.Windows.Forms
    if ($Kind -in @('Folder','OutputFolder')) {
        if (!('SteamUploader.NativeFolderDialog' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'NativeFolderDialog.cs') -ReferencedAssemblies @('System.dll','System.Windows.Forms.dll')
        }
        $dialog = New-Object SteamUploader.NativeFolderDialog
        $dialog.Title = $Label
        if ($Default) { $dialog.SelectedPath = [IO.Path]::GetFullPath($Default) }
    } else {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.AutoUpgradeEnabled = $true
        $dialog.Title = $Label
        $dialog.Filter = if ($Kind -eq 'Zip') { 'ZIP 包体 (*.zip)|*.zip' } else { 'Windows 程序 (*.exe)|*.exe' }
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        $dialog.RestoreDirectory = $true
        if ($Default -and (Test-Path -LiteralPath $Default -PathType Leaf)) {
            $dialog.InitialDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Default))
            $dialog.FileName = [IO.Path]::GetFileName($Default)
        }
    }
    return $dialog
}

function Show-UploaderPathDialog([string]$Label, [string]$Default, [string]$Kind) {
    $dialog = $null
    $owner = $null
    Write-Host ("正在选择：{0}" -f $Label)
    Write-Host '取消选择窗口后可粘贴路径，或回车保留原值。'
    try {
        if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw '文件选择窗口需要 STA 模式，请用 BAT 启动，或在 powershell.exe 后加 -STA。' }
        $dialog = New-UploaderPathDialog $Label $Default $Kind
        $owner = New-Object Windows.Forms.Form
        $owner.ShowInTaskbar = $false
        $owner.Opacity = 0
        $owner.TopMost = $true
        $owner.Show()
        if ($dialog.ShowDialog($owner) -eq [Windows.Forms.DialogResult]::OK) {
            if ($Kind -in @('Folder','OutputFolder')) { return $dialog.SelectedPath }
            return $dialog.FileName
        }
    } catch { Write-Warning ("无法打开选择窗口，可在终端粘贴路径。{0}" -f $_.Exception.Message) }
    finally {
        if ($dialog) { $dialog.Dispose() }
        if ($owner) { $owner.Dispose() }
    }
    return ''
}

function Read-UploaderPath([string]$Label, [string]$Default = '', [ValidateSet('Folder','OutputFolder','Zip','Exe')][string]$Kind = 'Folder', [switch]$Required) {
    if ($Required -and !$Default -and ![Console]::IsInputRedirected) {
        $selected = Show-UploaderPathDialog $Label $Default $Kind
        if ($selected) { Write-Host ("已选择：{0}" -f $selected); return $selected }
    }
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host ($Label + $suffix + '（回车/s 保留 / b 浏览 / 粘贴路径 / - 清空 / q 退出）')
        if ($answer -ieq 'q') { throw [OperationCanceledException]::new('用户取消。') }
        if ($answer -ieq 'b') {
            $selected = Show-UploaderPathDialog $Label $Default $Kind
            if ($selected) { Write-Host ("已选择：{0}" -f $selected); return $selected }
            continue
        }
        if ($answer -eq '-') { $answer = '' }
        elseif ($answer -ieq 's' -or [string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        $answer = $answer.Trim()
        # Pasted paths are data, never executable PowerShell expressions.
        if ($answer.Length -ge 2 -and (($answer.StartsWith('"') -and $answer.EndsWith('"')) -or ($answer.StartsWith("'") -and $answer.EndsWith("'")))) {
            $answer = $answer.Substring(1, $answer.Length - 2)
        }
        if (!$Required -or $answer) { return $answer }
        Write-Host '此项不能为空。输入 b 打开选择窗口，或粘贴完整路径。'
    }
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Write-JsonFile([string]$Path, $Value) {
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $temp + '.previous'
    Write-Utf8 $temp ($Value | ConvertTo-Json -Depth 12)
    try {
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, $backup) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Assert-UnderRoot([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (!$full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径必须位于指定目录内：$full"
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    while ($parent -and ($parent -ieq $base -or $parent.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase))) {
        if (Test-Path -LiteralPath $parent) { Assert-NoLink $parent }
        if ($parent -ieq $base) { break }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    return $full
}

function Assert-NoLink([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "不接受符号链接或 Junction：$Path" }
}

function Get-SafeFiles([string]$Root) {
    Assert-NoLink $Root
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        Assert-NoLink $item.FullName
        if ($item.PSIsContainer) { Get-SafeFiles $item.FullName }
        else { $item }
    }
}

function Remove-OwnedTree([string]$Path, [string]$Root) {
    $full = Assert-UnderRoot $Path $Root
    if (!(Test-Path -LiteralPath $full)) { return }
    $item = Get-Item -LiteralPath $full -Force
    # Directory.Delete without recursion removes a directory link itself, never its target.
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($full) } else { [IO.File]::Delete($full) }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $full -Force) { Remove-OwnedTree $child.FullName $Root }
        [IO.Directory]::Delete($full)
    } else {
        [IO.File]::SetAttributes($full, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($full)
    }
}

function Get-UploaderDataRoot([string]$ToolRoot) {
    # Existing installations keep their data in place, including while the old
    # process is running. Both entrypoints must use the same store and lock.
    $legacy = Join-Path (Split-Path $ToolRoot -Parent) 'steam-publisher/local-data'
    if (Test-Path -LiteralPath $legacy -PathType Container) { return [IO.Path]::GetFullPath($legacy) }
    return Join-Path $ToolRoot 'local-data'
}

function Enter-UploaderLock([string]$DataRoot) {
    [IO.Directory]::CreateDirectory($DataRoot) | Out-Null
    # Retain the lock filename so a running pre-rename tool also blocks us.
    try { return [IO.File]::Open((Join-Path $DataRoot 'publisher.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw '另一个工具实例正在使用此数据目录，或目录不可写。请稍后重试。' }
}

function New-UploaderProfile {
    return [pscustomobject][ordered]@{
        SchemaVersion = 2; Id = [guid]::NewGuid().ToString('N'); Name = '新配置'
        Operation = ''; OutputRoot = ''
        SteamAccount = ''; SteamCmdPath = ''; SourceType = 'Folder'; SourcePath = ''
        UnityProject = ''; UnityEditor = ''; Executable = ''; DevelopmentBuild = $false
        AppId = ''; DepotId = ''; Description = ''; Exclusions = @($script:DefaultExclusions)
    }
}

function Assert-Profile($Profile) {
    $required = (New-UploaderProfile).PSObject.Properties.Name
    foreach ($key in $required) {
        if (!$Profile.PSObject.Properties[$key]) { throw "配置缺少字段：$key" }
    }
    if ($Profile.SchemaVersion -ne 2 -or $Profile.Id -notmatch '^[a-f0-9]{32}$') { throw '配置版本或标识无效。' }
    if ($Profile.Operation -notin @('', 'Upload', 'BuildUpload', 'BuildOnly', 'CheckOnly')) { throw '配置的 Operation 无效。' }
    if ($Profile.SourceType -notin @('Folder', 'Zip', 'Unity')) { throw '配置的 SourceType 无效。' }
    if ($Profile.DevelopmentBuild -isnot [bool]) { throw 'DevelopmentBuild 必须为布尔值。' }
    foreach ($key in @('Name','Operation','OutputRoot','SteamAccount','SteamCmdPath','SourcePath','UnityProject','UnityEditor','Executable','AppId','DepotId','Description')) {
        if ($Profile.$key -isnot [string]) { throw "配置字段 $key 必须为文本。" }
        if ($Profile.$key -match '[\x00-\x1f]') { throw "配置字段 $key 包含控制字符。" }
    }
    foreach ($rule in @($Profile.Exclusions)) { if ($rule -isnot [string] -or $rule -match '[\x00-\x1f]') { throw '排除规则必须为单行文本。' } }
}

function Save-UploaderProfile($Profile, [string]$DataRoot) {
    Assert-Profile $Profile
    # Only allowlisted settings are saved; unknown fields cannot persist credentials.
    $clean = New-UploaderProfile
    foreach ($key in $clean.PSObject.Properties.Name) { $clean.$key = $Profile.$key }
    Write-JsonFile (Join-Path $DataRoot ('profiles/' + $clean.Id + '.json')) $clean
}

function Get-UploaderProfiles([string]$DataRoot) {
    $dir = Join-Path $DataRoot 'profiles'
    if (!(Test-Path -LiteralPath $dir)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name) {
        try {
            $p = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            if ($p.SchemaVersion -eq 1) {
                # Old profiles never stored these choices. Ask once instead of guessing.
                $p | Add-Member NoteProperty Operation '' -Force
                $p | Add-Member NoteProperty OutputRoot '' -Force
                $p.SchemaVersion = 2
            }
            Assert-Profile $p
            if ($file.BaseName -ne $p.Id) { throw '文件名与配置标识不一致。' }
            $clean = New-UploaderProfile
            foreach ($key in $clean.PSObject.Properties.Name) { $clean.$key = $p.$key }
            $clean
        } catch { Write-Warning ("已跳过损坏的配置，原文件保留：{0}。{1}" -f $file.FullName, $_.Exception.Message) }
    }
}

function Get-UploaderOutputRoot([string]$Path) {
    if ($Path -notmatch '^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
        throw '导出文件夹必须是完整的绝对路径。'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if (!(Test-Path -LiteralPath $ancestor -PathType Container)) { throw "导出路径被文件占用：$ancestor" }
            Assert-NoLink $ancestor
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor.TrimEnd('\','/'))
    }
    return $full
}

function New-UploaderContentRoot($Profile, [string]$RunRoot) {
    $output = Get-UploaderOutputRoot $Profile.OutputRoot
    $blocked = @()
    if ($Profile.SourceType -eq 'Folder') { $blocked += $Profile.SourcePath }
    if ($Profile.SourceType -eq 'Unity') {
        foreach ($dir in @('Assets','Packages','ProjectSettings')) { $blocked += Join-Path $Profile.UnityProject $dir }
    }
    foreach ($path in $blocked) {
        $base = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        $target = $output.TrimEnd('\','/')
        if ($target -ieq $base -or $target.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '导出文件夹不能位于源包体或 Unity 的 Assets、Packages、ProjectSettings 内。'
        }
    }
    $exportRun = Assert-UnderRoot (Join-Path $output (Split-Path $RunRoot -Leaf)) $output
    if (Test-Path -LiteralPath $exportRun) { throw "本次导出目录已存在，请重新运行：$exportRun" }
    $content = Assert-UnderRoot (Join-Path $exportRun 'content') $output
    [IO.Directory]::CreateDirectory($content) | Out-Null
    return $content
}

function Assert-SteamIds($Profile) {
    foreach ($key in @('AppId', 'DepotId')) {
        $n = [uint32]0
        if ($Profile.$key -notmatch '^[1-9][0-9]*$' -or ![uint32]::TryParse($Profile.$key, [ref]$n)) { throw "$key 必须是有效的正整数。请从 Steamworks 后台确认。" }
    }
    if ([string]::IsNullOrWhiteSpace($Profile.SteamAccount) -or $Profile.SteamAccount -match '[\s"]') { throw '请填写 Steam 登录账号（不是昵称），不能包含空格或引号。' }
}

function Test-Excluded([string]$RelativePath, [string[]]$Rules) {
    $path = $RelativePath.Replace('\', '/')
    foreach ($rule in $Rules) {
        if ([string]::IsNullOrWhiteSpace($rule)) { continue }
        $pattern = [regex]::Escape($rule.Replace('\', '/'))
        $pattern = $pattern.Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
        if ($path -match ('^' + $pattern + '$')) { return $true }
    }
    return $false
}

function Assert-NotUnityProject([string]$Root) {
    if ((Test-Path -LiteralPath (Join-Path $Root 'Assets') -PathType Container) -and (Test-Path -LiteralPath (Join-Path $Root 'ProjectSettings') -PathType Container)) {
        throw '选择的是 Unity 工程目录。请选择已生成的包体，或使用“构建并上传”。'
    }
}

function Expand-SafeZip([string]$ZipPath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @()
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (!$name -or $name.StartsWith('/') -or $name.Contains(':')) { throw "ZIP 路径无效：$name" }
            foreach ($segment in $name.TrimEnd('/').Split('/')) {
                if (!$segment -or $segment -in @('.', '..') -or $segment -match '[. ]$|[<>"|?*\x00-\x1f]' -or $segment -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw "ZIP 包含不安全的路径：$name" }
            }
            $unixType = ([int64]$entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000 -or (($entry.ExternalAttributes -band 0x400) -ne 0)) { throw "ZIP 不允许链接：$name" }
            $target = Assert-UnderRoot (Join-Path $Destination $name) $Destination
            if (!$seen.Add($target)) { throw "ZIP 包含重复或大小写冲突的路径：$name" }
            $entries += [pscustomobject]@{ Entry=$entry; Target=$target; IsDirectory=$name.EndsWith('/') }
        }
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        foreach ($item in $entries) {
            if ($item.IsDirectory) { [IO.Directory]::CreateDirectory($item.Target) | Out-Null; continue }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Target)) | Out-Null
            $source = $item.Entry.Open()
            $targetStream = [IO.File]::Open($item.Target, 'CreateNew', 'Write', 'None')
            try { $source.CopyTo($targetStream) } finally { $targetStream.Dispose(); $source.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Get-PackageCandidates([string]$Root) {
    Assert-NotUnityProject $Root
    $files = @(Get-SafeFiles $Root)
    $executables = @($files | Where-Object { $_.Extension -ieq '.exe' -and $_.Name -notmatch '^(UnityCrashHandler|UnityCrashHandler64|unins\d*|crashpad_handler)\.exe$' })
    $dirs = @($executables | ForEach-Object { $_.DirectoryName } | Select-Object -Unique)
    if ($dirs.Count -eq 0) { throw '包体中找不到游戏 EXE。' }
    $candidate = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    # Unwrap only a single enclosing directory. Engines with bin/Game.exe and
    # sibling data must keep their common root instead of losing runtime assets.
    while ($true) {
        if (@($executables | Where-Object { $_.DirectoryName -ieq $candidate }).Count -gt 0) { return $candidate }
        $children = @(Get-ChildItem -LiteralPath $candidate -Force)
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $candidate = $children[0].FullName; continue }
        break
    }
    return @($candidate) + @($dirs | Where-Object { $_ -ine $candidate })
}

function Copy-Package([string]$Source, [string]$Destination, [string[]]$Exclusions) {
    Assert-NotUnityProject $Source
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $destFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($destFull.Equals($sourceFull, [StringComparison]::OrdinalIgnoreCase) -or $destFull.StartsWith($sourceFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '暂存目录不能位于源包体内。' }
    $files = @(Get-SafeFiles $sourceFull)
    $excluded = @()
    [IO.Directory]::CreateDirectory($destFull) | Out-Null
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceFull.Length + 1).Replace('\', '/')
        if (Test-Excluded $relative $Exclusions) { $excluded += $relative; continue }
        $target = Assert-UnderRoot (Join-Path $destFull $relative) $destFull
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [IO.File]::Copy($file.FullName, $target, $false)
    }
    return ,$excluded
}

function Get-PackageManifest([string]$Root) {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $result = @(Get-SafeFiles $base | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ Path=$_.FullName.Substring($base.Length + 1).Replace('\','/'); Bytes=$_.Length; Sha256=(Get-Sha256 $_.FullName) }
    })
    return ,$result
}

function Test-Package([string]$Root, [string]$Executable) {
    Assert-NotUnityProject $Root
    $exe = Assert-UnderRoot (Join-Path $Root $Executable) $Root
    if (!(Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetExtension($exe) -ine '.exe') { throw '所选游戏主程序不存在或不是 EXE。' }
    $stream = [IO.File]::OpenRead($exe)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw '主程序不是有效的 Windows PE 文件。' }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw '主程序 PE 头无效。' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw '主程序 PE 签名无效。' }
        $machine = $reader.ReadUInt16()
        if ($machine -notin @(0x14c, 0x8664, 0xaa64)) { throw '无法识别 Windows 主程序架构。' }
    } finally { $reader.Dispose() }
    $exeDir = [IO.Path]::GetDirectoryName($exe)
    $data = Join-Path $exeDir ([IO.Path]::GetFileNameWithoutExtension($exe) + '_Data')
    $unityPlayer = Join-Path $exeDir 'UnityPlayer.dll'
    $isUnity = (Test-Path -LiteralPath $data -PathType Container) -or (Test-Path -LiteralPath $unityPlayer)
    if ($isUnity) {
        if (!(Test-Path -LiteralPath $data -PathType Container) -or !(Test-Path -LiteralPath $unityPlayer -PathType Leaf)) { throw 'Unity 包体缺少与 EXE 同名的 _Data 目录或 UnityPlayer.dll。' }
        if (!(Test-Path -LiteralPath (Join-Path $data 'globalgamemanagers')) -and !(Test-Path -LiteralPath (Join-Path $data 'data.unity3d'))) { throw 'Unity 数据目录缺少 globalgamemanagers 或 data.unity3d。' }
        if (!(Test-Path -LiteralPath (Join-Path $exeDir 'GameAssembly.dll')) -and !(Test-Path -LiteralPath (Join-Path $data 'Managed') -PathType Container)) { throw 'Unity 包体缺少 GameAssembly.dll 或 Managed 程序集目录。' }
    }
    $manifest = Get-PackageManifest $Root
    if ($manifest.Count -eq 0) { throw '包体为空。' }
    return [pscustomobject]@{ Executable=$Executable; Unity=$isUnity; Machine=$machine; FileCount=$manifest.Count; Bytes=($manifest | Measure-Object Bytes -Sum).Sum; Files=$manifest }
}

function ConvertTo-VdfValue([string]$Value) {
    if ($Value -match '[\x00-\x1f]') { throw 'VDF 字段不能包含控制字符。' }
    return $Value.Replace('\','\\').Replace('"','\"')
}

function Write-AppVdf($Profile, [string]$ContentRoot, [string]$BuildOutput, [string]$Path, [switch]$Preview) {
    Assert-SteamIds $Profile
    $desc = ConvertTo-VdfValue $Profile.Description
    $content = ConvertTo-VdfValue ([IO.Path]::GetFullPath($ContentRoot).Replace('\','/'))
    $output = ConvertTo-VdfValue ([IO.Path]::GetFullPath($BuildOutput).Replace('\','/'))
    $flag = if ($Preview) { '1' } else { '0' }
    $text = @"
"AppBuild"
{
    "AppID" "$($Profile.AppId)"
    "Desc" "$desc"
    "ContentRoot" "$content"
    "BuildOutput" "$output"
    "Preview" "$flag"
    "Depots"
    {
        "$($Profile.DepotId)"
        {
            "FileMapping" { "LocalPath" "*" "DepotPath" "." "recursive" "1" }
        }
    }
}
"@
    Write-Utf8 $Path $text
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW quoting, including quotes and trailing slashes.
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function New-UploaderProgress([string]$Activity, [string]$Kind, [string[]]$LogPaths = @()) {
    return [pscustomobject]@{
        Activity=$Activity; Kind=$Kind; LogPaths=$LogPaths; Offsets=@{}; Pending=@{}
        Clock=[Diagnostics.Stopwatch]::StartNew(); LastRender=-1.0; LastHeartbeat=-15.0
        LastActivity=0.0; Stage='正在准备'; Percent=-1; ProcessId=0; AwaitingInput=$false
    }
}

function Update-UploaderProgress($Progress, [string]$Text, [string]$Channel = 'stdout') {
    if (!$Progress -or !$Text) { return }
    $Progress.LastActivity = $Progress.Clock.Elapsed.TotalSeconds
    $textBuffer = [string]$Progress.Pending[$Channel] + $Text
    $lines = [regex]::Split($textBuffer, '[\r\n]')
    $Progress.Pending[$Channel] = $lines[-1]
    # Some native prompts and progress updates have no newline. Reparse the last
    # fragment on the next chunk, retaining enough context for split percentages.
    if ($Progress.Pending[$Channel].Length -gt 4096) { $Progress.Pending[$Channel] = $Progress.Pending[$Channel].Substring($Progress.Pending[$Channel].Length - 4096) }
    foreach ($line in $lines) {
        if (!$line.Trim()) { continue }
        $stage = ''
        $percent = -1
        if ($Progress.Kind -eq 'Unity') {
            if ($line -match '\[Steam(?:Publisher|Uploader)\] Stage: (.+)') {
                $stage = switch ($Matches[1].Trim()) {
                    'Prepare' { '检查构建配置' }
                    'Addressables' { '构建 Addressables 资源' }
                    'Player' { '构建 Windows 包体' }
                    'Finalize' { '写入构建报告并退出 Unity' }
                }
            } elseif ($line -match '(?i)(Compiling shader|shader compilation)') { $stage = '编译 Shader' }
            elseif ($line -match '(?i)(IL2CPP|il2cpp.exe).*(convert|compile|invok|running)') { $stage = '编译 IL2CPP' }
            elseif ($line -match '(?i)(Start importing|Asset Pipeline Refresh|Importing.*asset)') { $stage = '导入或刷新资源' }
            elseif ($line -match '(?i)(Begin MonoManager ReloadAssembly|ScriptCompilation|Compiling scripts)') { $stage = '编译或加载脚本' }
        } elseif ($Progress.Kind -eq 'Steam') {
            if ($line -match '(?i)(password|Steam Guard|two.factor|authenticator|enter.*code)') {
                $Progress.AwaitingInput = $true
                $stage = '等待 Steam 登录验证，请按控制台提示操作'
            }
            if ($line -match '(?i)(Waiting for user info.*OK|Logged in OK|Logged on successfully)') {
                $Progress.AwaitingInput = $false
                $stage = '登录成功，等待 SteamPipe'
            } elseif ($line -match '(?i)(uploading|upload progress)') { $stage = '上传包体数据' }
            elseif ($line -match '(?i)(building depot|processing.*files|scanning|hashing|chunking)') { $stage = '扫描文件并生成数据块' }
            elseif ($line -match '(?i)(committing|commit.*build|finalizing)') { $stage = '提交构建，等待服务器确认' }
            elseif ($line -match '(?i)Successfully finished AppID') { $stage = '等待进程退出并校验回执' }
            elseif ($line -match '(?i)(downloading|update progress)') { $stage = '更新 SteamCMD' }
            if ($stage -and $line -match '(?<![\d.])([0-9]{1,3}(?:\.[0-9]+)?)\s*%') {
                $value = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
                if ($value -le 100) { $percent = [int][Math]::Floor($value) }
            }
        }
        if ($stage) {
            if ($stage -ne $Progress.Stage) { $Progress.Percent = -1 }
            $Progress.Stage = $stage
            if ($percent -ge 0) { $Progress.Percent = $percent }
        }
    }
}

function Read-UploaderProgressLogs($Progress) {
    foreach ($path in $Progress.LogPaths) {
        if (![IO.File]::Exists($path)) { continue }
        $stream = $null
        try {
            $stream = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $offset = [long]$Progress.Offsets[$path]
            if ($stream.Length -lt $offset) { $offset = 0; $Progress.Pending[$path] = '' }
            if ($stream.Length -eq $offset) { continue }
            # Bound reads even when Unity emits megabytes of import diagnostics.
            if ($stream.Length - $offset -gt 65536) { $offset = $stream.Length - 65536; $Progress.Pending[$path] = '' }
            $stream.Position = $offset
            $buffer = New-Object byte[] 65536
            $count = $stream.Read($buffer, 0, $buffer.Length)
            $Progress.Offsets[$path] = $stream.Position
            Update-UploaderProgress $Progress ($script:Utf8.GetString($buffer, 0, $count)) $path
        } catch [IO.IOException] {
            # Writers can briefly replace/lock logs. Progress must not fail a build.
        } catch [UnauthorizedAccessException] {
            # A readable process result remains authoritative if a log is unavailable.
        } finally { if ($stream) { $stream.Dispose() } }
    }
}

function Show-UploaderProgress($Progress, [switch]$Force) {
    if (!$Progress) { return }
    $seconds = $Progress.Clock.Elapsed.TotalSeconds
    if (!$Force -and $seconds - $Progress.LastRender -lt 0.5) { return }
    $Progress.LastRender = $seconds
    Read-UploaderProgressLogs $Progress
    if ($Progress.AwaitingInput) {
        Write-Progress -Id 71 -Activity $Progress.Activity -Completed
        return
    }
    $elapsed = '{0:00}:{1:00}:{2:00}' -f [Math]::Floor($seconds / 3600), $Progress.Clock.Elapsed.Minutes, $Progress.Clock.Elapsed.Seconds
    $indicator = if ($Progress.Percent -ge 0) { '{0}%（当前阶段）' -f $Progress.Percent }
        else { @('[=   ]','[ =  ]','[  = ]','[   =]')[[int][Math]::Floor($seconds * 2) % 4] + ' 进行中（无总百分比）' }
    $status = '{0} | {1} | 已用时 {2}' -f $Progress.Stage, $indicator, $elapsed
    if ($Progress.ProcessId) {
        $status += ' | PID {0} | 最近输出 {1:N0} 秒前' -f $Progress.ProcessId, ($seconds - $Progress.LastActivity)
    }
    Write-Progress -Id 71 -Activity $Progress.Activity -Status $status -PercentComplete $Progress.Percent
    # Remains visible in redirected output or hosts that hide Write-Progress.
    if ($Force -or $seconds - $Progress.LastHeartbeat -ge 15) {
        Write-Host ('[{0}] {1}' -f $Progress.Activity, $status)
        $Progress.LastHeartbeat = $seconds
    }
}

function Complete-UploaderProgress($Progress) {
    if ($Progress) {
        $Progress.Clock.Stop()
        Write-Progress -Id 71 -Activity $Progress.Activity -Completed
    }
}

function Invoke-UploaderProgram([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory, [scriptblock]$OnStart, $Progress = $null) {
    if (!(Test-Path -LiteralPath $Exe -PathType Leaf)) { throw "程序不存在：$Exe" }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = [IO.Path]::GetFullPath($Exe)
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:Utf8
    $info.StandardErrorEncoding = $script:Utf8
    # stdin stays inherited so SteamCMD can read password / Steam Guard directly.
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $bufferOut = New-Object char[] 1024
    $bufferErr = New-Object char[] 1024
    $all = New-Object Text.StringBuilder
    try {
        if (!$process.Start()) { throw '无法启动程序。' }
        if ($OnStart) { & $OnStart $process.Id }
        if ($Progress) {
            $Progress.ProcessId = $process.Id
            Show-UploaderProgress $Progress -Force
        }
        $pendingOut = $process.StandardOutput.ReadAsync($bufferOut, 0, $bufferOut.Length)
        $pendingErr = $process.StandardError.ReadAsync($bufferErr, 0, $bufferErr.Length)
        while ($null -ne $pendingOut -or $null -ne $pendingErr -or !$process.HasExited) {
            if ($null -ne $pendingOut -and $pendingOut.IsCompleted) {
                $n = $pendingOut.GetAwaiter().GetResult()
                if ($n -eq 0) { $pendingOut = $null }
                else {
                    $chunk = New-Object string($bufferOut, 0, $n)
                    Write-Host -NoNewline $chunk
                    [void]$all.Append($chunk)
                    Update-UploaderProgress $Progress $chunk 'stdout'
                    $pendingOut = $process.StandardOutput.ReadAsync($bufferOut, 0, $bufferOut.Length)
                }
            }
            if ($null -ne $pendingErr -and $pendingErr.IsCompleted) {
                $n = $pendingErr.GetAwaiter().GetResult()
                if ($n -eq 0) { $pendingErr = $null }
                else {
                    $chunk = New-Object string($bufferErr, 0, $n)
                    Write-Host -NoNewline $chunk
                    [void]$all.Append($chunk)
                    Update-UploaderProgress $Progress $chunk 'stderr'
                    $pendingErr = $process.StandardError.ReadAsync($bufferErr, 0, $bufferErr.Length)
                }
            }
            Show-UploaderProgress $Progress
            Start-Sleep -Milliseconds 25
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$all.ToString() }
    } finally { Complete-UploaderProgress $Progress; $process.Dispose() }
}

function Assert-SteamLoginResult($Result) {
    if ($Result.ExitCode -ne 0 -or $Result.Output -notmatch '(?is)(Waiting for user info\.\.\.OK|Logged in OK|Logged on successfully)' -or $Result.Output -match '(?i)(FAILED.*(login|logon)|Login Failure|Invalid Password)') {
        throw 'Steam 登录未确认成功。请检查账号、密码、Steam Guard 或网络后重试。工具未保存密码或验证码。'
    }
}

function Assert-NoActiveSteam([string]$DataRoot) {
    $path = Join-Path $DataRoot 'active-steam-process.json'
    if (![IO.File]::Exists($path)) { return }
    $journal = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if (Test-JournalProcess $journal) { throw '上次 SteamCMD 进程仍在运行，请等待或自行处理后重试。尚未确认的上传请先到 Steamworks 后台核实。' }
    [IO.File]::Delete($path)
}

function Invoke-TrackedSteam([string]$Exe, [string[]]$Arguments, [string]$DataRoot, $Progress = $null) {
    Assert-NoActiveSteam $DataRoot
    $path = Join-Path $DataRoot 'active-steam-process.json'
    $journal = [pscustomobject]@{ ProcessId=0; ProcessStartedUtc='' }
    $callback = {
        param($id)
        $journal.ProcessId = $id
        $journal.ProcessStartedUtc = (Get-Process -Id $id).StartTime.ToUniversalTime().ToString('o')
        Write-JsonFile $path $journal
    }.GetNewClosure()
    try { return Invoke-UploaderProgram $Exe $Arguments ([IO.Path]::GetDirectoryName($Exe)) $callback $Progress }
    finally {
        if (!(Test-JournalProcess $journal)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
        else { Write-Warning 'SteamCMD 尚未退出，已保留进程记录；请先核实本次上传状态，不要立即重复上传。' }
    }
}

function Connect-UploaderSteam($Profile, [string]$DataRoot = '') {
    Assert-SteamIds $Profile
    $arguments = @('+login', $Profile.SteamAccount, '+quit')
    $result = if ($DataRoot) { Invoke-TrackedSteam $Profile.SteamCmdPath $arguments $DataRoot }
        else { Invoke-UploaderProgram $Profile.SteamCmdPath $arguments ([IO.Path]::GetDirectoryName($Profile.SteamCmdPath)) }
    Assert-SteamLoginResult $result
    # Deliberately do not write the login console transcript to disk.
}

function Install-UploaderSteam([string]$DataRoot) {
    $destination = Join-Path $DataRoot 'steamcmd'
    if (Test-Path -LiteralPath (Join-Path $destination 'steamcmd.exe')) { return (Join-Path $destination 'steamcmd.exe') }
    $install = Join-Path $DataRoot ('install-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($install) | Out-Null
    $zip = Join-Path $install 'steamcmd.zip'
    $old = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $old -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip
        Expand-SafeZip $zip (Join-Path $install 'unpacked')
        $exe = Join-Path $install 'unpacked/steamcmd.exe'
        $signature = Get-AuthenticodeSignature -LiteralPath $exe
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Valve') { throw '下载的 SteamCMD 签名未通过 Valve 校验。' }
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.File]::Copy($exe, (Join-Path $destination 'steamcmd.exe'), $false)
        return (Join-Path $destination 'steamcmd.exe')
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $old
        Remove-OwnedTree $install $DataRoot
    }
}

function Read-SteamBuildResult([int]$ExitCode, [string]$Log, [string]$DepotVdf, [string]$AppId, [string]$DepotId, [switch]$Preview) {
    if ($ExitCode -ne 0) { throw "SteamCMD 返回失败退出码 $ExitCode。请查看本次 Steam 日志。" }
    if ($Preview) {
        if ($Log -notmatch ("(?i)Successfully finished AppID " + $AppId + " build preview")) { throw '本次 SteamPipe 预览没有成功完成。' }
        return [pscustomobject]@{ Preview=$true; BuildId=''; ManifestId='' }
    }
    $match = [regex]::Match($Log, "(?i)Successfully finished AppID $AppId build \(BuildID ([0-9]+)\)")
    if (!$match.Success) { throw '本次日志没有正式上传成功的 BuildID，不能把预览或旧记录当作成功。' }
    foreach ($pair in @(@('appid', $AppId), @('depotid', $DepotId))) {
        if ($DepotVdf -notmatch ('(?i)"' + $pair[0] + '"\s+"' + $pair[1] + '"')) { throw 'Depot 回执与本次上传目标不一致。' }
    }
    $manifest = [regex]::Match($DepotVdf, '(?i)"manifest"\s+"([0-9]+)"')
    if (!$manifest.Success -or $manifest.Groups[1].Value -eq '0') { throw '本次上传缺少有效 ManifestID。' }
    return [pscustomobject]@{ Preview=$false; BuildId=$match.Groups[1].Value; ManifestId=$manifest.Groups[1].Value }
}

function Invoke-SteamPackage($Profile, [string]$ContentRoot, [string]$DataRoot, [string]$RunRoot, [switch]$Preview) {
    Assert-SteamIds $Profile
    $phase = if ($Preview) { 'preview' } else { 'upload' }
    $phaseRoot = Join-Path $RunRoot $phase
    [IO.Directory]::CreateDirectory($phaseRoot) | Out-Null
    $cache = Join-Path $DataRoot ("cache/" + $Profile.AppId + '-' + $Profile.DepotId)
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $appLog = "app_build_$($Profile.AppId).log"
    $depotLog = "depot_build_$($Profile.DepotId).log"
    $depotVdf = "depot_build_$($Profile.DepotId).vdf"
    # Rotate only these known files before launching. Chunk caches stay reusable.
    foreach ($name in @($appLog, $depotLog, $depotVdf)) {
        $old = Assert-UnderRoot (Join-Path $cache $name) $DataRoot
        $archive = Assert-UnderRoot (Join-Path $phaseRoot ('previous-' + $name)) $DataRoot
        if ([IO.File]::Exists($old)) { [IO.File]::Move($old, $archive) }
    }
    $vdfPath = Join-Path $phaseRoot 'app_build.vdf'
    Write-AppVdf $Profile $ContentRoot $cache $vdfPath -Preview:$Preview
    $activity = if ($Preview) { 'SteamPipe 预览' } else { 'Steam 上传' }
    $progress = New-UploaderProgress $activity 'Steam' @((Join-Path $cache $appLog), (Join-Path $cache $depotLog))
    $progress.Stage = '连接 Steam 并准备包体'
    Write-Host ("{0}日志：{1}" -f $activity, $cache)
    try {
        $result = Invoke-TrackedSteam $Profile.SteamCmdPath @('+login', $Profile.SteamAccount, '+run_app_build', $vdfPath, '+quit') $DataRoot $progress
    } finally {
        foreach ($name in @($appLog, $depotLog, $depotVdf)) {
            if ([IO.File]::Exists((Join-Path $cache $name))) { [IO.File]::Copy((Join-Path $cache $name), (Join-Path $phaseRoot $name), $false) }
        }
    }
    $logText = if ([IO.File]::Exists((Join-Path $phaseRoot $appLog))) { [IO.File]::ReadAllText((Join-Path $phaseRoot $appLog)) } else { '' }
    $depotText = if ([IO.File]::Exists((Join-Path $phaseRoot $depotVdf))) { [IO.File]::ReadAllText((Join-Path $phaseRoot $depotVdf)) } else { '' }
    return Read-SteamBuildResult $result.ExitCode $logText $depotText $Profile.AppId $Profile.DepotId -Preview:$Preview
}

function Get-UnityProjectInfo([string]$Project) {
    $root = (Get-Item -LiteralPath $Project -Force).FullName
    Assert-NoLink $root
    foreach ($dir in @('Assets', 'ProjectSettings')) {
        if (!(Test-Path -LiteralPath (Join-Path $root $dir) -PathType Container)) { throw "不是 Unity 项目：缺少 $dir。" }
        Assert-NoLink (Join-Path $root $dir)
    }
    $versionPath = Join-Path $root 'ProjectSettings/ProjectVersion.txt'
    if (!(Test-Path -LiteralPath $versionPath)) { throw '项目缺少 ProjectVersion.txt。' }
    $match = [regex]::Match([IO.File]::ReadAllText($versionPath), '(?m)^m_EditorVersion:\s*(\S+)')
    if (!$match.Success) { throw '无法识别 Unity 项目版本。' }
    $product = 'Game'
    $settings = Join-Path $root 'ProjectSettings/ProjectSettings.asset'
    if ([IO.File]::Exists($settings)) {
        $m = [regex]::Match([IO.File]::ReadAllText($settings), '(?m)^\s*productName:\s*(.+)$')
        if ($m.Success) { $product = $m.Groups[1].Value.Trim().Trim('"') }
    }
    return [pscustomobject]@{ Root=$root; Version=$match.Groups[1].Value; ProductName=$product }
}

function Find-UnityEditor([string]$Version, [string]$Preferred) {
    $candidates = @()
    if ($Preferred) { $candidates += $Preferred }
    foreach ($base in @($env:ProgramFiles, [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if ($base) { $candidates += (Join-Path $base ("Unity/Hub/Editor/$Version/Editor/Unity.exe")) }
    }
    $hubInfo = Join-Path $env:APPDATA 'UnityHub/secondaryInstallPath.json'
    if ([IO.File]::Exists($hubInfo)) {
        try {
            $hubPath = [IO.File]::ReadAllText($hubInfo) | ConvertFrom-Json
            if ($hubPath -is [string]) { $candidates += (Join-Path $hubPath "$Version/Editor/Unity.exe") }
        } catch { }
    }
    foreach ($path in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return [IO.Path]::GetFullPath($path) }
    }
    return ''
}

function Assert-UnityReady([string]$Project, [string]$Editor, [string]$ExpectedVersion) {
    if (!(Test-Path -LiteralPath $Editor -PathType Leaf) -or [IO.Path]::GetFileName($Editor) -ine 'Unity.exe') { throw '请选择匹配版本的 Unity.exe。' }
    $editorFolder = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Editor))
    $folderVersion = Split-Path (Split-Path $editorFolder -Parent) -Leaf
    $binaryVersion = (Get-Item -LiteralPath $Editor).VersionInfo.ProductVersion
    if ($folderVersion -ne $ExpectedVersion -and (!$binaryVersion -or !$binaryVersion.StartsWith($ExpectedVersion, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Unity 版本不匹配，项目需要 $ExpectedVersion。请在 Hub 安装匹配版本，避免自动升级工程。"
    }
    $support = Join-Path $editorFolder 'Data/PlaybackEngines/windowsstandalonesupport'
    if (!(Test-Path -LiteralPath $support -PathType Container)) { throw '所选 Unity 缺少 Windows Standalone 构建支持，请在 Unity Hub 安装对应模块。' }
    Assert-UnityClosed $Project
}

function Assert-UnityClosed([string]$Project) {
    $lock = Join-Path $Project 'Temp/UnityLockfile'
    if ([IO.File]::Exists($lock)) {
        try { $handle = [IO.File]::Open($lock, 'Open', 'ReadWrite', 'None'); $handle.Dispose() }
        catch { throw '该 Unity 项目正在打开或被占用。请自行保存并关闭编辑器，再运行工具；工具不会控制 Play 模式或关闭编辑器。' }
    }
}

function Install-UnityHelper([string]$Project, [string]$Template, [string]$RunRoot) {
    if (@(Get-ChildItem -LiteralPath (Join-Path $Project 'Assets') -Directory | Where-Object { $_.Name -match '^Steam(?:Publisher|Uploader)Temp_' }).Count -gt 0) {
        throw '项目中已有 SteamUploader 临时助手目录。请先使用对应工具的数据目录恢复清理，或核对后手动移除。'
    }
    $name = 'SteamUploaderTemp_' + [guid]::NewGuid().ToString('N')
    $folder = Assert-UnderRoot (Join-Path $Project ("Assets/" + $name)) (Join-Path $Project 'Assets')
    [IO.Directory]::CreateDirectory((Join-Path $folder 'Editor')) | Out-Null
    $helper = Join-Path $folder 'Editor/SteamUploaderBuild.cs'
    [IO.File]::Copy($Template, $helper, $false)
    $journal = [pscustomobject]@{
        Project=[IO.Path]::GetFullPath($Project); Folder=$folder; HelperHash=(Get-Sha256 $helper)
        ProcessId=0; ProcessStartedUtc=''; Editor=''
    }
    Write-JsonFile (Join-Path $RunRoot 'unity-helper.json') $journal
    return $journal
}

function Clear-UnityHelper($Journal) {
    Assert-UnityClosed $Journal.Project
    $folder = Assert-UnderRoot $Journal.Folder (Join-Path $Journal.Project 'Assets')
    if ((Split-Path $folder -Leaf) -notmatch '^Steam(Publisher|Uploader)Temp_[a-f0-9]{32}$') { throw '临时构建助手目录标识不符，保留目录。' }
    $helperName = 'Steam' + $Matches[1] + 'Build.cs'
    if (Test-Path -LiteralPath $folder) {
        $helper = Join-Path $folder ('Editor/' + $helperName)
        if (!(Test-Path -LiteralPath $helper) -or (Get-Sha256 $helper) -ne $Journal.HelperHash) { throw '临时助手已被修改，保留目录以免覆盖其他工作。' }
        $allowed = @('Editor','Editor.meta',('Editor/' + $helperName),('Editor/' + $helperName + '.meta'))
        foreach ($entry in Get-ChildItem -LiteralPath $folder -Recurse -Force) {
            Assert-NoLink $entry.FullName
            $relative = $entry.FullName.Substring($folder.Length + 1).Replace('\','/')
            if ($relative -notin $allowed) { throw "临时助手目录出现未知内容，保留：$relative" }
        }
        Remove-OwnedTree $folder (Join-Path $Journal.Project 'Assets')
    }
    $meta = Assert-UnderRoot ($folder + '.meta') (Join-Path $Journal.Project 'Assets')
    if ([IO.File]::Exists($meta)) { [IO.File]::Delete($meta) }
}

function Test-JournalProcess($Journal) {
    if (!$Journal.ProcessId) { return $false }
    $p = Get-Process -Id $Journal.ProcessId -ErrorAction SilentlyContinue
    if (!$p) { return $false }
    try { return $p.StartTime.ToUniversalTime().ToString('o') -eq $Journal.ProcessStartedUtc }
    catch { return $true }
}

function Repair-UploaderHelpers([string]$DataRoot) {
    $runs = Join-Path $DataRoot 'runs'
    if (!(Test-Path -LiteralPath $runs)) { return }
    foreach ($run in Get-ChildItem -LiteralPath $runs -Directory) {
        $path = Join-Path $run.FullName 'unity-helper.json'
        if (![IO.File]::Exists($path)) { continue }
        $j = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if (Test-JournalProcess $j) { throw '上次由工具启动的 Unity 构建仍在运行。请等待它结束后重试。' }
        Clear-UnityHelper $j
        [IO.File]::Delete($path)
        Write-Host '已清理上次中断遗留的临时 Unity 构建助手。'
    }
}

function Invoke-UnityPackage($Profile, [string]$RawContent, [string]$RunRoot, [string]$Template) {
    $info = Get-UnityProjectInfo $Profile.UnityProject
    Assert-UnityReady $info.Root $Profile.UnityEditor $info.Version
    $requestPath = Join-Path $RunRoot 'unity-request.json'
    $reportPath = Join-Path $RunRoot 'unity-report.json'
    $logPath = Join-Path $RunRoot 'unity-build.log'
    $progress = New-UploaderProgress 'Unity 构建' 'Unity' @($logPath)
    $progress.Stage = '启动 Unity，等待项目加载'
    Write-Host ("构建日志：{0}" -f $logPath)
    Write-JsonFile $requestPath ([ordered]@{
        output=[IO.Path]::GetFullPath($RawContent); report=[IO.Path]::GetFullPath($reportPath)
        development=[bool]$Profile.DevelopmentBuild
    })
    $journal = Install-UnityHelper $info.Root $Template $RunRoot
    try {
        $callback = {
            param($id)
            $journal.ProcessId = $id
            $journal.ProcessStartedUtc = (Get-Process -Id $id).StartTime.ToUniversalTime().ToString('o')
            $journal.Editor = $Profile.UnityEditor
            Write-JsonFile (Join-Path $RunRoot 'unity-helper.json') $journal
        }.GetNewClosure()
        $result = Invoke-UploaderProgram $Profile.UnityEditor @('-batchmode','-quit','-projectPath',$info.Root,'-buildTarget','Win64','-executeMethod','SteamUploaderBuild.Run','-steamUploaderRequest',$requestPath,'-logFile',$logPath) ([IO.Path]::GetDirectoryName($Profile.UnityEditor)) $callback $progress
        if ($result.ExitCode -ne 0 -or ![IO.File]::Exists($reportPath)) { throw "Unity 构建未成功完成。请查看 $logPath" }
        $report = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
        if (!$report.succeeded -or $report.errors -gt 0) { throw "Unity 构建失败：$($report.message)。请查看构建日志。" }
        return $report
    } finally {
        if (Test-JournalProcess $journal) {
            Write-Warning '构建进程仍在运行，临时助手和恢复记录已保留；工具不会终止编辑器。进程退出后再次运行工具即可清理。'
        } else {
            Clear-UnityHelper $journal
            [IO.File]::Delete((Join-Path $RunRoot 'unity-helper.json'))
        }
    }
}

Export-ModuleMember -Function *
