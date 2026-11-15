# view-timer

macOS 菜单栏小工具：设一个时长，到点自动**停止 Mac 上正在播放的视频**并锁屏。

支持的播放源（v1.1 起为「统一停止」）：

| 播放源 | 停止方式 | 能否复核 |
|---|---|---|
| Edge / Chrome 等 Chromium 浏览器（网页视频） | 系统暂停（`MRMediaRemoteSendCommand(kMRPause)`）；勾选「关闭浏览器标签页」后到点再发 ⌘W | ❌ 见下方「浏览器通道的边界」 |
| 腾讯视频官网客户端（QQLive） | 激活到前台 + 空格 | ✅ 用 CoreAudio 音频信号 |
| QuickTime / 音乐等注册了 Now Playing 的 App | 系统暂停 | ❌ 同浏览器 |

## 构建与安装

```bash
./scripts/install.sh     # 构建 → 装进 /Applications → 清理重复注册与旧授权 → 启动
```

只要产物：`./build.sh`（输出 `build/view-timer.app`）。签名默认 `auto`：
有稳定证书身份就用证书签名，否则退回 ad-hoc。

**图标**：仓库只保留 `assets/icon.svg` 源文件，`AppIcon.icns` / `icon-1024.png`
是生成物、不入库（`build/` 同理）。克隆后首次构建时 `build.sh` 会自动调用
`scripts/make-icon.sh` 重新生成；该脚本依赖 `rsvg-convert`（`brew install librsvg`），
没装也不会中断构建，只是 App 不带图标。也可手动跑一次 `./scripts/make-icon.sh`。

菜单栏出现 `⏱ view-timer` 后点开即是设置面板。

### 辅助功能权限（必读）

首次使用（只需一次）：**系统设置 → 隐私与安全性 → 辅助功能 → 点「+」→ 选 `/Applications/view-timer.app`**。
列表里若已有旧的 `view-timer`，先用「−」删掉再添加。

**签名方式决定「重新编译后要不要重给权限」**（实测结论）：

| 签名方式 | TCC 的指定要求 | 能否加入辅助功能 | 重新编译后 |
|---|---|---|---|
| ad-hoc（兜底） | 二进制 cdhash | ✅ | ❌ 要删掉重加一次 |
| 自签证书 + 系统域信任 | identifier + 证书根 | ✅ | ✅ 不用动 |

证书方案能用起来只有一个前提：**证书根必须装进系统域**。做一次即可：

```bash
./scripts/setup-signing.sh
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain ~/.viewtimer-sign/cert.pem
./scripts/install.sh      # 自动检测到证书身份 → 用证书签名
```

**签名钥匙串密码不入库**：`build.sh` / `install.sh` 解锁 `vtsign.keychain-db` 时按
`VT_SIGNING_KC_PASS` 环境变量 → `~/.viewtimer-sign/keychain.pass`（权限 600）的顺序读取；
首次运行 `setup-signing.sh` 会自动生成随机密码写入该文件。仓库里没有明文口令，
clone 到新机器后各跑一次 `setup-signing.sh` 即可，互不依赖。

判定信任是否真生效（**必须退出码 0**）：

```bash
codesign --verify -R='anchor trusted' /Applications/view-timer.app
```

实测验证：改代码重编译后 cdhash 从 `de75f41…` 变成 `13db7e2…`，
指定要求仍是 `certificate root = H"3d2cd976…"`，启动日志依然「辅助功能权限正常」。

历史上踩过的两个坑（现已修复，别改回去）：

1. 证书声明 `CA:FALSE` 时，`add-trusted-cert -r trustRoot` 会**静默失效**——
   证书确实进了系统钥匙串，但签名链验不过。脚本已改为 `CA:TRUE + keyCertSign`；
   若手上是旧证书，用 `./scripts/setup-signing.sh --force` 重建。
2. 证书根只在**用户域**（或只挂在独立钥匙串）时，tccd 做签名链验证找不到可信锚点，
   表现就是「App 能拖进辅助功能列表，但勾选不生效 / 条目自己消失」。

`install.sh` 另外自动处理：注销同 bundle id 的重复 LaunchServices 注册、去掉
`com.apple.quarantine`、以及**仅在 ad-hoc 模式**下重置授权记录
（证书模式还去 reset 等于自断授权）。

## 图标

`assets/icon.svg` 是唯一源文件，`assets/AppIcon.icns` 由它生成（16–1024 全套，
`build.sh` 会自动拷进 `Contents/Resources/`）。

```bash
./scripts/make-icon.sh     # 改完 SVG 后重新生成 icns（需要 brew install librsvg）
```

设计：紫色渐变的 macOS squircle + 白色计时环（已走过的时间）+ 中央暂停符，
环尾的薄荷绿小圆点是「进度头」。缩到 16px 仍能看出「暂停 + 计时」。

⚠️ 写 SVG 时**不要用 `filter`**：librsvg（rsvg-convert）处理 `feDropShadow` 会把
整块图形渲染成空白/纯白，实测踩过。光影用带 `stop-opacity` 的渐变实现，正常。

## 使用

- **定时时长**：默认快捷值是 `5 / 10 / 15 / 20 / 30 / 60 / 90` 分钟，4 列网格排列。
- **编辑快捷值**：点「定时时长」标题右侧的**编辑**，用逗号分隔填写（如 `5,10,15,25,40`），
  1–600 分钟、最多 12 个、自动去重排序；**留空保存则恢复默认**。
- **临时自定义**：最后一格「自定义」可随时输入任意分钟数，不写进快捷列表。
- **停止策略**：「到点立即停止」按时间严格执行；「播完当前再停」等检测到播放停止（或到达上限）再执行。
- 到点前会弹全屏提醒，可「立即执行」或「再看 5 分钟」。
- **提醒提前量可调**：「全屏提醒」那一行右侧可改秒数（3–120，默认 **10** 秒），
  提醒窗口上会显示「N 秒后自动执行」并逐秒递减，最后 5 秒变橙；
  改完直接点「开始计时」也会生效（不必按回车）。

## 实测结论（macOS 15.8 + 腾讯视频 6.x，踩过的坑）

这些是写代码前必须知道的事实，决定了整个实现方式：

1. **MediaRemote：能写不能读**（2026-11 修正，旧记录「全废」是错的）。
   - **读**：`MRMediaRemoteGetNowPlayingInfo` 返回 null、`...GetNowPlayingApplicationPID` 返回 0，
     **连自己刚注册 `MPNowPlayingInfoCenter` 的进程都读不到**。macOS 15.4+ 的封锁坐实。
   - **写**：`MRMediaRemoteSendCommand(kMRPause)` **仍然有效**。旧记录说「返回 true 但什么都不做」，
     真实原因是**发完立刻退出进程**——它是异步 XPC，命令会静默丢失。
     实测对照：不转 runloop → 播放器收不到；转 1.5 秒 runloop → 准点收到并暂停。
   - **但它只投递给「已注册 Now Playing」的 App**，而腾讯视频**不注册**
     （播放中发 pause / toggle / play 均无反应，音频持续 16 秒无变化）。
     所以对腾讯视频无效、必须回退到「激活 + 空格」；对 Edge 等浏览器则**有效，v1.1 已接入**。
   - ⚠️ 发送后**必须让进程存活约 1 秒**（`usleep`）命令才会真正送出。
2. **播放状态只能读 CoreAudio**：`kAudioProcessPropertyIsRunningOutput`（`piro`）为 1 表示
   进程在向音频设备写数据。公开 API，免权限。

3. **这个信号有滞后，而且方向不对称**（关键）：
   | 状态变化 | 信号翻转耗时 |
   |---|---|
   | 播放 → 暂停 | **约 8 秒**（客户端先渐弱、再释放音频设备） |
   | 暂停 → 播放 | **约 1.5 秒** |

   ⇒ 「无输出」是可信的「确实已停」；「有输出」不能立刻断定在播，必须等够约 14 秒。

4. **空格键确实能暂停**，但前提是客户端真的到了前台。客户端常驻全屏 Space 时，
   切 Space 有动画，**按键太早会打偏**（这是最初误判「空格无效」的根因）。
   正确做法：`activate()` 后轮询 `NSWorkspace.shared.frontmostApplication`，
   确认切换完成再按键。

5. **CPU 占用不能当播放判据**：暂停状态下腾讯视频仍会吃掉约 60% CPU，与播放时（120%+）
   区间重叠，且随画面复杂度剧烈波动。

6. 腾讯视频是自绘 UI，**AX 树里没有播放/暂停控件**。曾有的 `pressPauseControl()` 已移除
   （永远返回 false；且按下后 8 秒内无法判定成败，贸然补发空格会把视频重新放起来）。

## 停止流程（Sources/StopExecutor.swift）

严格按「先确认停止、再锁屏」的顺序，且**绝不盲发 toggle**：

0. 先在日志里列出「当前发声进程」，让你看得出到底在停谁
1. **系统暂停**（无条件发，幂等）：覆盖浏览器 / QuickTime / 音乐等注册了 Now Playing 的 App，不抢焦点、不改窗口层级
2. 腾讯视频在播 → 激活并**确认到前台**（失败会重试一次）→ 空格 → 等音频释放（最长 14s）
3. 媒体键（仅在等满确认仍在出声时发；**保留它的唯一理由**是空格在焦点落到输入框时
   会变成「打一个空格」，而媒体键与键盘焦点无关）
4. **到点附加动作**（v1.2 起：勾了开关就执行，与 1~3 的成败、有没有音频信号、
   浏览器是不是前台全都无关，且所有分支都经过统一出口 `finishAll`，不会漏掉）：
   - **关闭腾讯视频（退出 App）**：枚举运行中的客户端实例 → `terminate()`，
     2 秒内没退掉再 `forceTerminate()`；**会丢播放进度**，日志与结果里会告警
   - **关闭浏览器标签页（⌘W）**：把运行中的已知浏览器逐个激活、**等确认到前台**再发 ⌘W；
     有音频信号的浏览器排在前面，但音频信号不作为执行门槛
5. 附加动作执行完复核一次停止状态 → 才锁屏；未确认则跳过锁屏并如实告知

> 曾经的「AX 直接按暂停控件」一级**已删除**：腾讯视频拿不到该控件，
> 且它无法安全判定成败（见上文第 6 条）。

### 浏览器通道的边界（重要，别承诺做不到的事）

Edge 的音频输出挂在 `Microsoft Edge Helper (Aperitif)` 这个 helper 进程上，
它的 `kAudioProcessPropertyIsRunningOutput` 标志**永久卡在 1**——
视频暂停了也不回落（实测连续 12 秒仍是 1）。

后果：
- **判断不了**浏览器是不是在播；
- **也验收不了**停没停。

所以浏览器侧只能「发出去就算完成」。好在 `pause` 是**幂等**的（不像空格/媒体键是 toggle），
发错没有副作用，这是唯一能这么干的原因。日志与结果里会标注「无法复核」。

#### 两个附加动作：勾选即执行，默认关闭

v1.1 时这两项叫「兜底」，条件苛刻：退出客户端要前面几级全失败才做；关标签还要求
「检测到浏览器在出声 + 它本来就是前台应用 + 绝不抢焦点」。结果就是**勾了开关、
到点却什么都没发生**。v1.2 改成「勾选即在倒计时结束时执行」，与播放状态彻底解耦。

| 开关 | 到点做什么 | 代价 |
|---|---|---|
| 关闭腾讯视频（退出 App） | 枚举并退出所有运行中的客户端实例 | 播放进度丢失 |
| 关闭浏览器标签页（⌘W） | 逐个激活运行中的已知浏览器 → 发 ⌘W | 焦点被抢；前台窗口的当前标签及其页面状态丢失 |

仍要如实说明的边界：

- 浏览器侧读不到播放状态，**无法复核** ⌘W 是否关掉了正在播的那个标签；
  若视频在后台标签，关掉的可能是别的标签。
- 只勾一个就只执行一个；两个都勾就都执行，顺序是「先关标签 → 再退出腾讯视频 → 锁屏」。
- **默认关闭**，因为都是不可逆手段；勾选即视为已同意上述代价。全屏提醒窗口会提前告知本次将执行哪些动作。
- 演练（走完整识别 / 激活链路但不真关、不真退）：`VT_CLOSETAB=drill`、`VT_QUITCLIENT=drill`。

### 「播完当前再停」的精度

触发时刻 = 真正播完 + 音频设备释放（约 8 秒）+ 静默阈值（2.5 秒），
即**本集结束后约 10~11 秒**才执行暂停与锁屏。客户端不暴露播放进度，做不到更准。

⚠️ **客户端开了「自动连播」时该模式会失效**：下一集 1~3 秒内接上，音频信号根本不会掉到 0，
只能靠「最长等待上限」兜底。此时请改用「到点立即停止」，或在客户端里关掉自动连播。

⚠️ 该模式依赖腾讯视频的音频信号，**对浏览器渠道无效**（Aperitif 标志不会回落）。

## 开发用环境变量

| 变量 | 作用 |
|---|---|
| `VT_SELFTEST=1` | 跑状态机 + 停止执行器全链路（不锁屏） |
| `VT_TEST_TOGGLE=1` | 验证「激活 + 空格」是否真的暂停，打印音频/CPU |
| `VT_SNAPSHOT=/path.png` | 把面板渲染成 PNG（配合 `VT_SNAPSHOT_STATE` / `_STRATEGY` / `_APPEARANCE`） |
| `VT_SNAPSHOT_OVERLAY=/path.png` | 渲染全屏提醒窗口 |
| `VT_AXDUMP=1` | 打印客户端 AX 控件树 |
| `VT_OPEN_PANEL=1` | 启动后自动弹出面板，便于截图核对 |
| `VT_AUTOWARN=snooze\|proceed\|timeout` | 自动跑「进入提醒 → 点按钮 / 到点执行」全流程，用于排查提醒窗口相关的崩溃 |
| `VT_NOSTOP=1` | 配合 `VT_AUTOWARN`，只走状态流转，不真的暂停视频/锁屏 |

### 已修的坑：点提醒窗口按钮后 App 直接退出

**现象**：提前 20 秒的提醒窗口弹出后，点「立即执行」或「再看 5 分钟」App 立刻消失，
动作也不生效。

**根因**：`NSWindow` 默认 `isReleasedWhenClosed = true`，`close()` 会额外给窗口发一次
`release`；而 Swift 侧（AppDelegate 的 `warningWindow`）还持有强引用，回调里再置 `nil`
就是**过度释放**，崩在 `objc_release`。

崩溃报告堆栈（三份完全一致）：

```
EXC_BAD_ACCESS (KERN_INVALID_ADDRESS at 0x20)
objc_release
AutoreleasePoolPage::releaseUntil
objc_autoreleasePoolPop
_CFRunLoopPerCalloutARPEnd   ← 处理点击事件那一轮 runloop 结束时
```

`NSZombieEnabled=YES` 直接点出对象：

```
*** -[main.WarningWindow release]: message sent to deallocated instance 0x7fa01d9e6b90
```

**修法**：
- `WarningWindow` 里显式 `isReleasedWhenClosed = false`，生命周期完全交给 ARC
- 关闭统一走 `orderOut(nil)`，**不再调用 `close()`**
- `dismiss(using:)` 先解绑回调、再隐藏、最后执行动作，并带重入保护

上面 `VT_AUTOWARN` 的三条路径（延后 / 立即执行 / 到点执行）均已验证不再崩溃。
