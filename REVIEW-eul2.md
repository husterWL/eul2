# eul2 代码评审与优化建议

评审日期:2026-11-17
评审范围:相对上游 gao-sun/eul 的全部改动(约 315 个文件、+14.6k 行),重点覆盖 Store 刷新链路、SwiftUI/AppKit UI 层、IOKit/SMC/进程工具层、FanHelper 特权守护进程、自动更新链。
方法:四路独立审查(SMC/风扇专项 + Store 层 + UI 层 + 系统层),所有高严重度结论均经源码二次核实,行号以当前 HEAD(c047e4d)为准。

---

## 总体评价

这份 fork 的质量**明显高于上游开源 eul**,很多"教科书式"的优化已经做对了:

- **常驻能耗路径扎实**:nettop / system_profiler 严格限制在"面板打开且对应 lens 选中"时运行;widget 写入有安装检测 + 节流;慢变量(启动卷容量、磁盘满、蓝牙、应用目录测量)都有缓存;刷新链用带 tolerance 的一次性 Timer 链 + generation 计数防睡眠唤醒后定时器叠加。
- **状态栏架构正确**:没有走"每秒重绘 NSImage / 整棵重建 hosting"的歧路;hosting 树常驻、叶子视图各订阅各的 store;隐藏 worst-case 文本预留宽度消除数字抖动;宽度治理器对锁屏/全屏/刘海屏的 occlusion 误报有成体系防御。
- **FanHelper 是亮点**:XPC 内核级签名校验(避免了 Stats 的 GHSA-qwhf-px96-7f6v 类 LPE)、Double 空间 clamp 防 NaN trap、启动即 revert、连接失效 / SIGTERM / 45s dead-man 三重兜底、SMAppService 按需注册、"拒绝即非事件"的授权仪式。安全设计成熟。
- **macOS 26/27 适配思路正确**:没有硬编码版本号判断,电池用 key 探测 + 嵌套字典深度遍历,温度用 IOHID 能力探测,私有 API 全部 dlsym + 优雅降级,公证不受影响。
- IOKit 资源管理(iterator/entry/CF 配对)基本无可挑剔。

**剩余问题集中在四处**:① 更新链的安全缺口;② 主线程仍是所有常驻采样的执行线程;③ 面板打开路径的 SwiftUI 粒度与功能缺陷;④ 差值类指标缺少"基线归属"与回绕处理。下面按优先级列出。

---

## P0 — 安全与正确性,建议尽快修复

### 1. 自动更新链全程无代码签名校验,下载即替换安装
- 位置:`eul/Utilities/AutoUpdate.swift:68-96`(下载)、`SelfUpdate/AppDelegate.swift:52-60`(替换)
- 问题:
  - `downloadTask` 回调完全忽略 `response`——404/限流页也会被存成 zip;
  - 从下载到安装没有任何 `SecStaticCode` 签名/公证/Team ID 校验;
  - SelfUpdate **先删旧 bundle 再拷新 bundle**,拷贝失败(磁盘满/权限/quarantine)用户直接失去应用,且 `defer { quit() }` 让失败也静默退出;
  - `CommandLine.arguments[1...3]` 无边界检查,独立双击 SelfUpdate.app 即越界崩溃。
- 风险:GitHub 账号/release 资产被投毒(或同用户进程 TOCTOU 替换临时目录内容)即获得用户级持久代码执行——这是常驻监控 App 最典型的供应链攻击面。FanHelper 侧已经做了内核级签名校验,更新链反而没有,标准不一致。
- 建议:安装前强制校验,失败即中止:
  ```swift
  var code: SecStaticCode?
  SecStaticCodeCreateWithPath(newAppUrl as CFURL, [], &code)
  let req = "anchor apple generic and identifier \"com.gaosun.eul\" and certificate leaf[subject.OU] = \"<TEAMID>\""
  guard SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req as CFString) == errSecSuccess else { return }
  ```
  同时:检查 `(response as? HTTPURLResponse)?.statusCode == 200`;先拷到同卷 staging 路径、校验成功后 `replaceItemAt` 原子交换;`guard CommandLine.arguments.count >= 4`。

### 2. Shell 子进程失败路径不完整:永久挂起 + stderr 死锁 + 无超时
- 位置:`eul/Utilities/Shell.swift:16、21、29-37`
- 问题(三条叠加):
  - `try task.run()` 抛错时只 print 然后继续走 `readDataToEndOfFile()`。spawn 失败时管道写端仍由父进程持有,永远等不到 EOF,**调用线程无限阻塞**。`NetworkTopStore` 在专用串行队列上跑,一旦挂起后续所有 nettop 采样积压,网络进程列表永久冻结直到重启 App——而系统高负载(fork 返回 EAGAIN)恰恰是监控 App 最需要工作的时刻;
  - stderr 管道挂上了但**从不读取**:子进程 stderr 写满 pipe buffer(~64KB)后阻塞在 write,stdout 永不 EOF → 经典双向死锁。`system_profiler` 在异常机器上可以非常啰嗦;
  - `waitUntilExit()` 无超时,子进程自身挂死同样永久阻塞。
- 建议:
  ```swift
  do { try task.run() } catch {
      print("⚠️ shell executed with error", error)
      return nil   // 必须直接返回
  }
  ```
  stderr 改 `FileHandle.nullDevice`(现有调用方都不需要 stderr);用 `terminationHandler` + `DispatchSemaphore.wait(timeout: .now() + 10)` 实现超时,超时 `task.terminate()`。顺带可去掉 `bash -c` 包装直接指定 executableURL(现有调用都不需要 shell 特性,`2>/dev/null` 用 nullDevice 替代),少一次 fork+exec,也消除 `AutoUpdate.unzip` 的路径拼接注入易感模式(`AutoUpdate.swift:110`)。

### 3. 网络速率在接口切换时产生 GB/s 级假尖峰
- 位置:`eul/Store/NetworkStore.swift:75-91`
- 问题:速率差值始终用"上一次回调的累计字节"对比"本次",但**没有记录上次采样对应哪个接口**。auto 模式下 Wi-Fi ↔ 以太网切换、插拔 Thunderbolt 网卡、或用户手动改 `networkPortSelection` 后,新接口的累计计数器与旧接口直接相减:新接口计数更大时 delta 等于其**开机以来全部累计流量**,除以 3s 得到 GB/s 级假尖峰;更小时被回绕保护吞成 0。错误数字还会写入 widget 容器和 HealthStore 的 networkHistory。第 76 行注释只处理了"同接口计数器重置"(#226),没覆盖"换了接口"。
- 建议:记录 `lastDevice: String?`,接口(含手动选择值)变化时只更新基线、本拍速率置 0:
  ```swift
  let device = currentActivePort?.device
  if device != lastDevice { lastDevice = device; inSpeedInByte = 0; outSpeedInByte = 0 }
  else { /* 现有差值逻辑 */ }
  ```

### 4. Clean Mode 的主动 event tap 与权限模型错配
- 位置:`eul/Utilities/KeyboardLock.swift:32-40、44、80-89`;`eul/Store/CleanModeManager.swift:137-142`
- 问题:tap 用 `.defaultTap`(主动过滤器,返回 nil 吞事件),按 Quartz Event Services 权限模型需要**辅助功能(Accessibility)**;但 `hasPermission()` 只检查 `CGPreflightListenEventAccess()`(Input Monitoring,只覆盖 listen-only tap),引导也只打开 `Privacy_ListenEvent` 面板。全工程没有任何 `AXIsProcessTrusted` 调用。若目标系统要求 Accessibility,会形成死循环:preflight 通过 → tapCreate 被拒 → 再引导授权 → 永远进不了 Clean Mode。代码注释自己也承认存在 "preflight passed but the tap was refused" 路径。
- 建议:`hasPermission()` 增加 `AXIsProcessTrusted()`;用 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` 触发授权;设置面板 URL 改 `Privacy_Accessibility`;引导文案说明两种权限。**具体 TCC 行为请在 macOS 26/27 真机验证后再定稿**。
- 另:`unlock()`(107-116)建议显式 `CFMachPortInvalidate(tap)`,不依赖 ARC 释放时的隐式失效。

### 5. FanHelper `setFanAuto` 不校验 fan id,可打崩 root 守护进程
- 位置:`FanHelper/main.swift:76-87`;`eul/Utilities/SMC.swift:118、840`
- 问题:`setFanForced` 认真做了 id 范围与 NaN/Inf 校验(注释明确 "never trust the client"),但 `setFanAuto` 直接把 id 拼进 `"F\(id)Md"`:id ≥ 10 或负数 → 字符串 ≠ 4 字符 → `FourCharCode(fromString:)` 的 precondition 让 **root daemon 崩溃**;Intel 路径 id ≥ 16 时 `UInt16(1 << id)` 同样 trap。虽然 XPC 客户端已被签名要求限定,eul 侧一个普通 bug 即可打崩 root helper,违反该文件自己声明的信任边界不变量。
- 建议:把 `setFanForced` 的 fanCount 范围校验提取为公共前置检查,`setFanAuto` 同样执行;`fanSetAuto` 内对 id 做 `0..<16` 防御。

---

## P1 — 真实可触发的功能缺陷

### 6. 面板高度无上限、无滚动,矮屏幕上内容不可达
- 位置:`eul/Views/Panel/PanelView.swift:866-867`;`eul/StatusBar/StatusBarPanel.swift:194-206、222`
- 问题:`.frame(width: 360).fixedSize()` 高度完全由内容决定;多个 tile 可同时展开(各自独立 @State),展开 tile 独占整行。3 个展开 tile + 紧凑行 + 进程区 + 头尾,总高轻松超过 1200pt;`handleContentSize` 无条件采用内容高度,定位 `y = barFrame.minY - height - 5` 不钳制到屏幕可见区。1080p 及更矮屏幕上连点几个 tile 就会让面板底部伸出屏幕外,且无法滚动。
- 建议:内容限高 + ScrollView,定位钳制下边界:
  ```swift
  ScrollView { VStack { ... } }
      .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 60)
  // StatusBarPanel.position:
  let y = max(barFrame.minY - height - 5, visible.minY + 8)
  ```

### 7. 每次启动覆盖用户拖拽保存的状态栏位置
- 位置:`eul/StatusBar/StatusBarItem.swift:146`
- 问题:init 无条件写入 `greatestFiniteMagnitude` 到 `NSStatusItem Preferred Position`,把 AppKit 持久化的用户拖拽位置抹掉——每次重启图标跳回最左。与 205-206 行"保留 legacy autosaveName 让老用户位置 survives upgrade"的注释直接矛盾。
- 建议:仅在无已保存值时写入:
  ```swift
  let key = "NSStatusItem Preferred Position \(autosaveName)"
  if UserDefaults.standard.object(forKey: key) == nil {
      UserDefaults.standard.set(Self.leadingPosition, forKey: key)
  }
  ```
  (若"固定最左"是有意设计,请删掉误导注释并去掉 stash 机制。)

### 8. ForEach 用数组下标做身份:进程展开详情跳变、tile 状态串位
- 位置:`eul/Views/Panel/PanelView.swift:752、818`;`eul/Views/Panel/PanelTiles.swift:212`
- 问题:进程区 `ForEach(0..<rows.count, id: \.self)`,而 `PanelProcessRow` 带 `@State expanded`。TopStore 每 tick 按使用率重排,行内容换进程但身份不变 → 用户展开的 PID/路径详情停留在行号上,下一秒显示的是另一个进程。tileGrid 同理:隐藏/展开导致行移位时,行内 RollingValue/SegmentBar 等 @State 按位置保留,短暂串到别的 tile。
- 建议:进程行按 pid 标识(`ForEach(procs, id: \.pid)`);tile 行用首个 tile 的 kind 做稳定 id。

### 9. CPU per-core ticks 差值未处理 Int32 回绕,也未钳位
- 位置:`eul/Store/CpuStore.swift:118-140`
- 问题:`host_processor_info` 返回 `integer_t`(Int32),转 64 位后做差。idle 计数约 248 天溢出回绕为负,回绕后 busy/total 出现巨大负值,使用率可为负或 >100,全程无 clamp。常年不重启的 Mac 必然触发。
- 建议:UInt32 wrapping 差值再转 Int,并钳位:
  ```swift
  let dUser = Int(UInt32(bitPattern: Int32(user)) &- UInt32(bitPattern: Int32(previous[0])))
  usages.append(min(100, max(0, total > 0 ? Double(busy)/Double(total)*100 : 0)))
  ```

### 10. MemoryStore:分母口径偏小 + 首拍前 NaN
- 位置:`eul/Store/MemoryStore.swift:30-40、78-80`
- 问题:(a)`total = free+inactive+active+wired+compressed` 是 vm 类别求和而非 `hw.memsize`,speculative 等页未计入,使用率系统性偏高且分母随采样抖动;(b)init 不做首次 refresh,首个通知到来前(默认约 3s)`usedPercentage = 0/0 = NaN`——HealthStore 已自行打补丁承认这个 NaN,但 MemoryStore 自身的 `usedPercentageString` 无防护。
- 建议:分母改物理内存(TopStore.swift:30 已用 `System.physicalMemory()`);`total > 0` 守卫;init 末尾补一次 refresh()(BatteryStore/HealthStore 都这么做)。

### 11. nettop CSV 解析:空输出崩溃 + 列错位
- 位置:`eul/Store/NetworkTopStore.swift:72-99、126-127`
- 问题:(a)`rows[0]` 无空数组守卫,nettop 退出码 0 但 stdout 为空时越界崩溃(`2>/dev/null` 把错误线索也吞了);(b)表头 split 用 `omittingEmptySubsequences: false`,数据行却用默认 true——任何空字段使后续列左移,取到错误列;进程名含逗号同样错位;(c)`timeElapsed` 除法无 >0 守卫。
- 建议:`guard let header = rows.first else { return }`;数据行同样 `omittingEmptySubsequences: false`;除法加守卫。
- 同文件小项:pid 基线字典只增不减(死进程条目累积 + pid 复用错差值),每拍按当前 pid 集合重建;进程名按 "." 切首段把 `com.apple.WebKit.WebContent.12345` 截成 "com",应 `dropLast().joined(separator: ".")`;Combine sink 缺 `removeDuplicates()` 且强捕获 self(TopStore 同构代码两者都有)。

### 12. 状态栏 item 可见性切换后 hosting view 重挂顺序风险
- 位置:`eul/StatusBar/StatusBarManager.swift:256-260、266-269、374-386`;`eul/StatusBar/StatusBarItem.swift:188-192、244-248`
- 问题:代码自身注释断言"AppKit 在 isVisible off/on 切换时重建 button",render() 也专门写了重挂逻辑;但 `renderBar()` 是**先 render 后 show**,anchor 分支 show 之后完全没有 render,`dropSlot` 先 hide 再 async show 之后也没有 render。若 button 确实在 show 时重建,hosting view 留在旧 button 上:strip 空白直到下一次 renderBar(最坏等 60s reprobe),anchor 空白直到 health level 变化(健康机器上可能永远不变)。
- 建议:show 之后补一次重挂;或把重挂统一收进 `BaseStatusItem.setVisible(true)` 末尾。修复零成本,建议优先。

---

## P2 — 性能优化(常驻开销与面板打开开销)

### 13. 把四个常驻重活从主线程移出去
当前 SMC 读取 → 通知 → 各 store refresh 全链路同步跑在主线程。TopStore 已经示范了正确模式(专用 sampleQueue 采样、主线程只发布),照搬即可:

| 重活 | 位置 | 说明 |
|---|---|---|
| 电池注册表全量 dump | `BatteryStore.swift:62-78` → `IOHelper.swift:97-112` | 每 3s 对 AppleSmartBattery 每个 entry 调 `IORegistryEntryCreateCFProperties` 并深度递归收集所有整数字段,macOS 27 上 pack/bank/cell 都带完整嵌套 payload。designCapacity/cycleCount 分钟级才变,却按秒级采集,且无组件/面板门控,台式机也照跑。建议硬件部分加 30-60s 缓存(仿 HealthStore.rawDiskFullCached),IOPS 电量/充电状态保留每拍 |
| GPU 注册表全量读 | `GpuStore.swift:90` → `GPU.swift:64-91` | 全量读的取舍本身合理(单键会拿到过期快照),但每 3s 在主线程执行。挪后台队列采样 |
| 磁盘 statfs | `DiskStore.swift:210-240` | 每拍主线程对每个挂载卷 statfs;**SMB/AFP/NFS 失联时可阻塞数秒**,直接卡死主线程。挪后台 + 对 list 做 Equatable 比较后再赋值(现在每拍无条件重建触发全量 UI 失效);或改 NSWorkspace 挂载/卸载通知事件驱动 + 低频兜底 |
| 健康引擎进程遍历 | `HealthStore.swift:299-349` | runaway 检测每 15s 在主线程做全量 libproc 遍历(数百进程 × 2 次 syscall),面板关闭也跑。挪专用串行队列,结果回主线程喂 tracker |

### 14. GpuStore 初始化同步 fork system_profiler,启动卡顿 1-5s
- 位置:`eul/Store/GpuStore.swift:70` → `GPU.swift:33-54`
- `SharedStore.gpu` 懒加载单例首次访问在启动阶段主线程,`system_profiler SPDisplaysDataType` 典型 0.5-2s+,叠加 Shell 无超时问题更糟。GPU 型号是 immutable 硬件事实:先置空、后台取回再赋值(BluetoothStore.swift:21-37 已有正确范式);Apple Silicon 上可改 IOKit 直接读 accelerator model,彻底免 fork。

### 15. PanelView 单体 body + 14 个 EnvironmentObject:任一 store 发布即全量重算
- 位置:`eul/Views/Panel/PanelView.swift:43-56、857-885`
- `@EnvironmentObject` 订阅 objectWillChange,与 body 实际读哪个属性无关。HealthStore 每 tick 改写 4 个历史数组、Cpu/Memory/Fan 每 tick 发布 → 面板打开期间每个 tick 整个 PanelView body 重算:8 个 tile 闭包、AnyView 数组重排、进程区格式化、蓝牙 filter、historyMax 全部重跑。与 StatSlotView 精心设计的叶子订阅粒度形成鲜明反差。
- 建议:每个 tile 拆独立 View 结构体、只声明自己用到的 store(照抄 StatSlotView 模式);进程区拆子视图;慢变 tile(Disk/Battery/Bluetooth)加 Equatable + `.equatable()`。这与 886 行文件的拆分(见 P3)一举两得。

### 16. HealthStore 历史数组每 tick 发布 4 次,击穿叶子订阅粒度
- 位置:`eul/Store/HealthStore.swift:165-169、425-440`
- 4 个 @Published 数组每 tick append + removeFirst(O(n) 前移),各发一次 objectWillChange → 所有观察 healthStore 的视图每 tick 失效 4 次,包括常驻栏槽位和打开的设置窗口。AnchorStatusItem 用 `$level.sink` 是正确做法,反衬视图侧问题。
- 建议:历史改非发布存储(普通 var / 环形缓冲),仅 widget 写入/面板读取时按需暴露;或拆独立 HistoryStore 供 Sparkline 观察;或合并为单个 @Published struct 一次性赋值。
- 相关:HealthStore 与 TopStore 只是共享了 `processSamples()` 函数,并非共享一次采样(HealthStore.swift:345-349 注释 "a single libproc walk" 不实)。面板打开时两者各自遍历。建议 IOHelper 层做带时间戳的共享采样器(1s 内复用),或 TopStore 采样时顺带喂 runaway 检测器;至少修正注释。

### 17. SMC 读取:温度小数丢失 + 类型回退导致每次双倍读取(专项补充)
- 位置:`eul/Utilities/SMC.swift:106-112、605-628、700-718`
- (a)`Double(fromSP78:)` 忽略第二个字节(FIXME 遗留):温度被截断为整数 °C,0.5° 的精度白白丢掉。修复:
  ```swift
  self = sign * (Double(bytes.0 & 0x7F) + Double(bytes.1) / 256.0)
  ```
- (b)`temperature()` 与 `decodeData()` 都是"先按 SP78/FPE2 读 → 捕获 SMCResult 135 → 再按 FLT 读"。Apple Silicon 上键几乎全是 flt,意味着**每个传感器每拍两次 SMC 往返**。键类型是 immutable 的:首次用 `keyInformation()` 查询后缓存 `FourCharCode → DataType`,之后直接按真实类型读,常驻 SMC 调用量近乎减半。
- (c)`SMCKit.connection` 是无锁静态 var:当前消费方都在主线程所以没事,但这是脆弱约定(与 AppleSiliconSensors 同类问题)。建议加 `dispatchPrecondition(condition: .onQueue(.main))` 或串行队列保护;`open()` 重复调用会泄漏旧连接,`close()` 后不置 0(终止流程中残余 refresh 会对已关闭 port 调用)。

### 18. WidgetReloader 15s 节流仍远超 WidgetKit 刷新预算
- 位置:`eul/Utilities/WidgetReloader.swift:20、56-58、77-81`
- 相比旧版已是巨大改进,但已安装 kind 仍可达 ~5760 次/天 reloadTimelines。系统每日预算(经验量级几十~几百次)超限后请求被静默忽略:白白唤醒 widget 扩展进程,耗尽预算后 widget 反而长时间不更新。且 `shouldWrite` 对已安装 kind 每 tick 返回 true,容器编码 + cfprefsd 写入仍是每 tick 一次。
- 建议:minimumReloadInterval 提到 60s+(或数值变化显著才 reload);容器写入与 reload 对齐节流,未变化时跳过编码。

### 19. Sparkline:200 点亚像素过采样 + 双 Shape 逐帧数组插值
- 位置:`eul/Components/Sparkline.swift:54-60、86-92、138-151`
- sparkline 宽约 150pt,200 点过采样;fill + stroke 两个 Shape 各自以 AnimatableVector 做 animatableData,每个动画帧执行数组 +/- (每次分配新数组)并重建 200 点 Path。CPU+Network 两条图 × 每 tick 0.3s spring ≈ 每 tick 数十次全量路径重建。
- 建议:按宽度降采样到 ~60-75 点;或改 Canvas 单绘制(放弃逐点 morph,用整体左移动画)。

### 20. CpuStore 每拍对同一份数据做两次内核读取
- 位置:`eul/Store/CpuStore.swift:83-88`
- `Info.system.usageCPU()`(SystemKit 聚合)与 `computePerCoreUsage()`(host_processor_info)每拍各走一次内核,且两套基线可能短暂不一致。只保留 host_processor_info,聚合值用各核 busy/total 差值汇总,口径还完全一致。
- 同文件小项:coreLabels 只依赖核数(immutable)却每拍重建并重新发布(CpuStore.swift:114、125-130、144),init 算好存 let 即可。

### 21. 面板 Timer 间隔固化,设置变更不生效
- 位置:`eul/Store/TopStore.swift:44-46、129`;`eul/Store/NetworkTopStore.swift:55-57、165`
- 主刷新链每拍重读偏好、改刷新率立即生效;这两个面板 Timer 的 interval 只在创建时读一次,面板开着时改设置必须关开一次才生效。订阅 `$smcRefreshRate/$networkRefreshRate`(removeDuplicates)变化时重建,或改用与 AppDelegate 相同的一次性 Timer 链。
- 根因之一:非 View 类里用 `@ObservedObject`(TopStore.swift:40、NetworkTopStore.swift:52、DiskStore.swift:17、GpuStore.swift:16、AppDelegate.swift:32、StatusBarManager.swift:23-24)——它只在 SwiftUI View 的动态属性机制里生效,放在普通类里无任何观察效果,容易误导维护者以为存在响应式联动。改 `let` + 显式订阅。

### 22. 风扇控制路径的几处打磨(专项补充)
- **helper 每次写入重读硬件参数**:`FanHelper/main.swift:45-58` 每次 setFanForced 都读 fanCount/min/max(4+ 次 SMC 往返)。这些是静态硬件值,缓存一次即可(App 侧滑杆只在松手时发送,这点做得对)。
- **App 侧回滚竞态**:`FanControlStore.swift:339-368` setTarget 的 rollback 捕获 previous;快速连续两次调节时,前一次失败的迟到回滚会覆盖后一次的新值。加 per-fan _generation 序号,回滚前比对。
- **removeHelper 主线程阻塞**:`FanControlStore.swift:251-256` 信号量同步等 XPC 最多 0.5s,由 UI 按钮直接触发 → 点击卡半秒。改异步 + 超时续体(退出路径 revertAllOnQuit 的同步等待可接受)。
- **对账只删不补**:`FanControlStore.swift:423-434` ping 对账只删除本地 stale 项;helper 多出的 override(部分写入失败:模式已置、target 失败)要等 App 停止 ping 后 45s watchdog 兜底。建议对 `helperSet - localKeys` 主动 setFanAuto。
- **watchdog 用墙钟**:`FanHelper/main.swift:24、207` 用 Date() 计心跳间隔,睡眠唤醒后必然 >45s → 风扇回 auto。这是安全方向的行为,但建议在注释中写明"唤醒即回 auto 是有意设计",或改用连续时钟 + 唤醒通知显式处理,避免未来维护者误判。
- **SMC 连接失效无重开**:ensureSMC 只 open 一次,驱动重置后所有调用持续失败直到 daemon 重启。可在特定错误码时重置 smcOpened。

---

## P3 — 健壮性与可维护性

### 死代码与埋雷
- `eul/Views/Chart/LineChart.swift`:全仓库仅 Preview 引用,却为它链接 **SpriteKit**;body 里 closedPath 与 path 各跑一遍 SKKeyframeSequence spline 采样。建议删除(连同 SpriteKit 依赖),需要曲线时复用 Sparkline/Canvas。
- `eul/Components/Sparkline.swift:13-24`:HistoryBuffer(上限 300)无人使用,注释"10 minutes/capped"与实际 200 点不符。删除或让 HealthStore 真正复用。
- `eul/Store/CleanModeManager.swift:107-118`:startPermissionPolling 定义后无调用。删除,或在 confirming 且缺权限时真正启用。
- `eul/Utilities/SmcControl.swift:156-157`:**确凿 copy-paste bug**——`Fan(json:)` 的 minSpeed/maxSpeed 都读 `json["id"]`。目前是死代码,一旦启用风扇布局持久化即读出 min=max=id。修正或删除。
- `eul/Utilities/Info.swift:29-34`:isBigSur 在部署目标 12.0 下恒真,死分支可清理。
- `eul/Schema/DesignTokens.swift:57`:slotLabel 无引用(槽位已改图标)。

### 健壮性小项
- `AppleSiliconSensors.swift:85-89、98-102`:init 失败路径泄漏已创建的 IOHID client(Copy 规则 +1 存裸指针,ARC 不管);无 deinit。失败路径 `Unmanaged.fromOpaque(client).release()`。另:cachedServices 永不重建,睡眠/唤醒后 HID service 失效则温度一直缺失直到重启——监听 `NSWorkspace.didWakeNotification` 重新枚举;入口加 dispatchPrecondition 固化主线程约定。
- `IOHelper.swift:102-104`:多个 AppleSmartBattery entry 以 first-wins 合并,NSDictionary 遍历顺序未定义 → 同名 key 取值跨采样不稳定。对同一 key 显式定义聚合策略(max/sum/顶层优先)。
- `HorizontalOrganizingView.swift:82-101、175`:拖拽排序每手势 tick 无冷却 swapAt,交换后捕获的 offset/frames 已过期 → 抖动/乱序;`frames[offset]` 无边界检查可越界崩溃。交换后按 element 重求 index + 冷却 + indices 保护。另 52-61 行 onHover 手动 NSCursor push/pop 在视图被移除时失衡,改用项目已有的 `.pointingHandCursor()`。
- `CleanModeManager.swift:167、187`:hold/countdown 定时器未加 `.common` 模式——AppDelegate 刷新链特意用了 .common 并注释原因,这里不一致;tracking 模式下按住退出环可能停摆(60s 超时仍兜底)。
- `CleanModeOverlay.swift:104、269、290`:每屏 overlay 观察完整 manager,hold 期间 60Hz 发布让只画黑布的副屏每帧重算;副屏只需 acceptsHold。全黑阶段 `isOpaque = false` 画纯黑徒增合成开销,可设 true。
- `GlobalHotKey.swift:29-47`:InstallEventHandler/RegisterEventHotKey 返回值被忽略,⌃⌥E 被占用时正式用户无任何提示(Print 仅 --debug 输出)。检查 OSStatus,失败走用户可见提示/允许改键。
- `DisplayBrightness.swift:104`:ramp Timer 依赖调用线程 runloop,显式 `RunLoop.main.add(timer, forMode: .common)`。
- `AppDelegate.swift:75-82`:睡眠/唤醒观察者 queue: nil,显式 `.main` 更稳妥。
- `AppDelegate.swift:208-213、222-227`:刷新间隔从 UserDefaults 原样读入,被写成 0/负数时一次性 Timer 链变主线程紧循环。`max(1, value)` 钳位。
- `PreferenceStore.swift:167-183`:checkUpdate 网络失败时不置 checkUpdateFailed,UI 无法区分"已是最新"与"检查失败"。
- `BluetoothStore.swift:29-35、58`:失败返回 [] 也清空 devices 并缓存 60s(一次偶发失败 → 一分钟空窗),失败应保留旧数据;`.userInitiated` QoS 跑 2s 的 system_profiler 建议 `.utility`;`props as? [String: String]` 要求所有值均为字符串,混入任何非字符串即整台设备被丢弃,逐键取值更稳。
- `NetworkStore.swift:47-63`:看门狗针对的是旧 shell 管道挂死(#263),现实现纯 sysctl/getifaddrs 回调必然到达,基本是死代码;保留无害,建议注明仅防御未来实现回退。
- `ComponentsStore.swift:86`、`PreferenceStore.swift:197`:启动时 print 完整偏好 JSON,删除或包 `#if DEBUG`。
- `TopStore.swift:25` vs `PanelView.swift:786`:rowCount = 5 但面板 prefix(6) 永远取不满,统一共享常量。

### 结构与工程
- **PanelView 886 行拆分**(与 P2-15 的粒度修复合并):PanelHeader / 每 tile 独立 View / PanelProcessSection / PanelFooter + SelfUsageSampler / TileFlowLayout(tileRows 算法可考虑 SwiftUI Layout 协议)。本体收敛到 ~100 行组合代码;hideable/tileRows 的 AnyView 尽量用泛型/@ViewBuilder 保留类型信息。
- **DesignTokens 绕过**:secondary 0.55/0.6 不统一(PanelView vs FanCeremonyOverlay)、分隔线 0.09、背景 0.06/0.08、tile minHeight 116、设置窗 640×560 在 AppDelegate 出现 5 次。增加 Color.secondaryText/divider/tileBackground、Size.settings 等 token 统一引用。电池严重度阈值逻辑在 PanelView.swift:587-598 与 StatSlotView.swift:85-96 各写一遍,下沉为 BatteryStore 计算属性。
- **fansTile 重复代码**:PanelView.swift:538-546 与 555-563 几乎相同;577 行裸 `fansExpanded.toggle()` 绕过了带 Reduce Motion 门控的 toggleExpansion,展开是硬跳。
- **StatusBarPanel 首开双挂载**:ensurePanel 已建 hosting,open 又赋一次 rootView → 首开构建两棵 PanelView;尺寸驱动 setFrame 在展开动画期间逐帧 resize。仅 closed→open 转换时赋 rootView;setFrame 节流(高度差 <0.5pt 跳过)。
- **工具链**:SWIFT_VERSION 仍是 5.0,可升 5.9+/6 语言模式(严格并发检查会直接暴露 P2-17 的主线程约定问题);部署目标 12.0 是 Xcode 27 的硬约束,合理。
- 仓库卫生:`._*` AppleDouble 文件散落源码树(未被 git 跟踪,.gitignore 已覆盖),本地清理即可;BuildTools/.build 666MB 为本地 SwiftFormat 构建产物,未入库,无问题。

---

## 建议的修复顺序

1. **P0-1 更新链签名校验**(安全缺口,改动小收益大)
2. **P0-2 Shell 失败路径**(一个函数修好,两个功能永久冻结的风险消除)
3. **P1-6/7/8/12**(用户可直接感知的功能缺陷,均为小改动)
4. **P0-3/4/5 + P1-9/10/11**(数据正确性;Clean Mode 权限需真机验证)
5. **P2-13/14/15/16**(主线程重活外移 + 面板粒度,常驻与打开期 CPU 的主要下降空间)
6. **P2-17/18/19/20**(SMC 双倍读取、widget 预算、图表过采样——能耗进一步下降)
7. P3 随手清理

修完 P0/P1 后,这个代码库可达可长期维护的生产水准;P2 做完,常驻开销结构就相当健康了。