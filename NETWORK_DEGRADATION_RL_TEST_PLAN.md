# TopFull 网络退化场景测试计划（RL + NDI）

## 1. 背景与目标

本测试计划用于验证以下论点：

1. TopFull 在其定义域（CPU-bound overload）内通常有效。
2. 当根因变为网络退化（非 CPU 主导）时，原始 TopFull RL（仅依赖 goodput/latency）存在局限。
3. 在不大幅增加模型复杂度的前提下，仅新增 1 个网络退化观测参数 `NDI`，可提升网络退化场景下的控制效果。

---

## 2. 核心假设

- `H1`：CPU-bound 场景下，原始 TopFull RL 可较好恢复（goodput 回升、latency 回落）。
- `H2`：网络退化场景下，原始 TopFull RL 容易出现误判或缓解不足。
- `H3`：新增 `NDI` 后，RL 在网络退化场景的恢复速度、SLO 违约时间、有效吞吐将优于原始 RL。

---

## 3. 新增参数定义（仅 1 个）

### 3.1 NDI（Network Degradation Index）

定义为关键链路延迟膨胀指数：

\[
NDI_t = \max_{e \in E_{critical}} \left(\frac{L_e(t)}{L_e^{base}} - 1\right)_+
\]

- `L_e(t)`：时刻 `t` 的链路延迟（建议 p95 或 avg）。
- `L_e^{base}`：同链路在健康状态下的基线延迟。
- `E_{critical}`：关键 API 路径上的关键服务间链路集合。

说明：
- 先采用 `max` 形式保证对瓶颈最敏感。
- 可使用平滑（如 EWMA）降低抖动，不改变“仅 1 个新增参数”的原则。

---

## 4. 实验分组设计

### G0：原始 TopFull RL（对照组）
- 输入：`[goodput_ratio, latency95]`
- 门控：CPU overload 触发
- 动作：入口 API throttling（现有实现）

### G1：TopFull RL + NDI（实验组）
- 输入：`[goodput_ratio, latency95, NDI]`
- 门控：`CPU overload OR NDI > threshold`
- 动作：入口 API throttling（保持执行器不变）

### G2（可选增强组）
- 输入同 G1
- 动作仍在入口侧，但增加 API 定向权重策略（不必在首轮实现）

> 首轮最小可行建议：先做 G0 vs G1，验证“仅增加 1 个参数”的增益。

---

## 5. 场景设计

### S0：健康基线（无故障）
- 目的：确认系统在稳态负载下指标范围与基线链路延迟。

### S1：CPU-bound overload
- 目的：验证 H1（TopFull 定义域内有效）。
- 预期：G0 与 G1 均表现较好，差异不一定显著。

### S2：局部网络退化（单服务/少数 pod）
- 示例：仅对 `productcatalogservice` 或 `checkoutservice` 某些 pod 注入额外延迟。
- 目的：验证 H2/H3 的主场景。

### S3：多点网络退化（同一路径多服务）
- 目的：观察控制稳定性与恢复上限。

---

## 6. 指标与验收标准

## 6.1 主指标
- `Goodput`（总与分 API）
- `Latency95/Latency99`（总与分 API）
- `SLO violation time`（超过延迟阈值的累计时长）
- `Time-to-Recovery (TTR)`（从注入到恢复稳态耗时）

## 6.2 辅指标
- `Fail rate`
- `Throttle level`（阈值变化轨迹）
- 控制振荡幅度（避免“过控-反弹”）

## 6.3 期望结论标准（建议）
- 在 `S2/S3` 中，G1 相比 G0：
  - Goodput 提升（均值或分位数）
  - SLO 违约时长下降
  - TTR 缩短

---

## 7. 执行步骤（基于现有脚本）

### 7.1 部署
```bash
cd experiment/TopFullExt
CONTROLLER_MODE=rl ./coordinate_setup.sh
```

### 7.2 启动控制与流量
```bash
make rl
make inject-base
make inject-surge DURATION=30m
```

### 7.3 状态检查与观测
```bash
make status
make observe
```

### 7.4 网络延迟注入（S2/S3 场景）

使用 `net_delay_k8s.sh`，所有参数通过 `.env` 配置。

**手动注入 / 清理：**

```bash
make net-delay-set
make net-delay-status
make net-delay-clear
```

**定时注入（与实验流量同步）：**

```bash
make net-delay-run
```

**自定义覆盖（不修改 .env）：**

```bash
NET_TARGET_SELECTOR=app=checkoutservice \
  NET_DELAY_MS=300 NET_JITTER_MS=20 \
  ./net_delay_k8s.sh set
```

### 7.5 停止
```bash
make stop
make net-delay-clear
make net-delay-status
```

### 7.6 绘图与结果导出
```bash
python plot_topfull_results.py --sync-first --prefix topfull
```

---

## 8. 数据记录规范

- 每组至少重复 `N=5` 次（不同时间窗或不同随机种子）。
- 统一记录：
  - `logs/total.csv`
  - `logs/<api>.csv`
  - `/tmp/topfull-controller.log`
  - 实验配置快照（注入参数、分组、时间戳）
- 输出图：
  - `topfull_total_metrics.png`
  - `topfull_api_goodput.png`

---

## 9. 结果分析框架

建议按以下顺序分析：

1. 先看 S1（CPU-bound）：确认 TopFull 在定义域内有效（建立公平前提）。
2. 再看 S2/S3（网络退化）：展示 G0 局限。
3. 比较 G1 与 G0：证明“新增 1 个网络参数 NDI”带来的改进。
4. 若改进有限，讨论入口侧执行器上限（可作为下一阶段工作）。

---

## 10. 风险与注意事项

- 若仍沿用“仅 CPU 门控”，网络退化可能无法触发控制回路，导致假阴性结论。
- 入口侧 throttling 只能缓解，不保证根因修复（尤其是局部坏 pod/链路问题）。
- 训练与评估分离：避免在评估流量上直接在线训练造成偏差。

---

## 11. 交付物清单

- 实验日志与图表（按分组归档）
- 分组对比表（G0/G1 在 S1/S2/S3 的主指标）
- 结论页：有效域、失效域、NDI 增益、残余不足

---

## 12. 网络延迟注入验收清单

每次注入实验前后按以下项目检查：

- [ ] `.env` 中 `NET_TARGET_SELECTOR` / `NET_TARGET_PODS` 已正确设置
- [ ] `make net-delay-set` 后 `make net-delay-status` 可见 netem 规则（含 delay 值）
- [ ] `make net-delay-clear` 后 `make net-delay-status` 确认规则已移除
- [ ] `make net-delay-run` 按 `NET_INJECT_AT_SEC` / `NET_RELEASE_AT_SEC` 时间自动注入和释放
- [ ] 中断脚本（Ctrl+C）后规则自动清理（`trap EXIT` 生效）
- [ ] 非目标 Pod 不受影响（检查同节点其他 Pod 的 qdisc）
- [ ] 注入期间 `make status` 能正常展示 netem 状态
- [ ] 与 `make rl` / `make inject-base` / `make inject-surge` 组合执行无冲突
