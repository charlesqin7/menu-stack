# 纵向菜单（VerticalMenu）

面向 **已越狱的 iOS 17.0**（同样覆盖 iOS 16）的 Theos 插件：把系统长按菜单里的**横向排列**改成**纵向列表**。

这不是越狱工具，只是安装到你自己设备上的 UI 插件。需要本机已经能用 Sileo / Zebra 装 tweak，并且有 ElleKit、Substitute 或 Cydia Substrate。

## 先分清你看到的是哪一种菜单

iOS 16/17 里「长按出现一排按钮」其实有三条互不相干的渲染路径，改错类就不会生效：

| 你在屏幕上看到的 | 系统实现 | 本插件怎么改 |
| --- | --- | --- |
| 长按 App 图标、链接、表格行之后，上面 3～4 个并排小按钮（备忘录里的扫描/置顶/锁定那种） | `UIMenu.preferredElementSize = small / medium` | 强制改成 `large`，变成每行一个完整条目 |
| 长按后出现一排只有图标的调色盘（iOS 17 书籍/邮件那种） | `UIMenu.options` 带 `displayAsPalette`（`1 << 7`） | 从 options 里清掉这一位 |
| 选中文字后浮出来的「拷贝 / 全选 / 粘贴」横条 | `UIEditMenuInteraction` → 私有类 `_UIEditMenuListView`（横向 `UICollectionView`） | 把 collection view 改成纵向，并重排 cell |

普通的上下文菜单动作列表本来就是纵向的，不用动。本插件针对的是上面三种「被做成横排」的情况。

文本选择条尤其不能只改 `preferredElementSize`：手指长按走的是 edit menu 展示，不是 context menu。`large` 只影响 cell 样式，**不会**把那条横栏变成竖列表。所以 `Tweak.x` 里对 `_UIEditMenuListView` 做了单独 hook。

## 实现要点

核心代码在 `Tweak.x`。菜单内容规则与视觉布局彼此独立：规则只在 UIKit 交付菜单模型时改一次菜单树，collection view 层只负责纵向尺寸、滚动和安全区域。

### 1. 上下文菜单 / palette（公开 API，最稳）

```objc
%hook UIMenu
- (NSInteger)preferredElementSize { return 2; } // UIMenuElementSizeLarge
- (NSUInteger)options { return %orig & ~(1 << 7); } // 去掉 displayAsPalette
%end
```

同时 hook 了 `menuWithTitle:image:identifier:options:children:` 和 `initWithTitle:image:identifier:options:children:`，避免 UIKit 只读 ivar、不走 getter。

### 2. 文本选择横条（私有类，运行时兜底）

对 `_UIEditMenuListView`：

1. hook `sizeThatFits:` / `intrinsicContentSize`，宽 280pt、行高 44pt；窗口高度最多 5 行，多出来的条目在 collection view 里上下滑。
2. 用当前选区矩形把菜单贴到文字下一行，并把顶部箭头移到选区中点；选区靠右时菜单贴右边、箭头仍对准选中的字。
3. 菜单上屏后再改内部 `UICollectionView`：系统用的是横向/分页 layout（把容器拉高只会变成「很高的几列」），所以换成自己的 `VLMVerticalListLayout`，每行 44pt 全宽。
4. 拦截 `setCollectionViewLayout:`，避免 UIKit 下一拍又把横向 layout 设回去。
5. 关掉 paging，隐藏 `_UIEditMenuPageButton`；没有系统图标的条目显示默认 `ellipsis.circle` 图标，保证文字左对齐。
6. 去掉菜单容器上的系统投影；列表上下各留 16pt，避免圆角把最后一行裁成半截。

私有类名随系统小版本可能变。打开设置里的「调试日志」后，用 `idevicesyslog | grep VerticalMenu` 看有没有 `sizeThatFits` 日志，就能确认 hook 是否打上。

### 3. 排序与隐藏（V2 策略）

- `MenuRegistryV2` 只记录 App 实际出现过的菜单项；观察菜单不会覆盖用户规则，也不会在每次展示时同步写盘。动态观察有容量上限，避免长期使用后偏好文件无限增长。
- `MenuPoliciesV2` 保存全局策略和 App 例外。App 可对每一项选择“继承 / 显示 / 隐藏”，因此可以恢复全局隐藏的项目；顺序可选“继承 / 系统 / 自定义”。
- 自定义顺序分为“固定到前面 / 相对顺序 / 固定到后面”。未配置或后来动态出现的项目保留系统槽位，不会被统一挤到末尾。
- 规则递归处理 `UIMenu` 层级和延迟生成的菜单项，不再在 cell 或 collection view 层二次排序。

## 工程结构

```
Makefile                 Theos 主工程，默认 rootless
control                  deb 元数据
VerticalMenu.plist       注入 com.apple.UIKit（所有 UIKit 进程）
Tweak.x                  Logos hook
VLMMenuRules.h/.m        可独立测试的菜单匹配、排序、隐藏与迁移规则
VLMMenuOrder.h/.m        设置持久化、跨进程同步和规则数据适配
Tests/                   Foundation 规则测试与工程元数据检查
Prefs/                   设置 App 里的「纵向菜单」开关与菜单规则页
layout/Library/PreferenceLoader/Preferences/
                         VerticalMenu.plist 设置入口（含图标）
                         VerticalMenu.png / @2x / @3x
```

设置项（`com.qins.verticalmenu`）：

- `Enabled`：总开关，默认开
- `ContextMenus`：改 compact / palette 上下文菜单
- `EditMenus`：改拷贝粘贴条
- `MenuPoliciesV2`：文本选择 / 上下文菜单各一份全局规则，并保存各 App 的三态可见性与顺序模式
- `MenuRegistryV2`：按 App × 菜单类型合并的观察记录，仅用于设置页列出真实出现过的菜单项
- `MenuPolicyV1Backup`：首次升级时保存旧版全局、Profile、顺序和隐藏字段，便于排查迁移问题
- `CustomOrder` / `MenuItemOrder` / `HiddenMenuItems` / `GlobalRules` / `MenuProfiles`：旧版兼容数据，首次升级后迁移到 V2
- `Debug`：NSLog 前缀 `[VerticalMenu]`

在设置里先改「文本选择 · 全局」和「上下文菜单 · 全局」。某个 App 要恢复全局隐藏项、额外隐藏项目，或使用自己的顺序时，打开「按 App 例外」。先在对应 App 里弹出一次菜单，Registry 记录后该 App 才会出现在列表中。

改开关或排序后点「注销 SpringBoard」，并且把目标 App 从多任务里划掉再开，注入才会进新进程。

## 环境

- 已越狱的 **iOS 16.0+** 设备（按 iOS 17.0 测过思路；17.0 常用 palera1n rootless + ElleKit）
- 一台装了 [Theos](https://theos.dev/) 和 iOS SDK 的 **macOS**
- 设备上有 PreferenceLoader，设置页才会出现；没有的话插件仍按默认值工作

## 编译

在 Mac 上：

```bash
export THEOS=~/theos
git clone <本仓库>
cd menu-stack   # 或本仓库根目录

# palera1n / Dopamine 等 rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

# RootHide / Bootstrap
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

生成的 deb 在 `packages/`。rootless / roothide 架构都是 `iphoneos-arm64`。

把对应越狱环境的 deb 拷到手机，用 Sileo / Zebra / `dpkg -i` 安装，然后 respring。设置里的「纵向菜单」由 PreferenceLoader 打开 PreferenceBundle（`VerticalMenuPrefs`），里面可以开关功能并拖动调整菜单顺序。

PR、手动运行以及每次往 `main` 的 push 都会跑 `.github/workflows/build.yml`：

1. 先检查 plist / 版本一致性并运行 Foundation 菜单规则测试
2. 分别编译 **rootless** 和 **roothide** 两份 `.deb`
3. 作为 Actions artifact 上传（`verticalmenu-rootless` / `verticalmenu-roothide`，以及合并后的 `release`）
4. 只有 `main` push 且 `control` 对应的版本标签尚不存在时才发布 GitHub Release；已有标签和 Release 永不覆盖

发布新版本前，要同时更新 `control` 与 `Prefs/Resources/Info.plist` 里的版本号。创建 Release 标签不会再次触发一轮构建。

在 macOS 本地可先运行：

```bash
bash Tests/validate-project.sh
bash Tests/run-tests.sh
```

RootHide / Dopamine 用户请装对应 scheme 的 deb，装完 respring，并把 Safari 从多任务划掉再开。

打开「调试日志」后，插件注入时会输出类似：

```
[VerticalMenu] loaded in com.apple.mobilesafari enabled=1 context=1 edit=1 debug=1 list=1 registry=2
```

用 `idevicesyslog | grep VerticalMenu`（或设备上的系统日志）就能确认有没有进 Safari。打开「调试日志」后才会有 `sizeThatFits` 等细节。若复制菜单完全不出现，先在设置里关掉「文本选择菜单」，划掉 App 再试：横条应恢复，用来确认是不是这一层 hook 的问题。

## 在设备上自测

1. 备忘录或信息里长按一条内容：顶部那排并排小按钮应变成逐行列表。
2. 任意输入框选中文字：拷贝菜单应为纵向列表，一次最多 5 项，其余可上下滑；靠近屏幕顶部选字时不应顶进状态栏。
3. Safari 长按链接：若系统给了 palette / compact 行，应变纵向；本来就是竖列表的动作区保持竖列表。
4. 设置里打开「文本选择 · 全局」，把「粘贴」拖到“固定到前面”：各 App 选中文字后，系统提供粘贴时它应排在首组。
5. 关闭「上下文菜单」并重新打开目标 App：系统上下文菜单应完全恢复原样，不再应用全局排序或隐藏。
6. 关闭「文本选择菜单」并重新打开目标 App：拷贝 / 粘贴菜单应恢复系统原始横条。
7. 在「按 App 例外」里隐藏一项：其它 App 仍应显示；再把一个全局隐藏项设为“显示”，该项在此 App 中应恢复（前提是系统本次提供它）。
8. 把两个已知项目调换相对顺序，然后触发包含动态项目的菜单：动态项目应保留原系统位置，子菜单层级也不应被拆散。
9. 打开键盘并在屏幕顶部、底部各选一次文字：菜单不得进入状态栏、灵动岛或键盘区域；超过 5 项时仍可顺畅上下滑。
10. 关闭「调试日志」时不应输出 `[VerticalMenu]` 诊断日志；打开后再弹出菜单，才应出现布局、记录和设置持久化细节。

## 没生效时怎么查

1. 确认 dylib 在 rootless 路径：  
   `/var/jb/Library/MobileSubstrate/DynamicLibraries/VerticalMenu.dylib`  
   以及同名 `VerticalMenu.plist`。
2. 打开调试日志，完全杀掉 App 再开，看是否出现 `[VerticalMenu] loaded in <bundle id>`。没有日志就是没注入（ElleKit 过滤、未 respring、装到了错误的 scheme）。
3. 文本条仍是横的：在设备上 class-dump / Cycript / Frida 看 `UIKitCore` 里实际类名是不是还叫 `_UIEditMenuListView`。若改名，把 `Tweak.x` 里的 `%hook` 类名换成新的即可。
4. 某个 App 崩溃：先在设置里关掉「文本选择菜单」或「上下文菜单」定位是哪一层 hook；私有 layout 被替换时偶发不兼容，优先关 EditMenus。

## 更新（1.0.51）

- 修复旧版或异常 `MenuRegistryV2` 数据在每个 UIKit 应用启动阶段被直接遍历、导致设置、备忘录、Safari 等宿主应用一起闪退的问题；运行时读取现在始终先清洗数据。
- 配置解析加入“宿主优先”保护：即使共享偏好损坏，也只在当前进程停用插件，不再让宿主应用崩溃。
- 根据 1.0.50 的 Sileo 崩溃栈，暂停会进入系统导航栏 `_backButtonMenu` 的全局 `UIMenu` 钩子，以及 1.0.49 新增的 `UIEditMenuInteraction`、延迟菜单 provider 代理；1.0.51 仅保留不会在 App 启动阶段命中的文本选择列表布局路径，待更窄的入口通过真机验证后再恢复上下文菜单能力。

## 更新（1.0.50）

- 修复 V2 包安装后 SpringBoard 进入安全模式：SpringBoard 只保留偏好通信，不再安装菜单 UI hook 或执行策略迁移；V2 迁移改由“设置”进程完成。

## 更新（1.0.49）

- 修复同一菜单行同时显示系统原生标题和插件标题造成的两个“粘贴”及图标叠字；缓存快速路径也会持续压住 UIKit 后创建的原生标题与图标。
- 固定菜单行共用的左侧对齐基准，并关闭纵向列表的边界橡皮筋，避免滑到最上方或最下方时部分菜单项横向跳动。

## 更新（1.0.48）

- SpringBoard 不再安装文本菜单的全局 collection/cell 热钩子；普通偏好读取不再扫描临时目录和所有 App 容器，减少安装后的桌面卡顿。
- 全局顺序、隐藏和按 App 例外改为单次快照读取、后台串行写入与内存 Profile 索引，进入设置和连续切换开关不再反复同步读写。
- 滚动期间只配置新复用的菜单行，已配置行使用缓存；移除持续轮询，恢复系统预取以改善滑动流畅度。
- 菜单按真实安全区、键盘与选区统一计算方向和可用高度；左侧图标使用稳定覆盖层和确定性备用图标，滚动条贴合最终视口右边缘。

## 更新（1.0.47）

- 修复关闭「上下文菜单」后仍会应用全局排序和隐藏的问题；两个菜单总开关现在都会完整恢复系统原始行为。
- 菜单匹配、排序、隐藏和旧配置迁移拆成独立规则模块，并增加中英文标题、自定义项、全局与 App 例外、旧版排序等回归测试。
- 偏好设置改为每次通知只读取一次；详细诊断日志只在打开「调试日志」后输出，并移除没有实际作用的钩子。
- CI 会先跑规则与版本一致性检查，再并行构建 rootless / roothide；已有版本标签和 Release 不再被后续构建覆盖。

## 更新（1.0.46）

- 到处都卡：每个 UIKit 进程在读设置时都会把清洗后的 `MenuProfiles` 写回磁盘，Darwin 通知再让所有进程重读，形成写盘风暴。改为读设置只读；SpringBoard 收 Incoming 放到后台队列并合并 0.4 秒；层级日志不再写 Incoming。
- 自己画的指示器太丑：不再藏系统箭头、不再画自定义三角，也不再 `clipsToBounds` 裁掉托盘外面的指针。只把 `arrowDirection` / `preferredArrowDirection` 设成朝向选区，钳位后按类名把系统箭头贴回托盘边。毛玻璃的 `effect` 保留，只裁 collection。
- 选项前面的图标时有时无：不透明遮罩盖住原生 22×22 `UIImageView`，第一次 layout 还没有 `image` 时又把遮罩冻住。改为每次 layout 都把原生图标和标题挪到纵向位置；标题已经出现、下一拍仍没有原生图时才用省略号兜底。
- 按 App 分别设置不够用：顺序和隐藏改成全局两份（文本选择 / 上下文菜单），App 只记最近一次弹出的项，并可额外多藏或覆盖顺序。全局隐藏不能在某个 App 里打开。

## 更新（1.0.45）

- 上下都有指示器、且不指向选中的字：系统气泡箭头没藏干净（只藏一次、只认 `_arrowView`），同时又画了自定义三角，所以顶、底各一个；水平位置还按整行/整段选区中点，容易落到屏幕中央。改为每次都藏掉系统箭头，只留一个指示器，并按选中字形或两端拖点对准。
- 指示器看起来像贴上去的：硬边白三角、和托盘颜色不一致、用翻转模拟朝下。改为与菜单同色、圆一点的尖、底边叠进托盘约 1.5pt，朝上朝下分开画。
- 设置里点「按菜单设置顺序与隐藏」很卡：设置进程会 unsandbox 并扫所有 App 容器。改为只有 SpringBoard 负责收记录；设置页只读已经合并好的列表，打开时最多再通知 SpringBoard 后台收一次。
- 「MD清单」等又出现：采集时把嵌套子菜单和示例脚本整棵树记进来了，而且只增不减。改为只记当时菜单条上能看见的项，并清掉 Mac 菜单栏 / 示例脚本 / `MD清单` 这类脏项。

## 更新（1.0.44）

- 超出安全区：新日志里菜单在 `alpha=0` 时就落位，键盘已经弹出却没算进去（底边压到键盘），靠近顶部时 `y=65` 箭头会进岛。改为每次按真实键盘窗口 / `UIInputSetHostView` 钳位，并给箭头和状态栏留空；菜单真正显示出来后再落一次位。
- 右边灰条：给毛玻璃加 `maskView` 会把它收成 `0×0`，系统原来的 347pt backdrop 仍会画出来。改为关掉 `UIVisualEffectView.effect`、藏起 `_UIVisualEffectBackdropView` 和翻页按钮，不再给全屏容器做 mask。
- 设置里没有 X：和层级日志用同一种 `writeToFile:` 把 XML 写到沙盒 tmp/Documents；SpringBoard 先 unsandbox，再按容器目录和 `LSApplicationProxy` 去找这份文件，容器里的副本不再删掉。

## 更新（1.0.43）

- 弹出菜单后卡死：1.0.42 在滚动/布局时强制改毛玻璃和翻页按钮的 frame，和系统布局互相顶，形成死循环。改为只在毛玻璃自己上面做圆角遮罩，滚动结束再修一次，并且菜单记录推迟到下一拍再写，不再在布局里做跨进程通信。
- 滑动后右边灰条：系统仍会把原来约 347pt 宽的 `UIVisualEffectView` 加回来，祖先 `clipsToBounds` 裁不住这块毛玻璃。改为给毛玻璃设置 `maskView`，按 250pt 托盘裁切。
- 菜单超出安全区：纵向高度 252pt 仍沿用横条的原点，并且第一次还没落位就把 setup 标成完成。改为贴选区后按安全区和键盘顶部钳位，未落位前会再试一次。
- X 仍不出现在设置里：记录会写到和层级日志同一份可写的沙盒 tmp。SpringBoard 不再只靠 glob，而是用 `LSApplicationProxy` 的 `dataContainerURL` 去 `tmp/`、`Library/Caches/tmp/` 等路径精确读取后再写入全局配置。打开「按菜单设置」时会再通知 SpringBoard 收一次。装完请 **respring**，划掉 X 再选一次字。

## 更新（1.0.42）

- X 仍不出现在设置里：日志证明采集成功，但记录只写在 X 自己的 tmp，设置读不到。改为写进 App 沙盒 tmp（已验证可写），SpringBoard 再按容器扫描合并；同时用分布式通知把菜单列表发给 SpringBoard。
- 滑动后右边灰条：系统在 collection 滚动时把约 347pt 的毛玻璃加回来，而列表自己此时不会 layout。改为滚动时钉住托盘宽度并裁掉翻页按钮。

## 更新（1.0.41）

- X 选字后设置里仍没有：第三方 App 经常写不进全局配置。改为把记录丢到 `/var/tmp`，SpringBoard 和设置页会合并进来；读取时按菜单逐条合并，不会用一份新记录盖掉其它 App。
- 菜单弹出时跳一下：第一次就按纵向尺寸落位，并关掉系统把横条拉成竖列表的尺寸动画。
- 滑动后右边一条灰：系统会把原来约 347pt 宽的毛玻璃/翻页按钮加回来。列表自己裁切到 250pt，并持续藏掉翻页按钮。
- 滑动发硬：滚动时不再改 collectionView 的 frame / contentOffset，并关掉横向分页吸附。

## 更新（1.0.40）

- 选字菜单滑动卡顿：滚动时不再每帧重排、扫整棵菜单树、写层级日志或改 contentOffset；单元格只在尺寸变化时重画。
- 层级日志每个菜单只写一次，并带上 App 的 bundle id 和按钮文字。文件在该 App 沙盒 tmp（Filza 里常见 `VerticalMenu-menu.txt`），能写入时也会放到 `/var/tmp/VerticalMenu-menu.txt`。

## 更新（1.0.39）

- 第三方 App（例如 X）选字后设置里没有记录：沙盒经常写不进全局配置，改为必要时经 SpringBoard 写入；输入框聚焦时按实际选字菜单采集，不再要求必须先对上内置目录。

## 更新（1.0.38）

- 按各 App 实际弹出的菜单项记录，不再只认内置目录。备忘录里的「学习」等后半截/嵌套项也会出现在设置里，其它 App 同样按真实选项采集。

## 更新（1.0.37）

- 「按菜单设置」不再按系统每一次内部组合拆行。每个 App 只保留「文本选择」和「上下文菜单」两条，备忘录里选中文字、空白处、格式子菜单等会合并在一起。
- 升级后打开设置页或弹出一次菜单，会把旧的重复项自动合并；隐藏和自定义排序仍按 App × 菜单类型生效。

## 更新（1.0.33）

- 「调整顺序与隐藏」可为每个菜单项关闭显示；隐藏的项不会出现在弹出菜单里。

## 更新（1.0.32）

- 修复设置里「注销 SpringBoard」点了没反应：改为走系统注销接口，并弹出确认。
- 设置页「关于」里显示插件版本号。

## 更新（1.0.31）

- 排序列表补上 Safari 常见项：查找所选内容、搜索网页、新建快速备忘录、拷贝链接等。
- 弹出过的菜单项会记下来，下次打开「调整顺序」时出现，不再只在顺序真的变过时才记录。

## 更新（1.0.30）

- 修复设置列表里「纵向菜单」图标不显示。
- 修复点「调整顺序」闪退：排序页改为 Settings 可推入的 Preference 控制器。

## 更新（1.0.29）

- 设置里新增「自定义排序」：可拖动调整剪切、拷贝、粘贴、全选等菜单项的顺序，弹出菜单按这个顺序排列。

## 更新（1.0.28）

- 编辑模式左边留白与复制模式对齐：复制菜单会给翻页按钮留 22pt，编辑菜单没有这块留白，图标就会贴着圆角。现在按菜单左缘对齐，两种模式同一套左边距。

## 更新（1.0.27）

- 横向偏移改为无条件归零（滚动的 setBounds 路径也拦住），菜单离屏幕边缘至少 16pt。

## 更新（1.0.26）

- 修复左侧图标被裁半个：列表残留 22pt 的横向滚动偏移（原翻页留位），现在竖列表的横向偏移锁定为 0。
- 菜单宽度从 280 收窄到 250，右侧空白没那么大。

## 更新（1.0.25）

- 根据设备上导出的真实层级（`tmp/VerticalMenu-menu.txt`）定位：残影是菜单**内部**给翻页按钮留位的内容包装层（左缩进 22、宽 214），行只画中间一段，280 宽的毛玻璃两侧就露出半透明带。现在把包装层和 collection view 撑满整个菜单宽度，右侧不再有多出的底。
- 层级导出改为在调整完成后写文件，便于后续核对。

## 更新（1.0.24）

- 残影修复换成可证明的方案：把竖菜单到窗口之间的**每一层**祖先都挂同一块圆角裁切（只裁渲染、不改 frame，不会再卡死）。系统底板不管在哪一层、底色画在自己身上还是子视图里，都会被裁掉；之前按类名找容器在 16.5 上匹配不到，等于没挂。
- 每次菜单出现会把完整视图层级写到目标 App 沙盒的 `tmp/VerticalMenu-menu.txt`（Filza 可查看）。若仍有残影，把该文件发出来即可精确定位。

## 更新（1.0.23）

- 菜单右侧那块残影：系统展示动画用的复制层/毛玻璃背板不在裁切范围内，现在凡是位置和竖菜单对不上的这类背板直接隐藏。菜单自己的圆角底不受影响。

## 更新（1.0.22）

- 菜单背后不再露出黑色/灰色残底：竖列表自己画圆角背景，残余的系统底板整体裁掉（裁切挂在最外层容器上，之前挂错层所以没生效）。

## 更新（1.0.21）

- 修复 1.0.20 弹出菜单后卡死：不再改系统容器的大小。
- 菜单后面的灰底改为用裁切挡住，不和系统布局抢 frame。

## 更新（1.0.20）

- 去掉菜单后面偏到右边的那块灰底：原来的横向菜单容器没有跟着竖列表缩小，现在容器和残余阴影都对齐到当前菜单。

## 更新（1.0.19）

- 「粘贴」不再出现两份、也不再和图标叠在一起：用一层底把系统按钮自己画的字盖住，只显示我们排好的图标和标题。不改系统按钮内部，避免再卡死。

## 更新（1.0.18）

- 修复编辑模式出现两个「粘贴」、图标仍叠字：系统按钮标题只清一次，真正显示的是我们画的那一行。
- 修复复制/阅读模式选字卡死：不再每次布局都 invalidate，也不再把整个窗口的视图树扫一遍找选区。

## 更新（1.0.17）

- 修复备忘录选中文字后面板卡死、菜单弹不出来：不再在系统按钮布局过程中反复隐藏内部视图，箭头改到下一拍再画。

## 更新（1.0.16）

- 每一行都用同一套左边图标、紧挨着的标题，不再出现「粘贴」叠在图标上、或 H 分词等标题被甩到最右边。
- 菜单自己画对准选区的小三角，并避免被列表裁掉。

## 更新（1.0.15）

- 「粘贴」用 cell 最上层的独立标题，系统按钮里原来的文字藏掉，避免图标和「粘贴」叠在一起。剪切/拷贝仍用系统标题。

## 更新（1.0.14）

- 「粘贴」默认图标出现后，把该行文字推到图标右侧，避免叠在图标上。剪切/拷贝不改。

## 更新（1.0.13）

- 「粘贴」的默认图标画在 cell 最上层，不再被按钮挡住；剪切/拷贝仍用系统图标。
- 备忘录编辑时根据真实选区移动三角指示器，对准选中的文字。

## 更新（1.0.12）

- 「粘贴」没有系统图标时也会显示默认图标；剪切/拷贝等已有系统图标的项不改。

## 更新（1.0.11）

- 有系统图标的项继续显示系统图标，不再被默认 `…` 盖住。
- 「粘贴」只保留一行文字，去掉重叠的重复标题。

## 更新（1.0.10）

- 默认图标与系统图标、当前行文字同一套坐标：左右对齐、垂直居中；「粘贴」等原来漏掉的项也会补上默认图标。

## 更新（1.0.9）

- 设置 App 里「纵向菜单」条目显示图标（蓝底纵向菜单）。

## 更新（1.0.8）

- 去掉文本选择菜单外圈阴影。
- 一次显示的 5 行都能完整露出，最后一项不再被圆角裁切。
- 没有图标的菜单项会补一个默认图标。

## 合法与风险

- 只用于你自己越狱设备上的界面改动。
- 调用了 UIKit 私有类，**系统小版本更新后可能失效或崩溃**，升级前先卸插件。
- 不能通过 App Store 分发。

## 许可证

MIT
