# 菜单与设置原生视图预览

来源：`make test-interface` 使用实际 `MenuBarPresentation` 和 `SettingsWindowController` 的 AppKit 视图离屏渲染。

- `menubar-fox.png`：生产 20pt 矢量模板图标以 2 倍尺寸预览，非新生成的宠物素材。
- `settings-light.png` / `settings-dark.png`：620×650pt 默认窗口。
- `settings-*-minimum.png`：560×620pt 最小窗口。
- `settings-*-about.png`：关于与帮助页。
- `settings-quiet.png`：安静模式下控件禁用及偏好保留说明。
- `menu-summary-*.png`：各状态菜单摘要，白底仅为离屏阅读，实际菜单背景由 macOS 提供。

这些图片不是系统菜单或实体 Touch Bar 截图。菜单本体由原生 `NSMenu` 绘制，真实点击、键盘导航和系统材质仍需在运行应用中验收。

保留已确认的狐狸 App 图标；菜单栏图标由本项目 `MenuBarIcon` 的矢量路径绘制。未为这些预览调用生图模型。
