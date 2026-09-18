# Codex Touch Bar 宠物可行性验证

验证日期：2026-09-17  
设备：MacBookPro17,1（Apple M1，实体 Touch Bar）  
系统：macOS 27.0（26A428）

## 结论

该产品作为个人使用或小范围直接分发的 macOS 工具是可行的。

它依赖两条当前可工作的私有链路：

1. Touch Bar 的 system-modal/system-tray 接口，用于跨应用展示宠物。
2. Codex Desktop 本机 IPC，用于获取正在运行任务的实时状态。

这两条链路都不是适合承诺长期兼容的公开产品契约。因此，产品必须内置版本探测、自动降级和安全退出；不适合把 Mac App Store 作为主要分发渠道。

## 实测结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| 私有 Touch Bar 入口存在 | 通过 | 四个 system-modal/system-tray selector 在运行时均可用 |
| 自定义内容显示在实体 Touch Bar | 通过 | 用户确认看到动态小熊、状态文字和 🐾 |
| 退出后恢复 Control Strip | 通过 | PoC 清理完成，TouchBarServer 与 ControlStrip 均保持运行 |
| 识别 Codex 正在运行 | 通过 | 当前线程实时状态为 `active` |
| 识别 Codex 完成并空闲 | 通过 | 捕获到 `idle`、turn `completed`、`hasUnreadTurn=true` |
| 不读取对话正文 | 通过 | 探针只输出线程 ID、状态、修订号和计数 |
| 独立 app-server 可作为完整实时源 | 不通过 | 对 Desktop 当前线程只返回 `notLoaded`，不能替代 Desktop IPC |

## 已确认的状态能力

Codex 协议定义支持：

- `idle`
- `active`
- `active + waitingOnApproval`
- `active + waitingOnUserInput`
- `systemError`
- turn `completed`

本次真机实际捕获了 `active → idle + completed`。审批等待、用户输入等待和系统错误已有协议定义，但尚未人为制造故障做真机验收。

## 风险边界

- Touch Bar 私有接口可能随 macOS 更新变化。
- Codex Desktop IPC 是桌面应用内部协调协议，可能随 Codex 版本变化。
- 使用私有 API 的应用不应以 Mac App Store 审核通过为目标。
- 工具不得自动重启 TouchBarServer、ControlStrip 或 WindowServer。
- 崩溃、信号退出和版本不兼容时，必须先撤销 system-tray item，再结束进程。

## 当前 PoC

- `selector_probe.m`：探测私有 Touch Bar selector。
- `touchbar_pet_poc.m`：短时展示并自动清理 Touch Bar 宠物。
- `codex_status_probe.py`：验证独立 app-server 的线程元数据能力。
- `desktop_status_probe.py`：订阅当前 Codex Desktop 线程的状态元数据。

当前目录没有安装常驻程序、修改 Codex 配置或配置开机启动。
