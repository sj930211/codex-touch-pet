# 狐狸逐帧动画测试 v1

这是一组动画测试与资源验收素材。当前已将通过结构检查的 idle/working 帧归一化后接入 `Resources/Fox`。

## 当前结果

- `idle`：6 帧，真实眨眼、呼吸、头部和尾巴细微变化；结构检查通过。
- `running`：6 帧，真实爪子操作、视线、耳朵和尾巴变化；电脑固定在狐狸右侧；两条后腿落地、两条前腿连接键盘；结构检查通过。
- `normalized/`：idle/working 均统一为 192×208 画布、171px 角色高度和同一基线，避免状态切换时视觉大小跳变。
- `decoded/running-before-anatomy-fix.png` 保留为修正前版本。
- `decoded/running-v1.png` 保留为早期版本，因电脑道具在帧间左右跳位，不作为候选。

## 预览

- `qa/idle-frames-sheet.png`：空闲逐帧大图
- `qa/running-frames-sheet.png`：工作逐帧大图
- `qa/idle-preview.gif`：空闲放大循环
- `qa/running-preview.gif`：工作放大循环
- `qa/idle-touchbar-preview.gif`：空闲 Touch Bar 高度循环
- `qa/running-touchbar-preview.gif`：工作 Touch Bar 高度循环
- `qa/fox-animation-test-sheet.png`：汇总预览

## 验收边界

当前已接入两种状态的真实逐帧动画。等待、完成、异常仍使用静态资源和既有事件动效，后续可在新素材通过同样 QA 后再补齐。
