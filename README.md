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

核心代码在 `Tweak.x`，分两层。

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

## 工程结构

```
Makefile                 Theos 主工程，默认 rootless
control                  deb 元数据
VerticalMenu.plist       注入 com.apple.UIKit（所有 UIKit 进程）
Tweak.x                  Logos hook
Prefs/                   设置 App 里的「纵向菜单」开关
layout/Library/PreferenceLoader/Preferences/
                         VerticalMenu.plist 设置入口（含图标）
                         VerticalMenu.png / @2x / @3x
```

设置项（`com.qins.verticalmenu`）：

- `Enabled`：总开关，默认开
- `ContextMenus`：改 compact / palette 上下文菜单
- `EditMenus`：改拷贝粘贴条
- `Debug`：NSLog 前缀 `[VerticalMenu]`

改开关后点「注销 SpringBoard」，并且把目标 App 从多任务里划掉再开，注入才会进新进程。

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

把对应越狱环境的 deb 拷到手机，用 Sileo / Zebra / `dpkg -i` 安装，然后 respring。设置里的「纵向菜单」由 PreferenceLoader 直接打开，不依赖自定义 PreferenceBundle。

每次往 `main` 的 push 会跑 `.github/workflows/build.yml`：

1. 分别编译 **rootless** 和 **roothide** 两份 `.deb`
2. 作为 Actions artifact 上传（`verticalmenu-rootless` / `verticalmenu-roothide`，以及合并后的 `release`）
3. 构建成功后发布到 GitHub Releases（标签 `v` + `control` 里的版本号，例如 [Releases](https://github.com/charlesqin7/menu-stack/releases)），deb 挂在该 Release 下面

RootHide / Dopamine 用户请装对应 scheme 的 deb，装完 respring，并把 Safari 从多任务划掉再开。

插件注入时**总会**打一条 `NSLog`，不依赖「调试日志」开关：

```
[VerticalMenu] loaded in com.apple.mobilesafari enabled=1 context=1 edit=1 debug=0 list=1
```

用 `idevicesyslog | grep VerticalMenu`（或设备上的系统日志）就能确认有没有进 Safari。打开「调试日志」后才会有 `sizeThatFits` 等细节。若复制菜单完全不出现，先在设置里关掉「文本选择菜单」，划掉 App 再试：横条应恢复，用来确认是不是这一层 hook 的问题。

## 在设备上自测

1. 备忘录或信息里长按一条内容：顶部那排并排小按钮应变成逐行列表。
2. 任意输入框选中文字：拷贝菜单应为纵向列表，一次最多 5 项，其余可上下滑；靠近屏幕顶部选字时不应顶进状态栏。
3. Safari 长按链接：若系统给了 palette / compact 行，应变纵向；本来就是竖列表的动作区保持竖列表。

## 没生效时怎么查

1. 确认 dylib 在 rootless 路径：  
   `/var/jb/Library/MobileSubstrate/DynamicLibraries/VerticalMenu.dylib`  
   以及同名 `VerticalMenu.plist`。
2. 打开调试日志，完全杀掉 App 再开，看是否出现 `[VerticalMenu] loaded in <bundle id>`。没有日志就是没注入（ElleKit 过滤、未 respring、装到了错误的 scheme）。
3. 文本条仍是横的：在设备上 class-dump / Cycript / Frida 看 `UIKitCore` 里实际类名是不是还叫 `_UIEditMenuListView`。若改名，把 `Tweak.x` 里的 `%hook` 类名换成新的即可。
4. 某个 App 崩溃：先在设置里关掉「文本选择菜单」或「上下文菜单」定位是哪一层 hook；私有 layout 被替换时偶发不兼容，优先关 EditMenus。

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
