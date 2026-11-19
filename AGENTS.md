# SleepSkip 项目工程规范

本文件沉淀自项目高频返工与架构演进经验，所有代码修改与评审均需遵守以下约束。

## 1. 会话状态机与转换契约（防止多入口漏同步）

- **单一状态场景真源**：UI 视图分发必须基于 `SessionManager.popoverScene`（`.idle` / `.following` / `.manualRunning`），禁止在视图层用 `isRunning && !isFollowingAgents` 等零散布尔组合重新拼接状态分支。
- **转换路径对齐**：`SessionManager` 中所有产生或切换运行态会话的入口（`startConfiguredSession`、`promoteAutoFollowToManual`、`switchManualToAutoFollow`、`beginAutoFollow`）必须保持以下前置/后置契约一致：
  1. 手动或接管启动前必须先提交并校验挂起的输入（如 `applyPendingCustomDurationIfNeeded()`）。
  2. 切换合盖守卫（`BackpackGuard` / `UnprivilegedLidGuard`）失败时，必须回滚或保留原有保护并显式上报 `errorMessage`，严禁静默降级为无保护状态。
  3. 产生新手动会话时，必须统一处理 `config.effectiveLockOnStart` 与安全监控（电源/温控）。
- **新增状态字段必须配状态矩阵测试**：在 `SessionManager` 新增影响生命周期或状态的 `@Published` 属性时，必须在 `Tests/SleepSkipTests/SleepSkipCoreTests.swift` 中补全「空闲 / 自动跟随 / 手动运行 / 等待授权 / 失败回滚」转换测试。

## 2. macOS 系统黑盒与电源机制变更规范

- **实测先于假设**：涉及 `powerd`、`IOPMrootDomain`（如 selector 12 `kPMSetClamshellSleepState`）、`pmset`、`NSPopover` 定位或 `FSEvents` 的机制调整，必须先通过 `scripts/probes/` 或可复现命令在真机验证系统实际行为，再修改定时策略或观察者。
- **不可破坏的核心不变量**：
  - 待机期间保持零轮询（`UnprivilegedLidGuard` 的低频重arm定时器仅允许在合盖守卫激活期间运行）。
  - 特权模式（`pmset -a disablesleep 1`）必须继续通过独立脚本 + sentinel PID 守护，并在启动时清理遗留进程。

## 3. 提交前自动化门禁

在认为任何改动完成之前，必须全部通过以下命令：

```bash
swift test
./scripts/verify.sh
./scripts/probe_app_integration.sh
```

涉及发布包或底层电源行为改动时，额外执行：

```bash
bash scripts/verify_release.sh
```
