[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolRoot 'Uploader.Core.psm1') -Force -DisableNameChecking
$root = Join-Path $toolRoot ('local-data/tests/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$results = New-Object Collections.ArrayList
function Check([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        [void]$results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})
        Write-Host ("PASS " + $Name)
    } catch {
        [void]$results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.ToString();Stack=$_.ScriptStackTrace})
        Write-Host ("FAIL " + $Name + ': ' + $_.ToString()) -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
}
function Assert([bool]$Condition, [string]$Message = 'Assertion failed') { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Body) {
    $thrown = $false
    try { & $Body | Out-Null } catch { $thrown = $true }
    Assert $thrown 'Expected rejection'
}
function Make-PE([string]$Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $bytes = New-Object byte[] 128
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[60]=64; $bytes[64]=0x50; $bytes[65]=0x45; $bytes[68]=0x64; $bytes[69]=0x86
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function Make-Zip([string]$Path, [string[]]$Names, [switch]$Link) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $Names) {
            $entry = $zip.CreateEntry($name)
            if ($Link) { $entry.ExternalAttributes = -1585446912 }
            $stream = $entry.Open()
            try { $stream.WriteByte(65) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
$fakeFolder = Join-Path $root '中文 tools & spaces'
[IO.Directory]::CreateDirectory($fakeFolder) | Out-Null
$fakeExe = Join-Path $fakeFolder 'steamcmd.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'FakeTools.cs') -OutputAssembly $fakeExe -OutputType ConsoleApplication -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$profile = New-UploaderProfile
$profile.Name = '中文 配置'
$profile.AppId = '4839140'; $profile.DepotId = '4839141'; $profile.SteamAccount = 'fixture_account'
$profile.Description = '测试 "quoted" description'; $profile.SteamCmdPath = $fakeExe
$source = Join-Path $root 'source 中文 & spaces'
Make-PE (Join-Path $source 'Game.exe')
Write-Utf8 (Join-Path $source 'data/file.txt') 'content'
Write-Utf8 (Join-Path $source 'steam_appid.txt') '480'
Write-Utf8 (Join-Path $source 'Game_BurstDebugInformation_DoNotShip/debug.txt') 'debug'
Write-Utf8 (Join-Path $source '.git/config') 'fixture'

Check 'PowerShell sources parse' {
    foreach ($path in @((Join-Path $toolRoot 'SteamUploader.ps1'), (Join-Path $toolRoot 'Uploader.Core.psm1'))) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ($errors | Out-String)
    }
}
Check 'Profiles: save, reload, update, no credential fields' {
    $profile | Add-Member NoteProperty Password 'must-not-persist' -Force
    Save-UploaderProfile $profile $root
    $loaded = @(Get-UploaderProfiles $root)
    Assert ($loaded.Count -eq 1)
    Assert ($loaded[0].Name -eq '中文 配置')
    $saved=[IO.File]::ReadAllText((Join-Path $root ('profiles/'+$profile.Id+'.json')))
    Assert (!$saved.Contains('must-not-persist'))
    $profile.Description = 'updated'
    Save-UploaderProfile $profile $root
    Assert (@(Get-UploaderProfiles $root)[0].Description -eq 'updated')
}
Check 'Profiles: all four operations and output folder round-trip' {
    $data=Join-Path $root 'profile-options'
    $p=New-UploaderProfile
    $p.OutputRoot=Join-Path $root '导出 & spaces'
    foreach ($operation in @('Upload','BuildUpload','BuildOnly','CheckOnly')) {
        $p.Operation=$operation
        Save-UploaderProfile $p $data
        $loaded=@(Get-UploaderProfiles $data)[0]
        Assert ($loaded.Operation -eq $operation -and $loaded.OutputRoot -eq $p.OutputRoot)
        Assert ($loaded.SchemaVersion -eq 2)
    }
    $p.Operation='Delete'
    Reject { Save-UploaderProfile $p $data }
}
Check 'Legacy profiles retain old fields and request only missing choices' {
    $data=Join-Path $root 'legacy-profiles'
    $p=New-UploaderProfile; $p.Name='旧配置'; $p.Description='keep description'; $p.SourcePath=$source
    $p.SchemaVersion=1; $p.PSObject.Properties.Remove('Operation'); $p.PSObject.Properties.Remove('OutputRoot')
    $p | Add-Member NoteProperty Password 'discard-on-migration'
    $path=Join-Path $data ('profiles/'+$p.Id+'.json')
    Write-JsonFile $path $p
    $before=Get-Sha256 $path
    $loaded=@(Get-UploaderProfiles $data)[0]
    Assert ($loaded.Name -eq $p.Name -and $loaded.SourcePath -eq $source -and $loaded.Description -eq $p.Description)
    Assert ($loaded.SchemaVersion -eq 2 -and $loaded.Operation -eq '' -and $loaded.OutputRoot -eq '')
    Assert (!$loaded.PSObject.Properties['Password'])
    Assert ((Get-Sha256 $path) -eq $before) 'Reading must not rewrite an old profile'
    $loaded.Operation='CheckOnly'; $loaded.OutputRoot=Join-Path $root 'legacy-output'
    Save-UploaderProfile $loaded $data
    Assert (@(Get-UploaderProfiles $data)[0].Operation -eq 'CheckOnly')
    Assert (![IO.File]::ReadAllText($path).Contains('discard-on-migration'))
    $loaded.PSObject.Properties.Remove('OutputRoot')
    Write-JsonFile $path $loaded
    Assert (@(Get-UploaderProfiles $data -WarningAction SilentlyContinue).Count -eq 0) 'Only v1 profiles may omit the new fields'
}
Check 'Export directories: unique runs preserve prior files and source' {
    $p=New-UploaderProfile; $p.SourcePath=$source; $p.OutputRoot=Join-Path $root 'custom 导出 & spaces'
    Write-Utf8 (Join-Path $p.OutputRoot 'keep.txt') 'unrelated output'
    $first=New-UploaderContentRoot $p (Join-Path $root 'runs/export-one')
    $null=Copy-Package $source $first $p.Exclusions
    $second=New-UploaderContentRoot $p (Join-Path $root 'runs/export-two')
    $null=Copy-Package $source $second $p.Exclusions
    Assert ($first -ne $second -and $first.StartsWith($p.OutputRoot))
    Assert ((Get-Sha256 (Join-Path $first 'Game.exe')) -eq (Get-Sha256 (Join-Path $second 'Game.exe')))
    Assert ([IO.File]::ReadAllText((Join-Path $p.OutputRoot 'keep.txt')) -eq 'unrelated output')
    Reject { New-UploaderContentRoot $p (Join-Path $root 'runs/export-one') }
    Assert ([IO.File]::Exists((Join-Path $source 'steam_appid.txt')))
}
Check 'Export directories reject relative, file, linked and source destinations' {
    foreach ($path in @('', 'relative/path', 'C:relative', '\relative', (Join-Path $source 'Game.exe/child'))) {
        Reject { Get-UploaderOutputRoot $path }
    }
    $p=New-UploaderProfile; $p.SourcePath=$source
    foreach ($path in @($source, (Join-Path $source 'exports'))) {
        $p.OutputRoot=$path
        Reject { New-UploaderContentRoot $p (Join-Path $root 'runs/invalid-export') }
    }
    $p.SourceType='Unity'; $p.UnityProject=Join-Path $root 'export-project'
    $p.OutputRoot=Join-Path $p.UnityProject 'Assets/Builds'
    Reject { New-UploaderContentRoot $p (Join-Path $root 'runs/invalid-export') }
    $target=Join-Path $root 'export-link-target'; [IO.Directory]::CreateDirectory($target)|Out-Null
    $link=Join-Path $root 'export-junction'
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Reject { Get-UploaderOutputRoot (Join-Path $link 'child') }
    Assert (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0)
}
Check 'Corrupt profile kept but skipped' {
    $path = Join-Path $root 'profiles/broken.json'
    Write-Utf8 $path '{bad json'
    Assert (@(Get-UploaderProfiles $root -WarningAction SilentlyContinue).Count -eq 1)
    Assert ([IO.File]::Exists($path))
}
Check 'Multiple profiles and invalid schema' {
    $other = New-UploaderProfile
    $other.Name = 'second'
    Save-UploaderProfile $other $root
    Assert (@(Get-UploaderProfiles $root -WarningAction SilentlyContinue).Count -eq 2)
    $other.SchemaVersion = 999
    Reject { Save-UploaderProfile $other $root }
}
Check 'Invalid IDs rejected' {
    $p=New-UploaderProfile; $p.SteamAccount='test'; $p.AppId='0'; $p.DepotId='1'
    Reject { Assert-SteamIds $p }
    $p.AppId='999999999999999999999'
    Reject { Assert-SteamIds $p }
    $p.AppId='123'; $p.DepotId='12"'
    Reject { Assert-SteamIds $p }
}
Check 'Glob exclusions cover root and nested diagnostics' {
    Assert (Test-Excluded 'Game_BurstDebugInformation_DoNotShip/debug.txt' $profile.Exclusions)
    Assert (Test-Excluded 'sub/steam_appid.txt' $profile.Exclusions)
    Assert (Test-Excluded '.git/config' $profile.Exclusions)
    Assert (!(Test-Excluded 'Game_Data/config.txt' $profile.Exclusions))
}
Check 'Package staging excludes files without modifying source' {
    $before=Get-Sha256 (Join-Path $source 'Game.exe')
    $excluded=Copy-Package $source (Join-Path $root 'staged') $profile.Exclusions
    Assert ($excluded.Count -eq 3) ('Excluded=' + $excluded.Count)
    Assert ([IO.File]::Exists((Join-Path $source 'steam_appid.txt')))
    Assert (!(Test-Path -LiteralPath (Join-Path $root 'staged/steam_appid.txt')))
    Assert ((Get-Sha256 (Join-Path $source 'Game.exe')) -eq $before)
}
Check 'Non-Unity PE package accepted and hashed' {
    $validation=Test-Package (Join-Path $root 'staged') 'Game.exe'
    Assert ($validation.FileCount -eq 2)
    Assert (!$validation.Unity)
}
Check 'Empty, missing EXE, invalid PE and escaped EXE rejected' {
    $empty=Join-Path $root 'empty'; [IO.Directory]::CreateDirectory($empty)|Out-Null
    Reject { Get-PackageCandidates $empty }
    Reject { Test-Package $source 'missing.exe' }
    Write-Utf8 (Join-Path $empty 'bad.exe') 'not PE'
    Reject { Test-Package $empty 'bad.exe' }
    Reject { Test-Package $source '../elsewhere.exe' }
}
Check 'Unity-specific runtime validation does not affect other engines' {
    $unity=Join-Path $root 'unity-content'
    Make-PE (Join-Path $unity 'Game.exe')
    Write-Utf8 (Join-Path $unity 'UnityPlayer.dll') 'fixture'
    Reject { Test-Package $unity 'Game.exe' }
    Write-Utf8 (Join-Path $unity 'Game_Data/globalgamemanagers') 'fixture'
    Write-Utf8 (Join-Path $unity 'Game_Data/Managed/Assembly-CSharp.dll') 'fixture'
    Assert (Test-Package $unity 'Game.exe').Unity
}
Check 'Unity project cannot be selected as package' {
    $project=Join-Path $root 'not-a-package'
    [IO.Directory]::CreateDirectory((Join-Path $project 'Assets'))|Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $project 'ProjectSettings'))|Out-Null
    Reject { Copy-Package $project (Join-Path $root 'wrong-stage') @() }
}
Check 'Nested package and multiple candidates detected' {
    $nested=Join-Path $root 'nested'
    Make-PE (Join-Path $nested 'wrapper/Game.exe')
    Assert (@(Get-PackageCandidates $nested).Count -eq 1)
    Make-PE (Join-Path $nested 'other/Another.exe')
    Assert (@(Get-PackageCandidates $nested).Count -eq 3)
}
Check 'Nested executable keeps sibling engine data in root choices' {
    $package=Join-Path $root 'engine'
    Make-PE (Join-Path $package 'bin/Game.exe')
    Write-Utf8 (Join-Path $package 'assets/data.bin') 'runtime data'
    $choices=@(Get-PackageCandidates $package)
    Assert ($choices[0] -eq $package)
    $stage=Join-Path $root 'engine-staged'
    $null=Copy-Package $choices[0] $stage @()
    Assert ((Test-Package $stage 'bin/Game.exe').FileCount -eq 2)
}
Check 'Safe ZIP expands under destination' {
    $zip=Join-Path $root 'safe.zip'
    Make-Zip $zip @('wrapper/file.txt','wrapper/data/another.txt')
    Expand-SafeZip $zip (Join-Path $root 'zip-safe')
    Assert ([IO.File]::Exists((Join-Path $root 'zip-safe/wrapper/file.txt')))
}
Check 'ZIP traversal, absolute paths, ADS, duplicates and links rejected' {
    $n=0
    foreach ($entries in @(@('../escape.txt'), @('/absolute.txt'), @('file.txt:stream'), @('file.txt','FILE.txt'), @('folder/../escape.txt'), @('CON.txt'))) {
        $n++; $zip=Join-Path $root "bad$n.zip"; Make-Zip $zip $entries
        Reject { Expand-SafeZip $zip (Join-Path $root "zip-bad$n") }
    }
    $zip=Join-Path $root 'symlink.zip'; Make-Zip $zip @('link') -Link
    Reject { Expand-SafeZip $zip (Join-Path $root 'zip-symlink') }
    Assert (!(Test-Path -LiteralPath (Join-Path $root 'escape.txt')))
}
Check 'Junction rejected for packaging and removed without touching target' {
    $outside=Join-Path $root 'shared'; Write-Utf8 (Join-Path $outside 'keep.txt') 'keep'
    $parent=Join-Path $root 'with-link'; [IO.Directory]::CreateDirectory($parent)|Out-Null
    $link=Join-Path $parent 'node_modules'
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
    Reject { Get-SafeFiles $parent }
    Remove-OwnedTree $parent $root
    Assert ([IO.File]::Exists((Join-Path $outside 'keep.txt')))
}
Check 'Destructive helper rejects root and sibling' {
    Reject { Remove-OwnedTree $root $root }
    Reject { Remove-OwnedTree ($root+'-other') $root }
}
Check 'VDF Unicode, escaping, preview and no publishing' {
    $p=New-UploaderProfile; $p.AppId='123'; $p.DepotId='456'; $p.SteamAccount='test'; $p.Description='中文 "quotes" \ slash'
    $vdf=Join-Path $root 'preview.vdf'
    Write-AppVdf $p $source (Join-Path $root 'cache') $vdf -Preview
    $text=[IO.File]::ReadAllText($vdf)
    Assert ($text.Contains('\"quotes\"'))
    Assert ($text.Contains('"Preview" "1"'))
    Assert (!$text.Contains('SetLive'))
    $bytes=[IO.File]::ReadAllBytes($vdf)
    Assert (!($bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb))
}
Check 'Native arguments: spaces, Unicode, quotes, empty and trailing slash' {
    $expected=@('中文 空格', 'a"b', '', 'C:\folder space\', 'a&b', 'a\b\"z')
    $result=Invoke-UploaderProgram $fakeExe (@('--echo')+$expected) $fakeFolder
    Assert ($result.ExitCode -eq 0)
    $decoded=@(($result.Output.TrimEnd([char]13,[char]10) -split '\r?\n') | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
    Assert (($decoded | ConvertTo-Json -Compress) -ceq ($expected | ConvertTo-Json -Compress)) ($decoded | Out-String)
}
Check 'Missing SteamCMD fails before invocation' {
    Reject { Invoke-UploaderProgram (Join-Path $root 'missing.exe') @() $root }
}
Check 'Login success and simulated Guard challenge' {
    foreach($mode in @('success','guard')) {
        $env:SP_FAKE_MODE=$mode
        Connect-UploaderSteam $profile
    }
}
Check 'Invalid login, network failure and cancelled login stop' {
    foreach($mode in @('loginfail','network','cancel')) {
        $env:SP_FAKE_MODE=$mode
        Reject { Connect-UploaderSteam $profile }
    }
    $env:SP_FAKE_MODE='success'
}
Check 'Preview and upload produce current IDs without publishing' {
    $run=Join-Path $root 'runs/good'
    $preview=Invoke-SteamPackage $profile $source $root $run -Preview
    Assert $preview.Preview
    $upload=Invoke-SteamPackage $profile $source $root $run
    Assert ($upload.BuildId -eq '12345678')
    Assert ($upload.ManifestId -eq '9876543210987654321')
}
Check 'Stale logs, preview-only success, nonzero exit and wrong manifest rejected' {
    foreach($mode in @('stale','previewonly','badexit','wrongmanifest')) {
        $env:SP_FAKE_MODE=$mode
        Reject { Invoke-SteamPackage $profile $source $root (Join-Path $root ('runs/'+$mode)) }
    }
    $env:SP_FAKE_MODE='success'
}
Check 'Concurrent tool instances cannot acquire same lock' {
    $handle=Enter-UploaderLock (Join-Path $root 'locked')
    try { Reject { Enter-UploaderLock (Join-Path $root 'locked') } } finally { $handle.Dispose() }
    $again=Enter-UploaderLock (Join-Path $root 'locked'); $again.Dispose()
}
Check 'Rename: new and old entrypoints share existing data and lock' {
    $install=Join-Path $root 'rename-fixture'
    $modern=Join-Path $install 'steam-uploader'
    [IO.Directory]::CreateDirectory($modern)|Out-Null
    Assert ((Get-UploaderDataRoot $modern) -eq (Join-Path $modern 'local-data'))
    $legacy=Join-Path $install 'steam-publisher/local-data'
    [IO.Directory]::CreateDirectory($legacy)|Out-Null
    Write-Utf8 (Join-Path $legacy 'profiles/keep.txt') 'existing profile'
    $chosen=Get-UploaderDataRoot $modern
    Assert ($chosen -eq $legacy)
    $oldLock=[IO.File]::Open((Join-Path $legacy 'publisher.lock'),'OpenOrCreate','ReadWrite','None')
    try { Reject { Enter-UploaderLock $chosen } } finally { $oldLock.Dispose() }
    Assert ([IO.File]::ReadAllText((Join-Path $chosen 'profiles/keep.txt')) -eq 'existing profile')
}

$projectRoot=Join-Path $root 'mock Unity project'
[IO.Directory]::CreateDirectory((Join-Path $projectRoot 'Assets'))|Out-Null
Write-Utf8 (Join-Path $projectRoot 'ProjectSettings/ProjectVersion.txt') 'm_EditorVersion: fixture-version'
$fakeUnity=Join-Path $root 'fixture-version/Editor/Unity.exe'
[IO.Directory]::CreateDirectory((Split-Path $fakeUnity -Parent))|Out-Null
[IO.File]::Copy($fakeExe,$fakeUnity)
[IO.Directory]::CreateDirectory((Join-Path (Split-Path $fakeUnity -Parent) 'Data/PlaybackEngines/windowsstandalonesupport'))|Out-Null
$unityProfile=New-UploaderProfile
$unityProfile.UnityProject=$projectRoot
$unityProfile.UnityEditor=$fakeUnity
Check 'Unity environment: correct version and module, occupied project rejected' {
    $info=Get-UnityProjectInfo $projectRoot
    Assert-UnityReady $projectRoot $fakeUnity $info.Version
    Reject { Assert-UnityReady $projectRoot $fakeUnity 'wrong-version' }
    $lockPath=Join-Path $projectRoot 'Temp/UnityLockfile'
    [IO.Directory]::CreateDirectory((Split-Path $lockPath -Parent))|Out-Null
    $held=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    try { Reject { Assert-UnityClosed $projectRoot } } finally { $held.Dispose() }
}
Check 'Mock Unity build success removes only owned helper' {
    $run=Join-Path $root 'runs/build-success'
    $report=Invoke-UnityPackage $unityProfile (Join-Path $run 'raw') $run (Join-Path $toolRoot 'UnityBuildHelper.cs')
    Assert $report.succeeded
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Assets') -Filter 'SteamUploaderTemp_*').Count -eq 0)
    Assert (![IO.File]::Exists((Join-Path $run 'unity-helper.json')))
}
Check 'Mock Unity failure stops and still cleans helper' {
    $env:SP_FAKE_MODE='buildfail'
    $run=Join-Path $root 'runs/build-failure'
    try { Reject { Invoke-UnityPackage $unityProfile (Join-Path $run 'raw') $run (Join-Path $toolRoot 'UnityBuildHelper.cs') } }
    finally { $env:SP_FAKE_MODE='success' }
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Assets') -Filter 'SteamUploaderTemp_*').Count -eq 0)
}
Check 'Interrupted helper cleanup preserves unknown or modified files' {
    $run=Join-Path $root 'runs/recovery'
    $j=Install-UnityHelper $projectRoot (Join-Path $toolRoot 'UnityBuildHelper.cs') $run
    Write-Utf8 (Join-Path $j.Folder 'unknown.txt') 'keep'
    Reject { Clear-UnityHelper $j }
    Assert ([IO.File]::Exists((Join-Path $j.Folder 'unknown.txt')))
    [IO.File]::Delete((Join-Path $j.Folder 'unknown.txt'))
    Repair-UploaderHelpers $root
    Assert (!(Test-Path -LiteralPath $j.Folder))
}
Check 'Rename: legacy helper journals can still be recovered' {
    $folder=Join-Path $projectRoot ('Assets/SteamPublisherTemp_'+[guid]::NewGuid().ToString('N'))
    $helper=Join-Path $folder 'Editor/SteamPublisherBuild.cs'
    Write-Utf8 $helper '// old tool helper fixture'
    $journal=[pscustomobject]@{Project=$projectRoot;Folder=$folder;HelperHash=(Get-Sha256 $helper);ProcessId=0;ProcessStartedUtc='';Editor=''}
    $run=Join-Path $root 'runs/legacy-helper'
    Write-JsonFile (Join-Path $run 'unity-helper.json') $journal
    Reject { Install-UnityHelper $projectRoot (Join-Path $toolRoot 'UnityBuildHelper.cs') $run }
    Repair-UploaderHelpers $root
    Assert (!(Test-Path -LiteralPath $folder))
    Assert (!(Test-Path -LiteralPath (Join-Path $run 'unity-helper.json')))
}
Check 'Entrypoint works outside tool working directory' {
    $ps=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $result=Invoke-UploaderProgram $ps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $toolRoot 'SteamUploader.ps1'),'-Help') $root
    Assert ($result.ExitCode -eq 0)
    Assert ($result.Output.Contains('SteamUploader'))
}
Check 'BAT invocation from CMD with spaces and Unicode' {
    $copy=Join-Path $root '启动工具 & spaces'
    [IO.Directory]::CreateDirectory($copy)|Out-Null
    foreach($name in @('SteamUploader.bat','SteamUploader.ps1','Uploader.Core.psm1')) {
        [IO.File]::Copy((Join-Path $toolRoot $name),(Join-Path $copy $name))
    }
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:WINDIR 'System32/cmd.exe'
    $start.Arguments='/d /s /c ""' + (Join-Path $copy 'SteamUploader.bat') + '" -Help"'
    $start.WorkingDirectory=$root
    $start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.EnvironmentVariables['STEAM_UPLOADER_NO_PAUSE']='1'
    $process=[Diagnostics.Process]::Start($start)
    $outTask=$process.StandardOutput.ReadToEndAsync()
    $errTask=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    try { Assert ($process.ExitCode -eq 0) ($outTask.Result+$errTask.Result) } finally {$process.Dispose()}
}
function Run-WizardFixture([string]$CaseName, [string]$RunMode, [string[]]$Answers, [switch]$Unity, [switch]$MissingSource,
    [string]$SavedOperation = 'Upload', [switch]$Legacy, [switch]$NewProfile, [switch]$Reuse) {
    $copy = Join-Path $root ("wizard-" + $CaseName)
    [IO.Directory]::CreateDirectory($copy) | Out-Null
    foreach ($file in @('SteamUploader.ps1','Uploader.Core.psm1','UnityBuildHelper.cs','NativeFolderDialog.cs')) {
        if (!$Reuse) { [IO.File]::Copy((Join-Path $toolRoot $file),(Join-Path $copy $file)) }
    }
    $p=New-UploaderProfile
    $p.Name='交互测试'; $p.SteamAccount='fixture'; $p.AppId='4839140'; $p.DepotId='4839141'
    $p.SteamCmdPath=$fakeExe; $p.SourcePath=$source; $p.Executable='Game.exe'; $p.Description='fixture'
    $p.UnityProject=$projectRoot; $p.UnityEditor=$fakeUnity
    $p.Operation=$SavedOperation; $p.OutputRoot=Join-Path $root ('exports 中文 & spaces/' + $CaseName)
    if($Unity){$p.SourceType='Unity'}
    if($MissingSource){$p.SourcePath=Join-Path $root 'missing-source'}
    $data=Join-Path $copy 'local-data'
    if ($Reuse) { $p=@(Get-UploaderProfiles $data)[0] }
    elseif ($Legacy) {
        $p.SchemaVersion=1; $p.PSObject.Properties.Remove('Operation'); $p.PSObject.Properties.Remove('OutputRoot')
        Write-JsonFile (Join-Path $data ('profiles/'+$p.Id+'.json')) $p
    } elseif (!$NewProfile) { Save-UploaderProfile $p $data }
    $beforeProfile=$p | ConvertTo-Json -Depth 6
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $parameters=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $copy 'SteamUploader.ps1'),'-Mode',$RunMode,'-NoBrowser')
    if (!$NewProfile) { $parameters+=@('-ProfileId',$p.Id) }
    $start.Arguments=($parameters | ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
    $start.WorkingDirectory=$root
    $start.UseShellExecute=$false
    $start.RedirectStandardInput=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    $outTask=$process.StandardOutput.ReadToEndAsync()
    $errTask=$process.StandardError.ReadToEndAsync()
    foreach($answer in $Answers){$process.StandardInput.WriteLine($answer)}
    $process.StandardInput.Close()
    if(!$process.WaitForExit(25000)){$process.Kill();throw 'Offline wizard fixture timed out'}
    $output=$outTask.Result+$errTask.Result
    $exit=$process.ExitCode
    $process.Dispose()
    Write-Utf8 (Join-Path $copy 'test-console.txt') $output
    Assert ([regex]::Matches($output, '(?m)^本次 Description：').Count -eq 1) ('Each run must confirm Description once: ' + $output)
    $run=@(Get-ChildItem -LiteralPath (Join-Path $data 'runs') -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1)
    $state=if($run.Count){[IO.File]::ReadAllText((Join-Path $run[0].FullName 'result.json')) | ConvertFrom-Json}else{$null}
    return [pscustomobject]@{ExitCode=$exit; Output=$output; State=$state; Run=if($run.Count){$run[0].FullName}else{''}; Data=$data; Profile=@(Get-UploaderProfiles $data)[0]; BeforeProfile=($beforeProfile | ConvertFrom-Json)}
}
Check 'Full wizard: saved profile, staging, preview, CheckOnly' {
    $r=Run-WizardFixture 'check' 'Wizard' @('1','') -SavedOperation CheckOnly
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.State.Status -eq 'Checked')
    Assert ($r.Profile.Description -eq 'fixture') 'Enter must retain the saved description'
    Assert (!(Test-Path -LiteralPath (Join-Path $r.Run 'upload-receipt.json')))
    Assert (!$r.Output.Contains('操作（保存到预设）'))
    Assert ([IO.File]::Exists((Join-Path $r.State.ContentRoot 'Game.exe')))
}
Check 'Full wizard: offline upload, receipt, no branch activation' {
    $r=Run-WizardFixture 'upload' 'Wizard' @('1','本次发布说明','1')
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.State.Status -eq 'Uploaded')
    $receipt=[IO.File]::ReadAllText((Join-Path $r.Run 'upload-receipt.json'))|ConvertFrom-Json
    Assert ($receipt.BuildId -eq '12345678' -and $receipt.SetLive -eq '')
    Assert ($r.Profile.Description -eq '本次发布说明' -and $receipt.Description -eq '本次发布说明')
    Assert ($receipt.ContentRoot -eq $r.State.ContentRoot -and $receipt.ContentRoot.StartsWith($r.Profile.OutputRoot))
    $vdf=Get-ChildItem -LiteralPath (Join-Path $r.Run 'upload') -Filter '*.vdf' | Select-Object -First 1
    Assert ([IO.File]::ReadAllText($vdf.FullName).Contains($receipt.ContentRoot.Replace('\','/')))
    Assert ([IO.File]::ReadAllText($vdf.FullName).Contains('本次发布说明'))
}
Check 'Full wizard: cancel before upload leaves no receipt' {
    $r=Run-WizardFixture 'cancel' 'Wizard' @('1','','2')
    Assert ($r.ExitCode -eq 2) $r.Output
    Assert ($r.State.Status -eq 'Cancelled')
    Assert (!(Test-Path -LiteralPath (Join-Path $r.Run 'upload')))
}
Check 'Full wizard: BuildOnly never requires Steam login' {
    $env:SP_FAKE_MODE='loginfail'
    try {$r=Run-WizardFixture 'build-only' 'Wizard' @('1','','1') -Unity -SavedOperation BuildOnly}
    finally {$env:SP_FAKE_MODE='success'}
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.State.Status -eq 'Built')
    Assert (!$r.Output.Contains('Login Failure'))
    Assert ($r.Output.Contains('未生成 ZIP'))
    Assert ($r.Output.Contains((Join-Path $r.State.ContentRoot 'Game.exe')))
    Assert ($r.State.ContentRoot.StartsWith($r.Profile.OutputRoot))
    Assert ($r.Output.Contains(('包体来源：Unity  ' + $projectRoot)))
    Assert (!$r.Output.Contains(('包体来源：Unity  ' + $source)))
}
Check 'Full wizard: build and upload with mock processes only' {
    $r=Run-WizardFixture 'build-upload' 'Wizard' @('1','','1','1') -Unity -SavedOperation BuildUpload
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.State.Status -eq 'Uploaded')
}
Check 'Full wizard: new preset then reuse skips all saved path and operation prompts' {
    $export=Join-Path $root 'new preset 导出'
    $r=Run-WizardFixture 'new-preset' 'Wizard' @('3','新构建配置',$export,$projectRoot,$fakeUnity,'1','Game.exe','-','','1') -NewProfile
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.Profile.Operation -eq 'BuildOnly' -and $r.Profile.OutputRoot -eq $export)
    $first=$r.State.ContentRoot
    $again=Run-WizardFixture 'new-preset' 'Wizard' @('1','','1') -Reuse
    Assert ($again.ExitCode -eq 0) $again.Output
    Assert (!$again.Output.Contains('操作（保存到预设）') -and !$again.Output.Contains('回车/s 保留 / b 浏览'))
    Assert ($again.State.ContentRoot -ne $first)
    Assert ([IO.File]::Exists((Join-Path $first 'Game.exe')))
}
Check 'Full wizard: modifying a preset saves the changed operation and output folder' {
    $export=Join-Path $root 'changed 导出'
    $r=Run-WizardFixture 'edit-options' 'Wizard' @('2','3','3','4',$export,'1','','1')
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.Profile.Operation -eq 'BuildOnly' -and $r.Profile.OutputRoot -eq $export)
    Assert ($r.State.Status -eq 'Built')
    $again=Run-WizardFixture 'edit-options' 'Wizard' @('1','','1') -Reuse
    Assert ($again.ExitCode -eq 0 -and $again.State.Status -eq 'Built') $again.Output
}
Check 'Full wizard: old preset asks new choices once without re-entering old fields' {
    $export=Join-Path $root 'legacy 导出'
    $r=Run-WizardFixture 'legacy' 'Wizard' @('1','4',$export,'') -Legacy
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.State.Status -eq 'Checked' -and $r.Profile.Operation -eq 'CheckOnly')
    Assert ($r.Profile.OutputRoot -eq $export -and $r.Profile.Description -eq 'fixture')
    $again=Run-WizardFixture 'legacy' 'Wizard' @('1','') -Reuse
    Assert ($again.ExitCode -eq 0) $again.Output
    Assert (!$again.Output.Contains('操作（保存到预设）') -and !$again.Output.Contains('回车/s 保留 / b 浏览'))
}
Check 'Edit menu: changing only Description preserves every other saved field' {
    $r=Run-WizardFixture 'edit-description' 'Wizard' @('2','15','new description','1','') -SavedOperation CheckOnly
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.Profile.Description -eq 'new description')
    foreach ($field in $r.BeforeProfile.PSObject.Properties.Name | Where-Object { $_ -ne 'Description' }) {
        Assert (($r.Profile.$field | ConvertTo-Json -Compress) -ceq ($r.BeforeProfile.$field | ConvertTo-Json -Compress)) ('Changed skipped field: '+$field)
    }
    Assert (!$r.Output.Contains('回车/s 保留 / b 浏览')) 'Editing a description must not prompt for any path'
}
Check 'Edit menu: skip selected text, path and choice fields and finish unchanged' {
    $r=Run-WizardFixture 'edit-skip' 'Wizard' @('2','4','s','15','s','8','s','9','s','1','') -SavedOperation CheckOnly
    Assert ($r.ExitCode -eq 0) $r.Output
    foreach ($field in $r.BeforeProfile.PSObject.Properties.Name) {
        Assert (($r.Profile.$field | ConvertTo-Json -Compress) -ceq ($r.BeforeProfile.$field | ConvertTo-Json -Compress)) ('Changed skipped field: '+$field)
    }
}
Check 'Edit menu: legacy preset can fill just missing options then continue' {
    $export=Join-Path $root 'legacy menu 导出'
    $r=Run-WizardFixture 'legacy-menu' 'Wizard' @('2','3','4','4',$export,'1','') -Legacy
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.Profile.Operation -eq 'CheckOnly' -and $r.Profile.OutputRoot -eq $export)
    Assert ($r.Profile.Description -eq 'fixture' -and $r.Profile.UnityProject -eq $projectRoot)
}
Check 'Edit menu: finish immediately only confirms Description' {
    $r=Run-WizardFixture 'edit-none' 'Wizard' @('2','','') -SavedOperation CheckOnly
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert (!$r.Output.Contains('操作（保存到预设）') -and !$r.Output.Contains('回车/s 保留 / b 浏览'))
}
Check 'Full wizard: explicit mode replaces and saves the preset operation' {
    $r=Run-WizardFixture 'explicit-mode' 'CheckOnly' @('1','') -SavedOperation Upload
    Assert ($r.ExitCode -eq 0 -and $r.State.Status -eq 'Checked') $r.Output
    Assert ($r.Profile.Operation -eq 'CheckOnly')
}
Check 'Missing source can switch to Unity environment check' {
    $r=Run-WizardFixture 'missing' 'CheckOnly' @('1','2',$projectRoot,'') -MissingSource
    Assert ($r.ExitCode -eq 0) $r.Output
    Assert ($r.State.Status -eq 'EnvironmentChecked')
    Assert (!(Test-Path -LiteralPath (Join-Path $r.Run 'raw-content')))
    Assert ($r.State.ContentRoot -eq '' -and !(Test-Path -LiteralPath $r.Profile.OutputRoot))
}
Check 'Active native process blocks subsequent Steam operations' {
    $data=Join-Path $root 'active-process'
    Write-JsonFile (Join-Path $data 'active-steam-process.json') ([pscustomobject]@{ProcessId=$PID;ProcessStartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')})
    Reject { Assert-NoActiveSteam $data }
    Write-JsonFile (Join-Path $data 'active-steam-process.json') ([pscustomobject]@{ProcessId=0;ProcessStartedUtc=''})
    Assert-NoActiveSteam $data
}
Check 'Owned path guard rejects linked ancestor' {
    $target=Join-Path $root 'ancestor-target'; [IO.Directory]::CreateDirectory($target)|Out-Null
    $parent=Join-Path $root 'ancestor-parent'; [IO.Directory]::CreateDirectory($parent)|Out-Null
    $link=Join-Path $parent 'junction'
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Reject { Assert-UnderRoot (Join-Path $link 'victim.txt') $parent }
    Remove-OwnedTree $parent $root
}
Check 'Native Steam Guard reads inherited stdin without exposing input' {
    $scriptPath=Join-Path $root 'guard-native.ps1'
    $modulePath=(Join-Path $toolRoot 'Uploader.Core.psm1').Replace("'","''")
    $exePath=$fakeExe.Replace("'","''")
    $code="Import-Module '$modulePath' -DisableNameChecking" + [Environment]::NewLine +
        '$p=New-UploaderProfile; $p.AppId="1"; $p.DepotId="2"; $p.SteamAccount="fixture"; ' +
        ('$p.SteamCmdPath=' + "'$exePath'; Connect-UploaderSteam " + '$p')
    [IO.File]::WriteAllText($scriptPath,$code,(New-Object Text.UTF8Encoding($true)))
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $start.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) | ForEach-Object {ConvertTo-NativeArgument $_}) -join ' '
    $start.UseShellExecute=$false
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.EnvironmentVariables['SP_FAKE_MODE']='guardread'
    $proc=[Diagnostics.Process]::Start($start)
    $out=$proc.StandardOutput.ReadToEndAsync(); $err=$proc.StandardError.ReadToEndAsync()
    try {
        $proc.StandardInput.WriteLine('123456'); $proc.StandardInput.Close()
        if(!$proc.WaitForExit(15000)){$proc.Kill();throw 'Mock native input timed out'}
        Assert ($proc.ExitCode -eq 0) ($out.Result+$err.Result)
        Assert ($out.Result.Contains('Guard input received'))
        Assert (!$out.Result.Contains('123456'))
    } finally {$proc.Dispose()}
}
Check 'Offline installer: signed download, signature and network rejection' {
    $fixture=Join-Path $root 'installer-fixture.zip'
    Make-Zip $fixture @('steamcmd.exe')
    $module=Get-Module Uploader.Core
    try {
        & $module {
            param($zip)
            $script:InstallerFixtureZip=$zip
            $script:InstallerFixtureMode='success'
            function script:Invoke-WebRequest {
                param([switch]$UseBasicParsing,[string]$Uri,[string]$OutFile)
                if($Uri -ne 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'){throw 'Unexpected URL'}
                if($script:InstallerFixtureMode -eq 'network'){throw 'Simulated network error'}
                [IO.File]::Copy($script:InstallerFixtureZip,$OutFile,$false)
            }
            function script:Get-AuthenticodeSignature {
                param([string]$LiteralPath)
                return [pscustomobject]@{Status=if($script:InstallerFixtureMode -eq 'signature'){'NotSigned'}else{'Valid'};SignerCertificate=[pscustomobject]@{Subject='CN=Valve Corp.'}}
            }
        } $fixture
        $data=Join-Path $root 'install-success'
        $exe=Install-UploaderSteam $data
        Assert ([IO.File]::Exists($exe))
        foreach($mode in @('signature','network')){
            & $module {param($m) $script:InstallerFixtureMode=$m} $mode
            $data=Join-Path $root ('install-'+$mode)
            Reject {Install-UploaderSteam $data}
            Assert (!(Test-Path -LiteralPath (Join-Path $data 'steamcmd/steamcmd.exe')))
            Assert (@(Get-ChildItem -LiteralPath $data -Filter 'install-*').Count -eq 0)
        }
    } finally {
        & $module {
            Remove-Item -LiteralPath Function:\Invoke-WebRequest,Function:\Get-AuthenticodeSignature
            Remove-Variable -Scope Script -Name InstallerFixtureZip,InstallerFixtureMode
        }
    }
}
Check 'Windows path dialogs: folder, ZIP and EXE filters and defaults' {
    $folder=New-UploaderPathDialog 'Folder test' $source 'Folder'
    $zip=New-UploaderPathDialog 'ZIP test' '' 'Zip'
    $exe=New-UploaderPathDialog 'EXE test' $fakeExe 'Exe'
    $emptyFolder=New-UploaderPathDialog 'Empty folder test' '' 'Folder'
    $outputFolder=New-UploaderPathDialog 'Export test' $source 'OutputFolder'
    try {
        Assert ($folder.SelectedPath -eq $source)
        Assert ($folder.GetType().FullName -eq 'SteamUploader.NativeFolderDialog')
        Assert ($folder.Title -eq 'Folder test' -and $outputFolder.Title -eq 'Export test')
        Assert ($outputFolder.SelectedPath -eq $source)
        Assert ($zip.Filter -eq 'ZIP 包体 (*.zip)|*.zip')
        Assert ($zip.CheckFileExists -and !$zip.Multiselect -and $zip.AutoUpgradeEnabled)
        Assert ($exe.Filter.Contains('*.exe') -and $exe.FileName -eq 'steamcmd.exe')
        Assert ($exe.InitialDirectory -eq $fakeFolder)
    } finally { $folder.Dispose(); $zip.Dispose(); $exe.Dispose(); $emptyFolder.Dispose(); $outputFolder.Dispose() }
}
Check 'Path dialogs announce their purpose before creating the modal window' {
    $module=Get-Module Uploader.Core
    $observed=& $module {
        $original=(Get-Command New-UploaderPathDialog).ScriptBlock
        $script:DialogEvents=New-Object Collections.ArrayList
        try {
            function script:Write-Host { param($Object) [void]$script:DialogEvents.Add([string]$Object) }
            function script:New-UploaderPathDialog { param($Label,$Default,$Kind) [void]$script:DialogEvents.Add('CREATE: '+$Label); throw 'Simulated dialog unavailable' }
            foreach ($label in @('导出文件夹','Unity 项目目录','Unity.exe 编辑器文件','现成 ZIP 文件','SteamCMD 程序文件')) {
                $null=Show-UploaderPathDialog $label '' 'Folder' -WarningAction SilentlyContinue
            }
            return ,@($script:DialogEvents)
        } finally {
            Set-Item -Path Function:script:New-UploaderPathDialog -Value $original
            Remove-Item -LiteralPath Function:\Write-Host
            Remove-Variable -Scope Script -Name DialogEvents
        }
    }
    Assert ($observed.Count -eq 15)
    for ($i=0; $i -lt $observed.Count; $i+=3) {
        Assert ($observed[$i].StartsWith('正在选择：'))
        Assert ($observed[$i+2] -eq ('CREATE: '+$observed[$i].Substring(5))) 'Purpose must precede dialog creation'
    }
}
Check 'Path prompt: browse, cancel to paste, quoted path, reuse and quit' {
    $module=Get-Module Uploader.Core
    $observed=& $module {
        $original=(Get-Command Show-UploaderPathDialog).ScriptBlock
        try {
            $script:PathAnswers=New-Object Collections.Queue
            $script:PathSelection='D:\包体 with spaces\Game.zip'
            function script:Read-Host {param($Prompt) return $script:PathAnswers.Dequeue()}
            function script:Show-UploaderPathDialog {param($Label,$Default,$Kind) return $script:PathSelection}
            $script:PathAnswers.Enqueue('b')
            $browse=Read-UploaderPath 'ZIP' 'D:\old.zip' -Kind Zip -Required
            $script:PathSelection=''
            $script:PathAnswers.Enqueue('b')
            $script:PathAnswers.Enqueue('"D:\包体 with spaces\New.zip"')
            $pasted=Read-UploaderPath 'ZIP' 'D:\old.zip' -Kind Zip -Required
            $script:PathAnswers.Enqueue('')
            $reused=Read-UploaderPath 'Folder' 'D:\已有包体' -Kind Folder -Required
            $script:PathAnswers.Enqueue("'D:\single quoted.zip'")
            $single=Read-UploaderPath 'ZIP' -Kind Zip
            $script:PathAnswers.Enqueue('q')
            $cancelled=$false
            try{Read-UploaderPath 'ZIP' -Kind Zip | Out-Null}catch [OperationCanceledException]{$cancelled=$true}
            [pscustomobject]@{Browse=$browse;Pasted=$pasted;Reused=$reused;Single=$single;Cancelled=$cancelled}
        } finally {
            Set-Item -Path Function:script:Show-UploaderPathDialog -Value $original
            Remove-Item -LiteralPath Function:\Read-Host
            Remove-Variable -Scope Script -Name PathAnswers,PathSelection
        }
    }
    Assert ($observed.Browse -eq 'D:\包体 with spaces\Game.zip')
    Assert ($observed.Pasted -eq 'D:\包体 with spaces\New.zip')
    Assert ($observed.Reused -eq 'D:\已有包体')
    Assert ($observed.Single -eq 'D:\single quoted.zip')
    Assert $observed.Cancelled
}
Check 'Progress: split percentage, phase reset and login prompt' {
    $progress = New-UploaderProgress 'fixture' 'Steam'
    Update-UploaderProgress $progress 'Uploading content (30.'
    Assert ($progress.Percent -eq -1)
    Update-UploaderProgress $progress "5%)`r"
    Assert ($progress.Percent -eq 30)
    Update-UploaderProgress $progress "Committing build...`n"
    Assert ($progress.Percent -eq -1 -and $progress.Stage -match '服务器确认')
    Update-UploaderProgress $progress 'Steam Guard code: '
    Assert $progress.AwaitingInput
    Update-UploaderProgress $progress "`nWaiting for user info...OK`n"
    Assert (!$progress.AwaitingInput)
    Update-UploaderProgress $progress "Uploading content (100%)`n"
    Assert ($progress.Stage -eq '上传包体数据') '100% is not a successful receipt'
    Complete-UploaderProgress $progress
}
Check 'Progress: missing, appended and truncated logs' {
    $log = Join-Path $root 'progress-tail.log'
    $progress = New-UploaderProgress 'fixture' 'Unity' @($log)
    Read-UploaderProgressLogs $progress
    Write-Utf8 $log '[SteamUploader] Stage: Address'
    Read-UploaderProgressLogs $progress
    [IO.File]::AppendAllText($log, "ables`n", [Text.Encoding]::UTF8)
    Read-UploaderProgressLogs $progress
    Assert ($progress.Stage -eq '构建 Addressables 资源')
    Write-Utf8 $log "[SteamUploader] Stage: Player`n"
    Read-UploaderProgressLogs $progress
    Assert ($progress.Stage -eq '构建 Windows 包体')
    Assert ($progress.Percent -eq -1) 'Unity must never get an invented percentage'
    Complete-UploaderProgress $progress
}
Check 'Progress: live quiet log, live stdout and cleanup after nonzero exit' {
    $module = Get-Module Uploader.Core
    & $module {
        $script:ProgressRecords = New-Object Collections.ArrayList
        function script:Write-Progress {
            param($Id, $Activity, $Status, $PercentComplete, [switch]$Completed)
            [void]$script:ProgressRecords.Add([pscustomobject]@{ Status=$Status; Percent=$PercentComplete; Completed=[bool]$Completed })
        }
    }
    try {
        $log = Join-Path $root 'live-progress.log'
        $progress = New-UploaderProgress 'fixture' 'Unity' @($log)
        $result = Invoke-UploaderProgram $fakeExe @('--progress-log', $log) $fakeFolder -Progress $progress
        $records = & $module { @($script:ProgressRecords) }
        Assert ($result.ExitCode -eq 5)
        Assert (@($records | Where-Object { $_.Status -match 'Addressables' }).Count -gt 0)
        Assert (@($records | Where-Object { $_.Status -match 'Windows 包体' }).Count -gt 0)
        Assert $records[-1].Completed
        & $module { $script:ProgressRecords.Clear() }
        $progress = New-UploaderProgress 'fixture' 'Steam'
        $result = Invoke-UploaderProgram $fakeExe @('--progress-output') $fakeFolder -Progress $progress
        $records = & $module { @($script:ProgressRecords) }
        Assert ($result.ExitCode -eq 0)
        Assert (@($records | Where-Object { $_.Percent -eq 30 }).Count -gt 0) 'Percentage must be visible while the process is running'
        Assert $records[-1].Completed
    } finally {
        & $module {
            Remove-Item -LiteralPath Function:\Write-Progress
            Remove-Variable -Scope Script -Name ProgressRecords
        }
    }
}
$env:SP_FAKE_MODE=$null
Write-JsonFile (Join-Path $root 'results.json') @($results)
$failed=@($results | Where-Object {!$_.Passed})
Write-Host ("Tests: {0}; failed: {1}; results: {2}" -f $results.Count,$failed.Count,$root)
if($failed.Count){exit 1}
exit 0
