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

1. hook `sizeThatFits:` / `intrinsicContentSize`，按条目数算出竖向尺寸（默认宽 236pt，行高 44pt）。
2. hook `layoutSubviews`，找到内部 `UICollectionView`，把 `UICollectionViewFlowLayout.scrollDirection` 改成纵向，并隐藏翻页按钮。
3. 若内部不是 flow layout，尝试 KVC 改 `scrollDirection`；再不行就替换成一条新的 flow layout（只替换一次）。
4. hook `_UIEditMenuListViewCell` / `_UIEditMenuListCell` 的 `layoutSubviews`：把原来「图标在上、标题在下」的 stack 改成横向，图标左、文字右。

私有类名随系统小版本可能变。打开设置里的「调试日志」后，用 `idevicesyslog | grep VerticalMenu` 看有没有 `sizeThatFits` 日志，就能确认 hook 是否打上。

## 工程结构

```
Makefile                 Theos 主工程，默认 rootless
control                  deb 元数据
VerticalMenu.plist       注入 com.apple.UIKit（所有 UIKit 进程）
Tweak.x                  Logos hook
Prefs/                   设置 App 里的「纵向菜单」开关
layout/Library/PreferenceLoader/Preferences/
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
cd VerticalMenu   # 或本仓库根目录

# palera1n / 现代 rootless（默认）
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

生成的 deb 在 `packages/`。架构是 `iphoneos-arm64`。

若你是 **rootful** 越狱：

```bash
make clean package FINALPACKAGE=1
```

并把 `control` 里的 `Architecture` 改成 `iphoneos-arm`（Theos 在非 rootless 时一般会自己改）。

把 deb 拷到手机，用 Sileo / Zebra / `dpkg -i` 安装，然后 respring。

推到 GitHub 后，每次 `push` 会跑 `.github/workflows/build.yml`：在 macOS runner 上装 Theos，编译 rootless `.deb`，并作为 Actions artifact 上传。

## 在设备上自测

1. 备忘录或信息里长按一条内容：顶部那排并排小按钮应变成逐行列表。
2. 任意输入框选中文字：原来的拷贝/粘贴横条应变成纵向菜单，可以上下滑。
3. Safari 长按链接：若系统给了 palette / compact 行，应变纵向；本来就是竖列表的动作区保持竖列表。

## 没生效时怎么查

1. 确认 dylib 在 rootless 路径：  
   `/var/jb/Library/MobileSubstrate/DynamicLibraries/VerticalMenu.dylib`  
   以及同名 `VerticalMenu.plist`。
2. 打开调试日志，完全杀掉 App 再开，看是否出现 `[VerticalMenu] loaded in <bundle id>`。没有日志就是没注入（ElleKit 过滤、未 respring、装到了错误的 scheme）。
3. 文本条仍是横的：在设备上 class-dump / Cycript / Frida 看 `UIKitCore` 里实际类名是不是还叫 `_UIEditMenuListView`。若改名，把 `Tweak.x` 里的 `%hook` 类名换成新的即可。
4. 某个 App 崩溃：先在设置里关掉「文本选择菜单」或「上下文菜单」定位是哪一层 hook；私有 layout 被替换时偶发不兼容，优先关 EditMenus。

## 合法与风险

- 只用于你自己越狱设备上的界面改动。
- 调用了 UIKit 私有类，**系统小版本更新后可能失效或崩溃**，升级前先卸插件。
- 不能通过 App Store 分发。

## 许可证

MIT
