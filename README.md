# SteamUploader 使用说明

Windows 中文交互工具：上传已有游戏文件夹或 ZIP，或者选择 Unity 项目，生成 Windows 64 位包体后上传 Steam。

**入口是同目录的 `SteamUploader.bat`。第一次按提示配置，以后选择保存的配置即可。** 每次正式上传前都会展示目标和文件信息，再询问是否开始。工具只上传，不自动发布分支。

## 1. 启动

不需要管理员权限，也不需要 Python、Node 或 PowerShell 7。BAT 使用系统自带 Windows PowerShell 5.1，执行策略仅对本次进程生效。

- 直接双击 `SteamUploader.bat`。
- 打开 CMD，把 BAT 拖进去，回车。
- 打开 PowerShell，先输入 `& `，再拖入 BAT，回车。带空格的路径会被加引号；单独的引号路径在 PowerShell 中只是字符串。

本项目的 PowerShell 命令：

```powershell
& "D:\UnityProject\nodedraw\tools\steam-uploader\SteamUploader.bat"
```

CMD：

```bat
"D:\UnityProject\nodedraw\tools\steam-uploader\SteamUploader.bat"
```

整个 `steam-uploader` 文件夹可以复制到其他位置。不要只复制 BAT，它需要旁边的脚本、模块和构建助手。运行不依赖终端当前目录。

工具已从 SteamPublisher 更名为 **SteamUploader**。启动时显示立体 STEAM 字标，副标题为 UPLOADER。旧 `steam-publisher/SteamPublisher.bat` 或 `.ps1` 入口仍会跳转到新工具。

字标颜色在 `SteamUploader.ps1` 开头的 `BannerColors` 中修改：`Face` 是字面，`Side` 是立体侧边，`Subtitle` 是副标题。支持 `00adee` 或 `#00adee` 这样的6位十六进制色值；默认字面为 `FFFFFF`，侧边和副标题为 `00adee`。保存后重新启动 BAT 生效。工具会尝试启用控制台真彩色，不支持时使用接近的基础色；字标显示后恢复原来的控制台模式。

本机升级保留了旧目录中的数据：只要旁边存在 `steam-publisher/local-data`，新工具会继续使用它，不搬动正在运行的任务、预设、SteamCMD 登录缓存或历史包体。请保留这个数据目录；要携带现有数据到其他位置，将它复制为新工具下的 `local-data`。单独新装且没有旧目录时，使用 `steam-uploader/local-data`。

## 2. 配置

首次启动会创建配置。已有配置时，先选择一套，再选择：

1. **沿用**：直接使用保存的操作、导出文件夹和其他字段，不再重复选择操作或路径；每次单独询问 Description，直接回车不改。仍检查环境，并在构建、上传前确认。
2. **修改**：从带当前值的字段菜单选择要改的项，可以连续修改多项；选择“完成修改，继续”或直接回车结束，未选中的项保持原值。
3. **另建一套**：以当前配置为基础另存，适合正式版、Demo、Playtest 或其他项目。

字段输入时，回车或 `s` 表示保留原值、跳过该项，`-` 表示清空，`q` 表示退出。路径可粘贴，也可拖入输入位置；外围双引号会去掉。首次尚未设置的必填项仍需填写。损坏的配置会提示并跳过，不覆盖原文件。

旧预设首次使用时，只需补选操作和导出文件夹，原有账号、项目、编辑器和上传目标等字段会保留；保存后下次直接沿用。新建时按向导设置；“修改”“另建一套”使用字段菜单，只有选中“操作”时才会询问四种操作，默认选中已保存的值。

打开任何选择窗口前，终端先显示“正在选择：”及用途，窗口标题也显示对应字段。文件夹采用资源管理器样式窗口，支持地址栏、路径粘贴、搜索、侧栏导航和新建文件夹；ZIP、Unity.exe、steamcmd.exe 使用文件选择窗口。首次填写必填路径时自动打开窗口，已有路径时回车或 `s` 沿用、`b` 重新浏览。取消窗口后回到输入提示，可保留旧值或手动输入；窗口不可用时也可粘贴路径。

手动粘贴：在资源管理器选中 ZIP，按 `Shift + 右键 → 复制为路径`；切回终端按 `Ctrl+V`（不生效时用 `Ctrl+Shift+V`），再回车。输入的是 ZIP 文件的完整路径，带引号也可以；这里是路径输入提示，不需要在前面加 `&`。文件夹路径可从资源管理器地址栏复制。更新脚本后，需要输入 `q` 退出当前旧向导，再重新运行 BAT 才能使用新窗口。

| 字段 | 填写方式 |
|---|---|
| 配置名称 | 自己容易识别的名称，如“农场 Playtest Windows” |
| 操作 | 上传现成包体、构建并上传、仅构建、仅检查；保存在预设中 |
| 导出文件夹 | 选择或输入完整目录路径；选择窗口支持新建文件夹，每次在其下新建 `<时间>-<随机ID>/content` 保存包体 |
| 来源 | 游戏文件夹、ZIP 或 Unity 项目 |
| 主程序 | 相对包体根目录，如 `Game.exe`、`bin/Game.exe`；留空后选择 |
| Unity 项目 | 包含 `Assets`、`ProjectSettings` 的目录 |
| Unity 编辑器 | 自动寻找项目所需版本；找不到时指定对应 `Unity.exe` |
| 构建类型 | 普通构建或 Development Build |
| Steam 账号 | 登录账号，不是显示昵称 |
| SteamCMD | 留空使用工具内版本，也可指定已有程序 |
| AppID、DepotID | 从目标应用后台确认，不能猜测 DepotID |
| Description | 每次显示当前备注并询问；回车保留，输入新内容会保存到预设；不修改游戏内部版本 |
| 排除规则 | 分号分隔，支持 `/`、`*`、`**`、`?` |

一套配置对应一个 Depot。不同 App 或 Depot 建立不同配置。**上传 AppID 不会改变游戏代码、运行时 Steam 初始化逻辑、Demo/正式版或游戏版本号。**

不用手动维护 `app_build.vdf`。向导里逐项输入的包体路径、AppID、DepotID 和 Description 会保存到配置，每次运行自动生成本次 VDF；目标变化时选择“修改”或“另建一套”即可。

导出路径不会覆盖已有包体，各次运行使用独立子目录。不要把导出文件夹设在源包体或 Unity 的 `Assets`、`Packages`、`ProjectSettings` 内。仅检查 Unity 项目环境时不生成包体目录，导出设置仍保存在预设中。

## 3. 四种操作

### 上传现成包体

1. 选择“上传现成包体”，输入游戏文件夹或 ZIP。
2. 配置 Steam 账号、AppID、DepotID、Description。
3. 工具验证 Steam 登录，将包体复制或解压到本次独立目录，不改源文件。
4. 选择完整包体根目录、主程序，查看检查结果和排除项。
5. SteamPipe 预览通过后，选择“开始上传”。默认选择是取消。
6. 成功后得到 BuildID、ManifestID，并打开该应用的后台构建页面。

包体应包含游戏 EXE 和完整依赖，不能只选一个 EXE。ZIP 可以多套一层文件夹；出现多个候选目录时，选择包含完整依赖的包体根目录。

如果其他引擎把 EXE 放在 `bin` 内、资源放在同级 `assets`，应选择两者共同的上级根目录，主程序填写 `bin/Game.exe`。

本项目的现成包示例：

```text
来源：ZIP
源路径：D:\NodeDraw\Build\chubby-farm-0.5.5d-win-steam-playtest.zip
AppID：4839140
DepotID：4839141
Description：填写本次实际版本与说明
```

这是历史 Playtest 目标示例。上传新版本时选择新包；上传正式版或其他应用时使用对应 ID。

### 构建并上传

1. 输入 Unity 项目目录；本项目为 `D:\UnityProject\nodedraw\Project-Cyberloli`。
2. 工具读取 `ProjectSettings/ProjectVersion.txt`，寻找匹配编辑器；不会安装或升级 Unity。
3. 检查 Windows Standalone 模块、项目占用及 Steam 登录。
4. 确认开始构建，成功后执行包体检查、SteamPipe 预览与上传确认。

提前在 Unity 中保存场景和设置，并自行关闭该项目。工具不会控制 Play 模式、关闭现有编辑器或运行 Luban。

构建沿用项目脚本宏、脚本后端、游戏版本和游戏内容设置。只构建 Build Settings 中勾选的场景，没有启用场景时失败。Unity 6 的目标也必须提供可用的启用场景列表。

有 Addressables 配置时，调用其构建 API 生成资源，不主动清空缓存；临时关闭随 Player 再次构建的选项，结束时恢复。没有 Addressables 的项目无需安装它。自定义构建回调仍属于所选项目的行为；额外构建要求、IL2CPP 工具链和许可证问题需要在该项目中解决。

### 仅构建

生成包体并检查，不要求 SteamCMD、账号或上传 ID，不连接 Steam。结果位于本次运行目录的 `content`。

### 仅检查

- 对现成包体：验证环境、登录、本地包体，执行 SteamPipe 预览；不正式上传。
- 对 Unity 项目：检查项目、编辑器及 Steam 登录；不启动 Unity。没有包体，因此不会预览文件清单。
- 包体路径失效时，可重选或改选 Unity 项目；不会静默上传旧包。

## 4. SteamCMD 与登录

已有 SteamCMD 直接使用。找不到程序时，可以下载 Valve 官方版本，或指定已有程序。下载版本必须通过 Valve 数字签名验证。

旧 SteamCMD 迁移时包含原配置和账号缓存。**缓存是否有效，以本次实际登录为准。** 首次使用、换账号或缓存失效时，按原生提示输入密码、邮件验证码或 Steam Guard。

工具配置不保存密码、验证码，也不保存登录控制台全文。SteamCMD 自己管理账号缓存。分享工具代码时排除 `local-data`，避免把本机登录缓存一起分享。

登录失败、取消或断网会停止流程。重新启动后可选择原配置。若上次 SteamCMD 仍在运行，先处理或等待它结束；上传状态未确认时，先到后台核实，不要立即重复上传。

## 5. 检查与发布边界

本地检查：非空目录、可读文件、Windows EXE 的 PE 头、主程序路径和常见 Unity 文件。识别出 Unity 包时，检查同名 `_Data`、`UnityPlayer.dll`、数据文件及 Managed/GameAssembly 等基础文件。

ZIP 拒绝目录越界、绝对路径、重复文件、不合法的 Windows 名称和链接。源目录中的符号链接/Junction 也会被拒绝，避免意外带入其他目录。

默认排除：

- `steam_appid.txt`，包括子目录中的同名文件；
- 名称含 `DoNotShip` 或 `DontShip` 的 Unity 诊断目录；
- `.git`、`.svn` 版本控制目录。

排除发生在暂存时，源包体保持不变。可修改规则；完整结果见 `excluded-files.json`。VDF 只映射本次暂存目录，不会把配置、账号缓存或工具上传。

SteamPipe 预览检查文件映射及服务端返回。App/Depot 关联、账号权限和后台配置问题最终以 Steam 返回为准。**检查和预览不等于游戏能正常运行，也不等于通过 Steam 审核。**

仍需在后台配置正确的启动项、Depot 及软件包权限。上传成功后手动选择 beta 或默认分支生效；工具不写 `SetLive`。

## 6. 数据位置

配置、运行记录和缓存保存在 `local-data`，已被 `.gitignore` 排除；本机升级沿用旁边的 `steam-publisher/local-data`，新装使用工具自身的 `local-data`。可交付和上传的包体保存在预设指定的导出文件夹：

```text
local-data/
  profiles/                配置
  steamcmd/                SteamCMD 与账号缓存
  cache/<AppID>-<DepotID>/  可复用上传缓存
  runs/<时间>-<随机ID>/
    profile.json           本次配置
    result.json            最终状态、退出码与实际包体路径 ContentRoot
    raw-content/           Unity 原始产物（构建模式）
    unpacked/              原始解压内容（ZIP 模式）
    validation.json        数量、大小、SHA-256 清单
    excluded-files.json    排除项
    unity-build.log        构建日志（构建模式）
    unity-report.json      构建报告（构建模式）
    preview/               预览配置与日志
    upload/                正式上传配置与日志
    upload-receipt.json    仅在正式上传成功并确认 ID 后生成
  tests/                   离线测试夹具与结果

<预设中的导出文件夹>/
  <时间>-<随机ID>/
    content/               筛选后的完整包体，也是 SteamPipe 预览和上传的来源
```

历史运行和导出包体不自动删除，构建或 ZIP 暂存会额外占用空间。不再需要时，可在工具停止后分别删除对应 `runs` 子目录和导出子目录。`cache` 可以删除后重建，保留通常更快。判断成功应查看本次回执，而非旧日志。升级前已生成的包体仍在原有 `runs/.../content`，不会自动搬移。

整体迁移工具文件夹时，内置 SteamCMD 的相对位置仍有效；外部项目、源包体、自定义编辑器和导出文件夹仍使用保存的绝对路径，换设备或目录时需修改。

从旧工具迁移后，使用新的 BAT 入口，SteamCMD 字段留空即可使用 `local-data/steamcmd/steamcmd.exe`。旧账号缓存随 SteamCMD 保留，第一次仍需填写配置中的登录账号；工具不会从旧上传回执猜测本次目标或版本。迁移核验和清理结果记录在 `local-data/migration-cleanup-receipt.json`。

## 7. 常见问题

构建、SteamPipe 预览和上传期间会显示动态进度提示，包括当前阶段、已用时、进程 PID 和距最近输出的时间；每 15 秒另有一行状态，终端隐藏进度条时也能看到。Unity 日志从本次 `unity-build.log` 持续读取；Unity 没有可靠的总百分比，因此显示动态等待指示。SteamCMD 提供百分比时显示**当前阶段**的实际进度，进入服务器确认阶段后继续等待回执。进程存在或进度达到 100% 都不代表成功，最终仍以构建报告或上传回执为准。登录要求密码或验证码时会收起进度条，按原生提示输入即可。新提示需在本次操作结束后重新启动 BAT 生效。

| 提示 | 处理方式 |
|---|---|
| Unity 正在打开 | 自行保存关闭该项目，再重试 |
| 编辑器版本不匹配 | 在 Hub 安装精确版本，或选择正确的 Unity.exe |
| 模块、IL2CPP、许可证报错 | 补齐构建模块、编译工具链，并检查许可证 |
| 主程序或 Unity 文件缺失 | 选择完整包体，必要时重新构建 |
| AppID/DepotID 或权限失败 | 后台核对应用、Depot 与账号开发者权限 |
| Description 仍为上次内容 | 每次的 Description 提示中输入新内容；直接回车会保留原值，不会自动改变游戏版本 |
| 预览后包体发生变化 | 重新运行以生成新暂存目录 |
| 上传结果未确认 | 查看本次 upload 日志和后台构建页 |
| PowerShell 只显示路径 | 路径前加 `& ` |
| 两个窗口同时运行 | 同一数据目录有锁，等待另一实例结束，不要删锁文件抢锁 |

临时助手位于所选项目的 `Assets/SteamUploaderTemp_<随机ID>/Editor`，正常结束会清理。中断后再次运行可恢复清理，也兼容旧的 `SteamPublisherTemp_` 记录；仅处理有对应记录且未被修改的助手，未知内容会保留。

Unity 导入、Addressables 或项目构建回调可能产生项目生成文件；工具不批量回滚项目改动。强制关闭构建进程后，也应核对 Addressables 设置是否恢复。

## 8. 参数与验证

```powershell
# PS 入口不会在结束时暂停
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SteamUploader.ps1

# 指定操作/配置，操作会更新到预设，仍需交互核对
.\SteamUploader.bat -Mode CheckOnly -ProfileId "农场 Playtest Windows"
.\SteamUploader.bat -Mode BuildOnly

# 上传后只显示后台网址
.\SteamUploader.bat -NoBrowser

.\SteamUploader.bat -Help

# 离线测试，不连接 Steam，不启动真实 Unity
.\SteamUploader.bat -SelfTest
```

BAT 默认结束时暂停。设置 `STEAM_UPLOADER_NO_PAUSE=1` 可取消暂停。退出码：`0` 成功、`1` 失败、`2` 用户取消。

`-Mode` 支持 `Upload`、`BuildUpload`、`BuildOnly`、`CheckOnly`；不指定时沿用预设保存的操作。构建和正式上传的开始确认仍会保留。

离线测试使用自编译模拟程序，覆盖配置、ZIP、包体检查、路径、登录/验证码提示、构建/上传成败、回执、锁、助手清理及完整向导。不会运行真实 Unity、Luban，也不上传实际包体。真实 Unity 构建、Steam 登录和上传需要按本文手动验证。

参考：[SteamPipe 官方上传说明](https://partner.steamgames.com/doc/sdk/uploading?l=schinese)。
