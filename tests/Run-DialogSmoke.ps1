[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with powershell.exe -STA.' }
$toolRoot = Split-Path $PSScriptRoot -Parent
$output = Join-Path $toolRoot ('local-data/tests/dialog-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
Add-Type -Path @((Join-Path $toolRoot 'NativeFolderDialog.cs'), (Join-Path $PSScriptRoot 'NativeDialogSmoke.cs')) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Windows.Forms.dll','System.Drawing.dll')
[NativeDialogSmoke]::Run($output)
Write-Output $output
