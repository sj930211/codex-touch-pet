# codex-touchbar-poc

Codex 状态宠物在实体 MacBook Touch Bar 上的可行性验证。

## 当前状态

- Touch Bar 真机展示：已通过。
- 退出和 Control Strip 恢复：已通过。
- Codex `active → idle/completed` 实时状态：已通过。
- Control Strip 宠物常驻，Codex 前台时自动展开完整状态。
- 多个活动任务显示汇总数量，例如“正在处理 2 项工作”，不显示 1/2、2/2 分页编号。
- 工具活动只作短暂辅助信息，不覆盖主工作状态。
- 产品设计：见 `PRODUCT_DESIGN.md`。

## 构建与运行

```bash
make clean all
make probe
./touchbar-pet-poc 45
python3 codex_status_probe.py
python3 desktop_status_probe.py 10
make test-app app
```

`touchbar-pet-poc` 会在设定时间后自动清理。也可以按 `Ctrl-C` 提前退出。

正式应用构建在 `.build/app/Codex Touch Pet.app`。它不会自动安装或设置开机启动。

## 注意

本项目使用 macOS 和 Codex Desktop 的私有接口，只适合实验、自用或有明确兼容性策略的直接分发产品。不要把当前 PoC 当作稳定公开 API 示例。
