# 第 9 章 Scheduled Execution 与 Clock

> **第三部分：接口与状态机 · 初稿**
> 对应规范：[5.1 Concepts](../spec-3.0.2/html/index.html#concepts-scheduled-execution) / [5.2 State Machine](../spec-3.0.2/html/index.html#state-machine-scheduled-execution) / [5.3 Code Example](../spec-3.0.2/html/index.html#example-scheduled-execution) / [5.4 Schema](../spec-3.0.2/html/index.html#scheduled-execution-schema)
> 预计阅读：45 分钟
> 动手时间：30 分钟

## 学习目标

读完本章，你应该能够：

1. 说清 SE 与 ME、CS 的本质区别：SE 把「什么时候执行哪段代码」完全交给导入端的调度器。
2. 解释「模型分区」（model partition）的概念，以及它与 Clock、clocked variable 的对应关系。
3. 画出 SE 的状态机，区分 `ClockActivationMode` 和 `ClockUpdateMode`。
4. 正确调用 `fmi3ActivateModelPartition`，说清 `clockReference` 和 `activationTime` 的语义。
5. 解释 `fmi3ClockUpdateCallback` 的用途，以及 `fmi3GetClock` / `fmi3GetIntervalDecimal` 在 `ClockUpdateMode` 中的角色。
6. 理解 `priority` 属性的语义和抢占（preemption）机制，知道 `fmi3LockPreemptionCallback` / `fmi3UnlockPreemptionCallback` 的用途。
7. 读懂 `scs_synchronous.c` 和 `scs_threaded.c` 两个 Reference 示例，指出它们分别演示了什么。

前两章的接口都有一个共同点：**导入端问「下一步做什么」，FMU 回答**。

- ME：导入端问「导数是多少」，FMU 答。
- CS：导入端问「走 `h` 秒」，FMU 答。

SE 把这个关系翻了过来：

> **SE 的导入端不问了。导入端直接说「这几个模型分区，这一秒你给我算一遍」，FMU 只管执行。**

导入端成了调度器（scheduler）。时间怎么推进、哪个分区先算、要不要抢占、算到哪个时刻，全是导入端的事。FMU 只需要声明：「我有哪些分区，它们由哪些 Clock 触发，各是多少优先级。」

这就是 SE 存在的理由：实时仿真、HIL、控制系统测试里，导入端往往已经有自己的调度器（通常是硬实时的），它需要 FMU 作为一个「可以按需调用的算法集合」，而不是一个「只能按固定步长推进的黑盒」。

---

## 9.1 三种接口的对照

先把三种接口放在一张表里。这是全章最重要的一张表。

| 维度 | Model Exchange | Co-Simulation | Scheduled Execution |
| --- | --- | --- | --- |
| 谁积分 | 导入端 | FMU | 不涉及连续积分 |
| 谁推进时间 | 导入端（`fmi3SetTime`） | 协商（`fmi3DoStep`） | 导入端（调度器） |
| 粒度 | 单个连续状态 | 一个通信步 | 一个模型分区 |
| 离散时间的载体 | 超密集时间（super-dense time） | 事件模式 | **Clock** |
| 关键推进函数 | `fmi3GetContinuousStateDerivatives` | `fmi3DoStep` | `fmi3ActivateModelPartition` |
| FMU 内部结构 | 连续状态 + 事件指示器 | 完整仿真器 | 若干独立模型分区 |
| 是否需要事件模式 | 是 | 可选 | **否** |
| 典型场景 | 需与导入端耦合的模型 | 系统级联合仿真 | 实时仿真、HIL、代码生成 |
| 优先级 | 无 | 无 | **有（`priority`）** |
| 抢占 | 无 | 无 | **有（lock/unlock）** |

三个关键差异值得展开：

**第一，SE 没有 `EventMode`。** 规范 2.3 节明确写着：

> `EventMode` is not available in Scheduled Execution.

为什么？因为 SE 的「事件」就是 Clock 的 tick。导入端不需要「进入事件模式做离散状态迭代」这一套——它只需要在 Clock 激活时调用 `fmi3ActivateModelPartition`。

**第二，SE 没有 `fmi3DoStep`。** 也没有 `fmi3GetContinuousStates`、`fmi3GetEventIndicators`、`fmi3GetOutputDerivatives`。SE 的 FMU 不暴露连续时间状态。

**第三，SE 引入了 `priority` 和抢占。** 这是 ME 和 CS 都没有的。规范 2.4 节：

> This attribute is mandatory for input Clocks in Scheduled Execution. ... Smaller values signal higher priorities.

---

## 9.2 模型分区：SE 的基本单位

### 9.2.1 定义

定义在规范 2.2.8.3 节和术语表里：

> **model partition**：An FMU may consist of several algorithms computing subsets of variables. A model partition is such an algorithm with variables connected to a Clock. The execution of a model partition is triggered by the activation of its Clock.

每个 Clock 对应一个模型分区。数学上：

$$
\begin{align}
(\mathbf{x}_k) &:= \mathbf{f}_{\mathit{disc}}(^\bullet{\mathbf{x}}_k, \mathbf{u}, t) \\
(\mathbf{y}_k) &:= \mathbf{f}_{\mathit{event}}(\mathbf{x}_k, \mathbf{u}, t)
\end{align}
$$

- $\mathbf{f}_\mathit{disc}$：状态转移函数（相当于离散的「积分器」）。
- $\mathbf{f}_\mathit{event}$：输出函数。

$\mathbf{x}_k$ 和 $\mathbf{y}_k$ 里的变量称为 **clocked variables**（时钟变量）。

### 9.2.2 clocked variable 的访问限制

规范 2.2.8.3 节：

> Clocked variables $\mathbf{v}_k$ can acquire new values and can be queried only when their Clock $k$ is active, except during `InitializationMode`.

也就是说，一个变量通过 `clocks="1001"` 关联到某个 Clock 之后：

| 时机 | 能否访问 |
| --- | --- |
| `InitializationMode` | 能（不受 Clock 激活状态限制） |
| Clock $k$ 活跃时 | 能 |
| 其他时刻 | 不能 |

XML 里的关联方式：

```xml
<Int32 name="inClock1Ticks" valueReference="2001" causality="output" clocks="1001"/>
<Int32 name="totalInClockTicks" valueReference="2004" causality="output" clocks="1001 1002 1003"/>
```

第二个变量关联了三个 Clock，说明它由多个模型分区共同更新（典型的共享计数器）。规范建议这种情况下用锁保护（见 9.6 节）。

### 9.2.3 Reference 的 `Clocks` FMU

仓库里的 `examples/reference-fmus/Clocks/` 是唯一一个 SE FMU。它的 `FMI3.xml` 声明了四个 Clock：

```xml
<ScheduledExecution modelIdentifier="Clocks"/>
...
<Clock name="inClock1"  valueReference="1001" causality="input"  intervalVariability="constant" intervalDecimal="1.0" priority="0"/>
<Clock name="inClock2"  valueReference="1002" causality="input"  intervalVariability="triggered" priority="1"/>
<Clock name="inClock3"  valueReference="1003" causality="input"  intervalVariability="countdown" priority="2" clocks="1001"/>
<Clock name="outClock"  valueReference="1005" causality="output" intervalVariability="triggered" clocks="1001 1002 1003"/>
```

对应的三个模型分区在 `examples/reference-fmus/Clocks/model.c`：

```c
static void activateModelPartition1(ModelInstance* comp, double time) {
    /* Note: model partition of highest priority
        -> no interruption by other model partitions possible
        -> no lock preemption needed
    */
    M(inClock1Ticks)++;
    M(totalInClockTicks)++;

    if ((int)time == 4) {
        M(inClock3_qualifier) = 2;   // fmi3IntervalChanged
        M(inClock3_interval) = 0.0;
    }

    M(outClock) = ((M(outClock) == false) && (M(totalInClockTicks) % 5 == 0));

    if (M(inClock3_qualifier) == 2 || M(outClock)) {
        comp->clockUpdate(comp->componentEnvironment);
    }
}
```

三个分区做三件事：

- **分区 1**（`inClock1`，优先级 0，最高）：累加 `inClock1Ticks` 和 `totalInClockTicks`；在 `time == 4` 时为 countdown Clock `inClock3` 设置间隔并通知导入端。
- **分区 2**（`inClock2`，优先级 1）：累加计数器，读取并清零输入 `input2`。
- **分区 3**（`inClock3`，优先级 2，最低）：累加计数器，**故意烧掉大量 CPU 时间**（1e9 次循环），然后写 `output3`。

分区 3 的存在是为了演示**抢占**：它是低优先级的「慢任务」，应当被高优先级任务打断。

`examples/reference-fmus/Clocks/FMI3.xml` 末尾的注释给出了这个模型预期的时间线：

```text
time        0 1 2 3 4 5 6 7 8 9
inClock1    + + + + + + + + + +   input,  triggered by the simulation algorithm every second
inClock2    + +             + +   input,  triggered by the simulation algorithm at 0, 1, 8 and 9
inClock3            +             input,  triggered by inClock1
outClock    ? ? ? ? ? ? ? ? ? ?   output, triggered by all inClocks (if totalInTicks % 5 == 0)
```

---

## 9.3 Clock 分类复习

第 8 章 8.8 节已经讲过 Clock 的分类，这里按 SE 的视角重新组织，因为 SE 把这些类型用得更狠。

### 9.3.1 总表

规范 2.2.8.1 节的表格按 `causality` × `intervalVariability` 分类。SE 关心的是「导入端怎么知道什么时候该激活」。

| `causality` | `intervalVariability` | 类型 | 谁决定 tick 时刻 | SE 中的调度方式 |
| --- | --- | --- | --- | --- |
| `input` | `constant` | 常量周期 | XML 的 `intervalDecimal` | 导入端按固定周期排程 |
| `input` | `fixed` | 固定周期 | 导入端设置 / FMU 查询 | 导入端设置间隔后排程 |
| `input` | `tunable` | 可调周期 | 导入端，可在运行时改 | 排程 + 运行时重新排程 |
| `input` | `changing` | 变化非周期 | FMU（每次 tick 后才知道下次） | 运行时用 `fmi3GetInterval` 更新排程 |
| `input` | `countdown` | 倒计时非周期 | FMU（提前告知） | 运行时用 `fmi3GetInterval` 更新排程 |
| `input` | `triggered` | 触发式（input） | 导入端（硬件事件等） | 导入端任意时刻激活 |
| `output` | `triggered` | 触发式（output） | FMU | FMU 通过 `fmi3ClockUpdateCallback` 通知 |
| `local` | `triggered` | 本地触发式 | FMU | **SE 中不允许** |

### 9.3.2 `constant` / `fixed` / `tunable` 的区别

三者都是周期 Clock，tick 公式相同：

$$
t_0 = t_{\mathit{start}} + T_{\mathit{shift}}, \qquad t_i = t_{i-1} + T_{\mathit{interval}, i}
$$

区别在于**谁能改间隔**：

| 类型 | `fmi3SetInterval` | `fmi3GetInterval` | 运行时可改？ |
| --- | --- | --- | --- |
| `constant` | 不需要 | `InitializationMode` | 不可改 |
| `fixed` | `InitializationMode`（若 XML 给了 `intervalDecimal` 则不调用） | `InitializationMode`（若 XML 没给） | 不可改 |
| `tunable` | `InitializationMode`；之后可在 `EventMode` / `ClockActivationMode` 调用 | 同上 | **可以** |

`fixed` 和 `tunable` 的差别只有一处：间隔是否依赖 `tunable` 参数。

> 规范细节：`tunable` 周期 Clock 的 shift 只能依赖 `fixed` 参数，所以 shift 只能在初始化时设置/查询。

### 9.3.3 `countdown` 与 `changing` 的区别

两者都是非周期 Clock，`fmi3GetShift` / `fmi3SetShift` 都不允许调用。区别在「 FMU 什么时候知道下一次 tick」：

- **`changing`（变化非周期）**：Clock 刚 tick 完，下一个间隔就**已经确定**了。规范要求导入端在 `InitializationMode` 查一次，之后在每次该 Clock 激活过的 `EventMode` / `ClockActivationMode` 再查一次。
- **`countdown`（倒计时非周期）**：Clock 刚 tick 完时，下一个间隔**还不知道**。所以导入端必须在 `InitializationMode`、每个 `EventMode`、每个 `ClockUpdateMode` 都查。

这个区别在 SE 里非常关键，因为 `countdown` Clock 的模型分区可能**暂时无法排程**。规范 2.2.8.1 节的表格对 `countdown` 有一句专门的说明：

> In Scheduled Execution the FMU must inform the importer by calling `fmi3ClockUpdateCallback` that the Clock is about to tick.

对比 `changing` 就没有这句。

### 9.3.4 `qualifiers`：告诉导入端「现在能不能排程」

`fmi3GetIntervalDecimal` / `fmi3GetIntervalFraction` 的 `qualifiers` 输出是 SE 调度器的核心输入。

```c
typedef enum {
    fmi3IntervalNotYetKnown,   /* = 0 */
    fmi3IntervalUnchanged,     /* = 1 */
    fmi3IntervalChanged        /* = 2 */
} fmi3IntervalQualifier;
```

| 值 | 含义 | SE 中的动作 |
| --- | --- | --- |
| `fmi3IntervalNotYetKnown` | 下次间隔还不知道 | **对应的模型分区暂时不能排程** |
| `fmi3IntervalUnchanged` | 和上次一样 | 已经排过程序了，保持原排程 |
| `fmi3IntervalChanged` | 间隔变了 | **重新排程**该模型分区 |

规范原话（2.2.8.1 节）：

> `fmi3IntervalChanged` ... In Scheduled Execution this means that the corresponding model partition must be scheduled or re-scheduled.
>
> `fmi3IntervalUnchanged` ... In Scheduled Execution this means that the corresponding model partition has already been scheduled.
>
> `fmi3IntervalNotYetKnown` ... In Scheduled Execution this return value means that the corresponding model partition cannot be scheduled yet.

> **注意枚举值的顺序**：`NotYetKnown = 0`、`Unchanged = 1`、`Changed = 2`。Reference 的 `Clocks/model.c` 直接用数字 `2` 表示 `fmi3IntervalChanged`。

---

## 9.4 SE 的状态机

### 9.4.1 主路径

```text
fmi3InstantiateScheduledExecution 返回非 NULL
        │
        ▼
   Instantiated
        │ fmi3EnterInitializationMode
        ▼
 InitializationMode
        │ 设置参数、初始值、Clock 的 interval/shift
        │ fmi3ExitInitializationMode
        ▼
 ClockActivationMode ◀────────────────────────────┐
        │                                          │
        │ fmi3ActivateModelPartition(clock, t)     │
        │                                          │
        │ FMU 内部调用 fmi3ClockUpdateCallback     │
        ▼                                          │
  ClockUpdateMode ────────────────────────────────┘
        │ 导入端在回调里调用
        │ fmi3GetClock / fmi3GetIntervalDecimal
        │
        │ （回到 ClockActivationMode）
        ▼
 ClockActivationMode
        │
        │ fmi3Terminate
        ▼
   Terminated
        │ fmi3FreeInstance
        ▼
   （实例释放）
```

和第 6 章的公共状态机对照：

| 状态 | ME | CS | SE |
| --- | --- | --- | --- |
| `EventMode` | ✅ | ✅（可选） | ❌ |
| `ContinuousTimeMode` | ✅ | ❌ | ❌ |
| `StepMode` | ❌ | ✅ | ❌ |
| `IntermediateUpdateMode` | ❌ | ✅（可选） | ❌ |
| `ClockActivationMode` | ❌ | ❌ | ✅ |
| `ClockUpdateMode` | ❌ | ❌ | ✅ |

`fmi3ExitInitializationMode` 之后，ME 进 `EventMode`，CS 进 `EventMode` 或 `StepMode`，SE 进 `ClockActivationMode`。Reference 的实现就是这么分的：

```c
switch (S->type) {
    case ModelExchange:
        S->state = EventMode;
        break;
    case CoSimulation:
        S->state = S->eventModeUsed ? EventMode : StepMode;
        break;
    case ScheduledExecution:
        S->state = ClockActivationMode;
        break;
}
```

### 9.4.2 ClockActivationMode

这是 SE 的主状态。规范 5.2 节允许的调用：

| 操作 | 说明 |
| --- | --- |
| `fmi3Set{VariableTypeExclClock}` | 设置 `input` 和 `tunable` 参数 |
| `fmi3Get{VariableTypeExclClock}` | 读取属于该模型分区的变量和不属于任何 Clock 的变量 |
| `fmi3ActivateModelPartition` | **核心**：激活一个模型分区 |
| `fmi3GetIntervalDecimal` / `fmi3GetIntervalFraction` | 仅对 `tunable` 和 `changing` aperiodic Clock |
| `fmi3GetDirectionalDerivative` / `fmi3GetAdjointDerivative` | 通用 |

规范特别强调了一条**顺序规则**：

> It is not allowed to call `fmi3Get{VariableTypeExclClock}` functions after `fmi3Set{VariableTypeExclClock}` functions without an `fmi3ActivateModelPartition` call in between.
>
> _[It is recommended, to call `fmi3Set{VariableTypeExclClock}`, `fmi3ActivateModelPartition` and `fmi3Get{VariableTypeExclClock}` in a sequence.]_

规范给出理由：

> ...contrary to Model Exchange, `fmi3ActivateModelPartition` will perform the actual calculation instead of `fmi3Get{VariableTypeExclClock}`, and therefore, algebraic loops at communication points cannot be handled by an appropriate sequence of `fmi3Get{VariableTypeExclClock}` and `fmi3Set{VariableTypeExclClock}` calls as for Model Exchange.

换句话说：**在 SE 里，「读变量」不触发计算，「激活分区」才触发计算。**

这和 ME 正好相反：ME 里的 `fmi3Get{VariableType}` 会触发计算（有 selective computation 机制）。SE 里，计算被显式地从读取中拆出来了，因为所有「耗时的计算」必须集中在 `fmi3ActivateModelPartition` 内部——这对实时性至关重要：

> Because of real-time constraints, the computational effort has to be predictable for all operations in Scheduled Execution. Therefore, all computationally expensive operations to compute a model partition have to be contained within the `fmi3ActivateModelPartition` function.

### 9.4.3 ClockUpdateMode

`ClockUpdateMode` 是 SE 独有的状态，由 **FMU 主动进入**：FMU 在执行一个模型分区的过程中调用 `fmi3ClockUpdateCallback`，状态就切到 `ClockUpdateMode`。

```c
typedef void (*fmi3ClockUpdateCallback) (
    fmi3InstanceEnvironment instanceEnvironment);
```

回调参数只有一个：实例化时传入的上下文指针。

`ClockUpdateMode` 里允许的调用：

| 操作 | 用途 |
| --- | --- |
| `fmi3GetClock` | 查询哪个 triggered output Clock 刚 tick 了 |
| `fmi3GetIntervalDecimal` / `fmi3GetIntervalFraction` | 查询 `countdown` Clock 的新间隔 |

规范对 `fmi3GetClock` 有个重要细节：

> For an `outputClock` only the first call of `fmi3GetClock` for a specific activation of this Clock signals `fmi3ClockActive`. The FMU sets the reported activation state immediately back to `fmi3ClockInactive` for following `fmi3GetClock` calls for that Clock until this outputClock is activated again.

也就是说，**output Clock 的 tick 状态是「一次性」的**：读第一次返回 `fmi3ClockActive`，再读就变回 `fmi3ClockInactive`。FMU 自己负责在读之后清零。

这个设计是为了避免导入端漏掉一次 tick：FMU 内部保持一个「有没有未读 tick」的标志。

### 9.4.4 SE 中禁止的调用

| 函数 | 原因 |
| --- | --- |
| `fmi3SetClock` | 规范明确：「`fmi3SetClock` must not be called in Scheduled Execution, instead `fmi3ActivateModelPartition` must be called.」 |
| `fmi3GetContinuousStates` | SE 不暴露连续状态 |
| `fmi3GetContinuousStateDerivatives` | 同上 |
| `fmi3GetEventIndicators` | 同上 |
| `fmi3GetOutputDerivatives` | 同上 |
| `fmi3GetNominalsOfContinuousStates` | 同上 |
| `fmi3EnterEventMode` | SE 没有 `EventMode` |
| `fmi3UpdateDiscreteStates` | SE 没有 `EventMode` |
| `fmi3GetFMUState` / `fmi3SetFMUState` 等 | **当有模型分区正在执行或被抢占时禁止** |

最后一条值得单独强调。规范 5.2 节：

> Functions `fmi3GetFMUState`, `fmi3SetFMUState`, `fmi3FreeFMUState`, `fmi3SerializedFMUStateSize`, `fmi3SerializeFMUState`, `fmi3DeserializeFMUState`: These functions must not be called if any model partition is currently active or preempted. _[This is because these functions apply to the whole FMU and not only to a specific model partition.]_

这些函数作用于整个 FMU，而模型分区可能正在并行运行。读写它们会破坏一致性。

### 9.4.5 `fmi3Discard` 在 SE 中的特殊含义

规范 5.2 节：

> State changes are global to all model partitions, except to and from `ClockUpdateMode`. E.g. if any function call returns `fmi3Discard` or `fmi3Error`, all active or preempted model partitions are in the same state.
>
> **In Scheduled Execution, `fmi3Discard` must be treated like `fmi3Error`.**

这是 SE 和 CS 的一个重要差别。CS 里 `fmi3Discard` 表示「这一步可以重试」；SE 里不能重试——因为模型分区可能已经有别的在跑，重试的状态基准已经变了。所以导入端必须把它当致命错误处理。

---

## 9.5 `fmi3ActivateModelPartition`

### 9.5.1 签名

```c
typedef fmi3Status fmi3ActivateModelPartitionTYPE(fmi3Instance instance,
                                                  fmi3ValueReference clockReference,
                                                  fmi3Float64 activationTime);
```

只有三个参数，非常简单：

| 参数 | 含义 |
| --- | --- |
| `clockReference` | 要激活的模型分区关联的 **input Clock** 的 value reference |
| `activationTime` | 该 Clock tick 的时间 $t_i$ |

### 9.5.2 三条硬约束

规范 5.2 节原文：

1. **`fmi3ActivateModelPartition` must only be called once for the same Clock and time.**
   同一个 Clock 在同一个时间点只能激活一次。不能重复调用。

2. **`fmi3ActivateModelPartition` must not be called on output Clocks of an FMU.**
   只能对 input Clock 调用。output Clock 的激活是 FMU 通过回调报告的，不是导入端触发的。

3. **Consecutive calls to `fmi3ActivateModelPartition` for a `clockReference` must have strictly monotonically increasing `activationTime`.**
   同一个 Clock 的连续激活时间必须严格单调递增。

### 9.5.3 这个函数会做计算

规范的加注很关键：

> _[Note, that other than `fmi3DoStep` for Co-Simulation, `fmi3ActivateModelPartition` will compute the variables of the model partition for the current `activationTime`.]_

对比一下：

| | 推进函数 | 是否计算 |
| --- | --- | --- |
| CS | `fmi3DoStep` | ✅ 计算到通信点末端 |
| SE | `fmi3ActivateModelPartition` | ✅ 计算该模型分区 |
| ME | `fmi3GetContinuousStateDerivatives` | 只算导数，状态由导入端更新 |

SE 是「调用即计算」。所以 `fmi3Get{VariableTypeExclClock}` 只是读已经算好的值。

### 9.5.4 SE 的调用序列

```c
fmi3Instance fmi3InstantiateScheduledExecution(
    fmi3String                     instanceName,
    fmi3String                     instantiationToken,
    fmi3String                     resourcePath,
    fmi3Boolean                    visible,
    fmi3Boolean                    loggingOn,
    fmi3InstanceEnvironment        instanceEnvironment,
    fmi3LogMessageCallback         logMessage,
    fmi3ClockUpdateCallback        clockUpdate,
    fmi3LockPreemptionCallback     lockPreemption,
    fmi3UnlockPreemptionCallback   unlockPreemption);
```

和前两个接口相比，SE 的实例化多了三个回调：

| 回调 | 作用 |
| --- | --- |
| `clockUpdate` | FMU 通知「我要 tick 了 / 我的 countdown 间隔变了」 |
| `lockPreemption` | 导入端加锁，阻止当前分区被抢占 |
| `unlockPreemption` | 解锁 |

注意 SE **没有** `eventModeUsed`、`earlyReturnAllowed`、`requiredIntermediateVariables` 这几个参数——SE 概念里没有「早期返回」也没有「中间更新」。

完整序列：

| 步骤 | 调用 | 说明 |
| --- | --- | --- |
| 1 | `fmi3InstantiateScheduledExecution` | 必需 |
| 2 | `fmi3EnterInitializationMode` | 必需 |
| 3 | `fmi3Set{VariableType}` / `fmi3Get{VariableType}` | 设置初始值、参数、查询 Clock 的 interval/shift |
| 4 | `fmi3ExitInitializationMode` | 进入 `ClockActivationMode` |
| 5 | `fmi3Set{VariableTypeExclClock}` | 设置该分区的输入（可选） |
| 6 | `fmi3ActivateModelPartition` | **核心** |
| 7 | `fmi3Get{VariableTypeExclClock}` | 读取该分区的输出（可选） |
| 8 | `fmi3Terminate` | 结束 |
| 9 | `fmi3FreeInstance` | 释放 |

---

## 9.6 优先级与抢占

### 9.6.1 priority 属性

规范 2.4 节：

> This attribute is mandatory for input Clocks in Scheduled Execution. For Co-Simulation and Model Exchange, this attribute must be ignored. Output Clocks must not have this attribute. **Smaller values signal higher priorities.** Clocks that have to be activated at the same time instant are ordered according to this attribute. For multiple Clocks with the same priority the order is undefined.

要点：

- **SE 的 input Clock 必须有 `priority`**（其它接口类型是可选的）。
- **数值越小，优先级越高。**
- **同一时刻激活的 Clock 按 priority 排序。**
- **相同 priority 的顺序未定义。** 导入端可以自己决定，但不要依赖。

Reference 的 `Clocks` FMU：

```xml
<Clock name="inClock1" valueReference="1001" ... priority="0"/>   <!-- 最高 -->
<Clock name="inClock2" valueReference="1002" ... priority="1"/>
<Clock name="inClock3" valueReference="1003" ... priority="2"/>   <!-- 最低 -->
```

### 9.6.2 优先级是 FMU 局部的

规范 5.1 节明确：

> _[The Clock priorities are local to an FMU. It is not possible for an FMU exporting tool to know in advance the priorities of other FMUs that will be connected to an FMU in a simulation setup. It is the responsibility of the importer to derive a computational order for the computation of two or distinct FMUs based on the local FMU Clock priorities and input-output relationships of connected FMUs.]_

也就是说，`priority = 0` 在 FMU A 里和在 FMU B 里毫无关系。跨 FMU 的顺序必须由导入端根据数据流推导。

规范还给了一个推荐做法：

> _[For periodic Clocks it is recommended to derive the priorities based on a rate monotonic scheduling scheme (smallest period leads to highest priority, that is, has the smallest priority value.]_

周期越短，优先级越高。这和实时系统里的 RMS（rate monotonic scheduling）一致。

### 9.6.3 抢占

规范 5.1.2 节：

> If a model partition of lower priority is executed when a model partition of higher priority is activated, the scheduler must ensure that the execution of the latter one is not delayed and causing violations of timing constraints.
>
> Preemption support means that the scheduler can immediately interrupt the current execution of a model partition in order to execute a model partition of higher priority. The computation of the interrupted model partition is proceeded afterwards.

抢占规则：

| 情况 | 行为 |
| --- | --- |
| 更高优先级的分区被激活 | **抢占**当前低优先级分区，立即执行高优先级 |
| 相同优先级的分区被激活 | **不抢占**，由调度器决定顺序 |

### 9.6.4 FMU 如何保护自己

抢占意味着 FMU 的代码可能在任意点被中断。FMU 需要保证数据结构的一致性。规范提供了两个回调：

```c
typedef void (*fmi3LockPreemptionCallback)   (void);
typedef void (*fmi3UnlockPreemptionCallback) (void);
```

FMU 在关键代码段前后调用它们。

规范列出**可能被抢占的函数**，FMU 必须能正确处理：

- `fmi3ActivateModelPartition`
- `fmi3Get{VariableType}`
- `fmi3Set{VariableType}`
- `fmi3GetClock`
- `fmi3GetIntervalDecimal`

规范还提醒了成本：

> _[Note that depending on their implementation, `fmi3CallbackLockPreemption` and `fmi3CallbackUnlockPreemption` have a non-negligible overhead, as well as a strong impact on the scheduler and therefore their use should be as rare and short as possible. In general it is recommended to reduce dependencies between different model partitions of one FMU by design.]_

以及一个可以偷懒的观察：

> _[One may also consider if the code can be preempted by other parts of the same FMU: E.g. a model partition cannot be interrupted if it is the only model partition or if it holds the highest priority. Similarly, a model partition, while it might be interrupted, might not need to guard data accesses if it is the only model partition of the FMU, or the one with the highest priority. In such cases no locks may be necessary.]_

Reference 的 `Clocks/model.c` 正好演示了这两种情况：

```c
static void activateModelPartition1(ModelInstance* comp, double time) {
    /* Note: model partition of highest priority
        -> no interruption by other model partitions possible
        -> no lock preemption needed
    */
    ...
    /* 没有 lockPreemption 调用 */
}

static void activateModelPartition2(ModelInstance* comp, double time) {
    if (comp->lockPreemption) { comp->lockPreemption(); }
    M(inClock2Ticks)++;
    M(totalInClockTicks)++;
    M(result2) += M(input2);
    M(input2) = 0;
    M(outClock) = ((M(outClock) == false) && (M(totalInClockTicks) % 5 == 0));
    if (comp->unlockPreemption) { comp->unlockPreemption(); }
    ...
}
```

分区 1 优先级最高，不可能被抢占，所以不用锁。分区 2 和分区 3 优先级较低，会被抢占，所以加了锁。

> 注意：分区 2 在 `unlockPreemption` **之后**才调用 `comp->clockUpdate(...)`，把 `M(outClock)` 的检查放在锁外面——这是有意的，因为 `clockUpdate` 可能触发导入端调度其他分区，如果还持有锁就会死锁。

---

## 9.7 `fmi3ClockUpdateCallback`：FMU 主动报告

### 9.7.1 两种触发场景

规范 5.2 节：

> During the computation of a model partition of an input Clock, the FMU may inform the importer that an output Clock ticked or a countdown Clock is about to tick by changing to `ClockUpdateMode` calling `fmi3ClockUpdateCallback`.
>
> The importer may then activate potential sinks (e.g. a model partition of another FMU) connected to this output Clock or must activate the model partition of the respective countdown Clock.

翻译成两种用法：

1. **triggered output Clock 刚 tick 了** → 导入端去问 `fmi3GetClock`，发现哪个 output Clock 活跃，然后调度它的下游。
2. **countdown Clock 快要 tick 了** → 导入端去问 `fmi3GetIntervalDecimal`，拿到新间隔，然后排程该模型分区。

### 9.7.2 参考实现：`ThreeInputClocks`

规范 5.3 节给的导入端例子（`docs/spec-3.0.2/adoc/examples/snippets.c`）：

```c
/* tag::SE_sa_clockUpdate[] */
void CallbackClockUpdate(fmi3InstanceEnvironment instanceEnvironment) {
    fmi3Float64 interval[] = { 0.0 };
    fmi3IntervalQualifier intervalQualifier[] = { fmi3IntervalNotYetKnown };

    // ask FMU if countdown clock AperiodicClock is about to tick
    const fmi3ValueReference aperiodicClockReferences[] = { 6 };
    fmi3GetIntervalDecimal(fmu, aperiodicClockReferences, 1, interval, intervalQualifier);
    if (intervalQualifier[0] == fmi3IntervalChanged) {
        // schedule task for AperiodicClock with a delay
        ScheduleAperiodicTask(interval[0]);
    }
    // ask FMU if OutputClock has ticked
    fmi3ValueReference outputClockReferences[] = { 7 };
    fmi3Boolean clockActivationStates[] = { fmi3ClockInactive };
    fmi3GetClock(fmu, outputClockReferences, 1, clockActivationStates);
    if (clockActivationStates[0]) {
        // schedule some external task
        ScheduleExternalTask();
    }
}
/* end::SE_sa_clockUpdate[] */
```

这是**标准模式**：

```text
FMU 调用 clockUpdate 回调
        │
        ▼
导入端在回调里：
   1. fmi3GetIntervalDecimal → 拿到 countdown Clock 的新间隔
      → qualifier == Changed ? 排程对应模型分区 : 不动
   2. fmi3GetClock → 看哪个 output Clock 刚 tick
      → 有活跃的 ? 调度它的下游 : 不动
```

### 9.7.3 FMU 侧的实现

规范 5.3 节的 FMU 侧例子：

```c
/* tag::SE_fmu_getIntervalDecimal[] */
fmi3Status fmi3GetIntervalDecimal(fmi3Instance instance,
                                  const fmi3ValueReference valueReferences[],
                                  size_t nValueReferences,
                                  fmi3Float64 interval[],
                                  fmi3IntervalQualifier qualifier[]) {
    ModelInstance * inst = (ModelInstance *) instance;

    for (int i = 0; i < nValueReferences; i++) {
        switch (valueReferences[i]) {
        case 5:    // Input clock 10msClock
            interval[i] = 0.01;
            qualifier[i] = fmi3IntervalUnchanged;
            break;
        case 6:    // Input clock AperiodicClock
            env->lockPreemption(); // Optional: Preventing preemption is actually not needed here.
            interval[i] = inst->CountdownClockInterval;
            qualifier[i] = inst->CountdownClockQualifier;
            if (inst->CountdownClockQualifier == fmi3IntervalChanged) {
                inst->CountdownClockQualifier = fmi3IntervalUnchanged;
            }
            env->unlockPreemption();
            break;
        ...
```

三个要点：

1. **`Changed` 是一次性的**：读过一次就降级成 `Unchanged`。这样导入端不会重复排程。
2. **`NotYetKnown` 在激活后重置**：另一个例子 `SE_fmu_activateMPAperiodic` 里：

```c
void activateModelPartitionAperiodic(fmi3Instance instance, fmi3Float64 activationTime) {
    ModelInstance* inst = (ModelInstance*)instance;
    inst->CountdownClockQualifier = fmi3IntervalNotYetKnown;
    // ...
}
```

countdown Clock 的模型分区一旦被激活，间隔就重新变成「未知」，等待 FMU 下次通知。

3. **锁是可选的**：如果只有一个模型分区会调用那个回调，就不需要锁。

Reference 的 `Clocks/model.c` 用的是同一套模式，只是更简洁：

```c
Status getInterval(ModelInstance* comp, ValueReference vr, double* interval, int* qualifier) {
    switch (vr) {
    case vr_inClock3:
        *qualifier = M(inClock3_qualifier);
        if (*qualifier == 2) {                  // fmi3IntervalChanged
            *interval = M(inClock3_interval);
            M(inClock3_qualifier) = 1;          // fmi3IntervalUnchanged
        }
        return OK;
```

注意这里 `M(inClock3_qualifier)` 只有两个状态：`1`（Unchanged）和 `2`（Changed）。**Reference 的 `Clocks` FMU 从不返回 `NotYetKnown`**——它的 `inClock3` 只在 `time == 4` 时被设置一次，之后就是 `Unchanged`。

> 这不是规范要求。规范希望 countdown Clock 在「间隔未知」时明确返回 `NotYetKnown`，让导入端知道分区暂时无法排程。Reference 的实现简化成了「一次性事件」：只在 `t = 4` 报一次 `Changed`，之后永远 `Unchanged`。对教学演示足够，但不够严谨。

4. **`Changed` 的降级和读取是原子的**：Reference 的写法是「读到 `Changed` 的同时把它改成 `Unchanged`」，这一段没有加锁——因为在 `Clocks` 里只有分区 1 会调用 `clockUpdate`，不会并发。规范 5.3 节的例子在这个位置加了 `env->lockPreemption()`，并注明「Optional: Preventing preemption is actually not needed here」。

### 9.7.4 output Clock 也是一次性的

```c
/* tag::SE_fmu_getClock[] */
fmi3Status fmi3GetClock(fmi3Instance instance,
                        const fmi3ValueReference valueReferences[],
                        size_t nValueReferences,
                        fmi3Clock values[]) {
    ModelInstance * inst = (ModelInstance *) instance;

    for (int i = 0; i < nValueReferences; i++) {
        switch (valueReferences[i]) {
        case 7:    // OutputClock
            env->lockPreemption();
            values[i] = inst->OutputClockTicked;
            inst->OutputClockTicked = fmi3ClockInactive;
            env->unlockPreemption();
            break;
```

读一次就清零。同 `Clocks/model.c` 里的 `getClock`：

```c
Status getClock(ModelInstance* comp, ValueReference vr, _Bool *value) {
    switch (vr) {
    case vr_outClock:
        *value = M(outClock);
        M(outClock) = false;
        return OK;
```

---

## 9.8 逐段读 `scs_synchronous.c`

这是 Reference 提供的同步（单线程）SE 示例，完整代码只有 71 行。

### 9.8.1 全局变量（第 9–14 行）

```c
fmi3Float64 countdownClockIntervals[1] = { 0.0 };
fmi3IntervalQualifier countdownClocksQualifier[1] = { fmi3IntervalNotYetKnown };
fmi3ValueReference vr_countdownClocks[1] = { vr_inClock3 };
fmi3ValueReference outClockVRs[1] = { vr_outClock };
fmi3Clock outClockValues[2];
```

这几个变量是导入端调度状态的「影子副本」：导入端从 FMU 那里读到 Clock 状态后，记在这里。

### 9.8.2 `cb_clockUpdate` 回调（第 16–22 行）

```c
static void cb_clockUpdate(fmi3InstanceEnvironment instanceEnvironment) {
    countdownClockIntervals[0] = 0.0;
    countdownClocksQualifier[0] = fmi3IntervalNotYetKnown;
    FMI3GetIntervalDecimal(S, vr_countdownClocks, 1, countdownClockIntervals, countdownClocksQualifier);
}
```

这个回调**只查 countdown Clock**，不查 output Clock。对比规范 5.3 的完整例子，它少了一半。

不过因为主循环每轮都无条件调用 `FMI3GetClock`，output Clock 的 tick 也不会漏——只是时机从「回调里立刻响应」变成「下一轮循环才发现」。

还有一个小细节值得注意：回调里先把 `countdownClocksQualifier[0]` 重置成 `fmi3IntervalNotYetKnown`，**然后**才调用 `FMI3GetIntervalDecimal`。这个重置会被 FMU 的返回值覆盖，所以实际上是「防御性初始化」——万一 FMU 没写这个输出，导入端至少不会读到上一次残留的 `Changed` 而重复排程。

而规范 5.3 的例子里的初始化值是 `fmi3IntervalNotYetKnown`，Reference 例子里也是。两者一致。

### 9.8.3 实例化（第 27–37 行）

```c
CALL(FMI3InstantiateScheduledExecution(S,
    INSTANTIATION_TOKEN,   // instantiationToken
    NULL,                  // resourceLocation
    fmi3False,             // visible
    fmi3False,             // loggingOn
    NULL,                  // requiredIntermediateVariables
    0,                     // nRequiredIntermediateVariables
    cb_clockUpdate,        // clockUpdate
    NULL,                  // lockPreemption
    NULL                   // unlockPreemption
));
```

这里的**参数个数是对的**（10 个，和规范一致），但**行尾注释是错的**。

规范的 `fmi3InstantiateScheduledExecutionTYPE` 是 10 个参数，**没有** `requiredIntermediateVariables` 和 `nRequiredIntermediateVariables`：

```c
typedef fmi3Instance fmi3InstantiateScheduledExecutionTYPE(
    fmi3String                     instanceName,
    fmi3String                     instantiationToken,
    fmi3String                     resourcePath,
    fmi3Boolean                    visible,
    fmi3Boolean                    loggingOn,
    fmi3InstanceEnvironment        instanceEnvironment,
    fmi3LogMessageCallback         logMessage,
    fmi3ClockUpdateCallback        clockUpdate,
    fmi3LockPreemptionCallback     lockPreemption,
    fmi3UnlockPreemptionCallback   unlockPreemption);
```

Reference 的实现（`examples/reference-fmus/src/fmi3Functions.c`）也是这 10 个。示例里那两行注释：

```c
    NULL,                  // requiredIntermediateVariables
    0,                     // nRequiredIntermediateVariables
```

是从 `simulate_fmi3_cs.c`（CS 的实例化）**复制粘贴**过来的，忘了改。实际对应的是：

| 位置 | 注释写的 | 实际是 |
| --- | --- | --- |
| 6 | `requiredIntermediateVariables` | `instanceEnvironment` |
| 7 | `nRequiredIntermediateVariables` | `logMessage` |

所以 `NULL` 传给了 `instanceEnvironment`，`0` 传给了 `logMessage`。

>`0` 作为 `fmi3LogMessageCallback`（函数指针）的值在 C 里等价于 `NULL`，所以编译能过。

### 9.8.4 `FMI3.h` 的包装函数

示例并不直接调用 C API，而是通过 `examples/reference-fmus/include/FMI3.h` 的包装层。包装层的签名把 `instanceName` 换成了 `FMIInstance *instance`：

```c
FMI_STATIC FMIStatus FMI3InstantiateScheduledExecution(
    FMIInstance                   *instance,
    fmi3String                     instantiationToken,
    fmi3String                     resourcePath,
    fmi3Boolean                    visible,
    fmi3Boolean                    loggingOn,
    fmi3InstanceEnvironment        instanceEnvironment,
    fmi3LogMessageCallback         logMessage,
    fmi3ClockUpdateCallback        clockUpdate,
    fmi3LockPreemptionCallback     lockPreemption,
    fmi3UnlockPreemptionCallback   unlockPreemption);
```

包装层的实现在 `examples/reference-fmus/src/FMI3.c`：

```c
FMIStatus FMI3InstantiateScheduledExecution(
    FMIInstance                   *instance,
    ...
    fmi3UnlockPreemptionCallback   unlockPreemption) {

    if (loadSymbols3(instance) != FMIOK) {
        return FMIError;
    }

    fmi3LogMessageCallback _logMessage = instance->logMessage ? cb_logMessage3 : NULL;

    instance->component = instance->fmi3Functions->fmi3InstantiateScheduledExecution(
        instance->name,          // instanceName 由包装层补上
        instantiationToken,
        resourcePath,
        visible,
        loggingOn,
        instance,                // instanceEnvironment 固定传包装层自己
        _logMessage,             // logMessage 也由包装层决定
        clockUpdate,
        lockPreemption,
        unlockPreemption);
```

注意两件事：

1. **`instanceName` 被包装层补上了**（`instance->name`，即 `"instance1"`）。所以示例里不需要传。
2. **`instanceEnvironment` 和 `logMessage` 被包装层覆盖**了。示例传什么无所谓——包装层会传自己的 `instance` 指针和统一的日志回调。

这解释了为什么示例里那两行错误的注释没有造成实际问题：就算 `scs_synchronous.c` 里写的是 `NULL, 0`，包装层也会替换掉它们。

> **教学价值**：这是一个「注释错了但代码是对的」的典型案例。读 Reference 代码时，**以函数签名为准，不要以行尾注释为准**。这一点在实验 5 里会用命令行验证。

### 9.8.5 主循环（第 40–68 行）

```c
CALL(FMI3EnterInitializationMode(S, fmi3False, 0, 0, fmi3False, 0));
CALL(FMI3ExitInitializationMode(S));

int time = 0;

// simulation loop
while (time < 10) {

    // Model Partition 1 is active every second
    CALL(FMI3ActivateModelPartition(S, vr_inClock1, time));

    // Model Partition 2 is active at 0, 1, 8, and 9
    if (time % 8 == 0 || (time - 1) % 8 == 0) {
        CALL(FMI3ActivateModelPartition(S, vr_inClock2, time));
    }

    if (countdownClocksQualifier[0] == fmi3IntervalChanged) {
        CALL(FMI3ActivateModelPartition(S, vr_inClock3, time));
        countdownClocksQualifier[0] = fmi3IntervalUnchanged;
    }

    CALL(FMI3GetClock(S, outClockVRs, 1, outClockValues));

    CALL(recordVariables(S, time, outputFile));

    time++;
}
```

这个循环就是一个**最小调度器**：

| 步骤 | 对应什么 |
| --- | --- |
| 无条件激活 `inClock1` | `constancy` 时钟，周期 1 s |
| 条件激活 `inClock2` | `triggered` 时钟，由导入端自行决定（这里模拟 0、1、8、9） |
| 条件激活 `inClock3` | `countdown` 时钟，只有 FMU 报了 `IntervalChanged` 才激活 |
| `fmi3GetClock` | 查询 output Clock 状态 |
| 记录变量 | |

注意 `time` 是 `int`，`activationTime` 也是整数时间（1 秒一步）。SE 允许这样——`activationTime` 的单位是独立变量的单位，FMU 不在乎。

### 9.8.6 观察到的时序

`scs_synchronous.exe` 的输出（`scs_synchronous_out.csv`）：

```text
time,inClock1Ticks,inClock2Ticks,inClock3Ticks,totalInClockTicks
0,1,1,0,2
1,2,2,0,4
2,3,2,0,5
3,4,2,0,6
4,5,2,1,8
5,6,2,1,9
6,7,2,1,10
7,8,2,1,11
8,9,3,1,13
9,10,4,1,15
```

对照 `FMI3.xml` 的预期时间线：

| t | `inClock1` | `inClock2` | `inClock3` | `total` | 解释 |
| --- | --- | --- | --- | --- | --- |
| 0 | ✓ | ✓ | | 2 | 两个分区各 +1 |
| 1 | ✓ | ✓ | | 4 | 两个分区各 +1 |
| 2 | ✓ | | | 5 | `total=5`，`5 % 5 == 0` → `outClock` tick |
| 3 | ✓ | | | 6 | |
| 4 | ✓ | | ✓ | 8 | `inClock3` 被 countdown 触发：`total` +2（分区 1 和分区 3） |
| 5–7 | ✓ | | | 9,10,11 | `total=10` → `outClock` 又 tick |
| 8 | ✓ | ✓ | | 13 | 两个分区各 +1 |
| 9 | ✓ | ✓ | | 15 | `total=15` → `outClock` 又 tick |

`t=4` 是关键：`Clocks/model.c` 里写着

```c
if ((int)time == 4) {
    M(inClock3_qualifier) = 2; // fmi3IntervalChanged
    M(inClock3_interval) = 0.0;
}
```

到 `t=4` 时，FMU 主动为 countdown Clock 设置间隔并调用 `clockUpdate`。导入端在回调里读到 `qualifier = Changed`，于是激活 `inClock3` 的模型分区。这就是 countdown Clock 的完整闭环。

---

## 9.9 逐段读 `scs_threaded.c`

`scs_threaded.c`（约 470 行）是同一个 `Clocks` FMU 的多线程版本，只在 Windows 上编译（`#error This example can only be compiled on Windows`）。

### 9.9.1 线程与优先级

导入端为每个 input Clock 创建一个线程：

```c
thrHandle[curThrHandle] = (HANDLE)_beginthreadex(NULL, 0, thr_activateModelPartition, &thrArguments[i], 0, NULL);
if (thrHandle[curThrHandle] != NULL) {
    SetThreadAffinityMask(thrHandle[curThrHandle], processorMask);
    SetThreadPriority(thrHandle[curThrHandle], inputClockPrio[i]);
}
```

关键在 `inputClockPrio`：

```c
/*
 * For FMI3.0 lower priority value means higher priority
 * In windows lower value means lower prio
 * In windows we only have 5 prio levels [-2 .. +2]
 *
 * Setting the values based on the clock priorities from the ModelDescription.xml
 */
fmi3Int32 inputClockPrio[N_INPUT_CLOCKS] = { 2, 1, -1 };
```

这行注释非常有教学价值：

- FMI 3.0：数值小 = 优先级高。
- Windows `SetThreadPriority`：数值大 = 优先级高（`-2` 最高，`+2` 最低）。
- 所以需要**取反**，并加偏移（Windows 只有 5 档）。

FMU 的 priority 是 `0, 1, 2`（`inClock1` 最高）。转换后是 `2, 1, -1`（Windows 语义下 `-1` 最高）。

> 这就是「priority 是 FMU 局部的」的具体体现：导入端必须把它翻译到自己的调度器语义。

### 9.9.2 每个线程做的事

```c
unsigned __stdcall thr_activateModelPartition(void *args)  {

    ThreadArgs* TA = (ThreadArgs *)args;
    fmi3Status retval = fmi3OK;

    // Set Variables of appropriate partition
    switch (TA->clockRef) {
    case vr_inClock1: {
        logEvent("activateModelPartition calling fmi3ActivateModelPartition (%d)", TA->clockRef);
        // No variables to set for this partition
        retval = FMI3ActivateModelPartition(S, TA->clockRef, TA->activationTime);
        if (retval != fmi3OK)    break;
        retval = FMI3GetInt32(S, vrOutputs_c1, 2, &outputs_c1[0], 2);
        recordVariables2(S->component, TA->activationTime, vr_inClock1);
    }
    break;
    ...
```

三个分区各有各的输入/输出变量集，线程内部按 `clockRef` 分派。注释里的三步就是规范推荐的顺序：

```text
Set → Activate → Get
```

### 9.9.3 抢占锁

导入端提供两个回调：

```c
void cb_lockPreemption(void) {
    GlobalLock(globalLockVar);
}

void cb_unlockPreemption(void) {
    GlobalUnlock(globalLockVar);
}
```

用一个 Windows 全局锁。FMU 在 `activateModelPartition2` / `activateModelPartition3` 里调用它们。

注意 `scs_synchronous.c` 传的是 `NULL, NULL`（不提供锁），而 `scs_threaded.c` 传的是真正的锁：

```c
cb_lockPreemption,     // lockPreemption,
cb_unlockPreemption    // unlockPreemption
```

**同一个 FMU，两种导入端配置**：单线程时不需要锁，多线程时必须锁。这正是 9.6.4 节说的。

### 9.9.4 `cb_clockUpdate` 里的线程创建

```c
void cb_clockUpdate(fmi3InstanceEnvironment instanceEnvironment) {

    HANDLE thr_handle;
    int returnval;
    fmi3Clock localOutputClocks[1];

    GlobalLock(globalLockVar);
    if (!checkOutputClocks(S) & !checkCountdownClocks(S)) {
        GlobalUnlock(globalLockVar);
        logEvent("No clock active in intermediateUpdate callback");
        return;
    }
    localOutputClocks[0] = outputClocks[0];
    GlobalUnlock(globalLockVar);

    if (countdownClocksQualifier[0] == fmi3IntervalChanged) {
        // create a thread that will run the model partition for input clock 3
        logEvent("cb_intermediateUpdate starting thread for input clock 3 (vr=%d)", vr_inClock3);
        ...
        thr_handle = (HANDLE)_beginthreadex(NULL, 0, thr_activateModelPartition, &iu_arguments, 0, NULL);
        ...
    }
```

这是 SE 里最「野」的一段代码：在 FMU 的回调里创建线程来执行另一个模型分区。

有两个问题值得指出：

1. **`&` 而不是 `&&`**：`!checkOutputClocks(S) & !checkCountdownClocks(S)` 用的是按位与，会强制两个函数都执行。作为短路判断这是笔误（应该是 `&&`），但巧合的是这里**需要**两个都执行——因为后面的代码要用 `outputClocks[0]` 和 `countdownClocksQualifier[0]` 的值。
2. **回调里创建线程**，意味着导入端在 FMU 的调用栈上做了很重的事。规范没有禁止，但这在实时系统里是需要小心设计的地方。
3. **日志文案是复制粘贴的残留**：

```c
logEvent("No clock active in intermediateUpdate callback");
logEvent("cb_intermediateUpdate starting thread for input clock 3 (vr=%d)", vr_inClock3);
```

SE 里根本没有 `IntermediateUpdateMode`，也没有中间更新回调。这几行文案是从 CS 示例复制来的，改一下会更好——但不影响功能。

> 这和 9.8.3 节的实例化注释是同一类问题：**Reference 的 SE 示例是从 CS 示例演化来的，残留了一些痕迹**。读它们时要留意。

### 9.9.5 观察到的输出

```text
Running Scheduled Execution example...
GetCurrentProcessorNumber() => 9 (Mask = 200)
setAndCheckInputClocks: time = 0, inputClocks[InClock1] = 1, inputClocks[InClock2] = 1
==========> time = 0
Starting thread for clock InClock_1 (vr=1001)
Starting thread for clock InClock_2 (vr=1002)
activateModelPartition calling fmi3ActivateModelPartition (1001)
activateModelPartition calling fmi3ActivateModelPartition (1002)
setAndCheckInputClocks: time = 1, inputClocks[InClock1] = 1, inputClocks[InClock2] = 1
==========> time = 1
Starting thread for clock InClock_1 (vr=1001)
Starting thread for clock InClock_2 (vr=1002)
activateModelPartition calling fmi3ActivateModelPartition (1001)
activateModelPartition calling fmi3ActivateModelPartition (1002)
setAndCheckInputClocks: time = 2, inputClocks[InClock1] = 1, inputClocks[InClock2] = 0
==========> time = 2
Starting thread for clock InClock_1 (vr=1001)
activateModelPartition calling fmi3ActivateModelPartition (1001)
Detected ticking of output clock (time=2)
```

值得注意：

- `setAndCheckInputClocks` 打印出 `InClock2` 在 `time=2` 时是 0（不激活），和 `scs_synchronous.c` 的 `time % 8 == 0 || (time - 1) % 8 == 0` 判定逻辑一致。
- **`Detected ticking of output clock (time=2)`**：这正是 `totalInClockTicks = 5`（`5 % 5 == 0`）触发 `outClock`。和 9.8.5 节 CSV 里 `t=2` 的 `total=5` 对得上。
- 循环在 `time=2` 之后就结束了：因为 `stopTime` 来自 `DEFAULT_STOP_TIME = 3`（`Clocks/config.h`），而 `stepSize = FIXED_SOLVER_STEP = 1`，所以 `while (time < stopTime)` 跑 `time = 0, 1, 2`。

---

## 9.10 XML 里的 SE 声明

### 9.10.1 `<ScheduledExecution>` 元素

规范 5.4 节：

> If the FMU implements the Scheduled Execution interface type, the element `<ScheduledExecution>` must be present.

**它没有任何专属属性**，只有公共能力标志：

```xml
<ScheduledExecution modelIdentifier="Clocks"/>
```

和 `<CoSimulation>` 那一大堆属性形成鲜明对比。这本身就说明了 SE 接口的简单性：调度信息全在 Clock 上。

### 9.10.2 Clock 属性

SE 真正关心的配置都在 `<Clock>` 元素上：

```xml
<Clock name="inClock1"
       valueReference="1001"
       causality="input"
       intervalVariability="constant"
       intervalDecimal="1.0"
       priority="0"/>
```

| 属性 | 适用 | 说明 |
| --- | --- | --- |
| `intervalVariability` | 全部 | **必填**。决定 Clock 类型 |
| `intervalDecimal` | 周期 Clock | tick 间隔 |
| `intervalCounter` | 周期 Clock | 间隔的有理数表示（分子） |
| `shiftDecimal` | 周期 Clock | 第一次 tick 的延迟，默认 0 |
| `shiftCounter` | 周期 Clock | 延迟的有理数表示 |
| `supportsFraction` | 全部 | 是否允许调用 fraction 版 API，默认 `false` |
| `priority` | SE 的 input Clock | **SE 中必填**，数值小 = 优先级高 |
| `canBeDeactivated` | 全部 | 默认 `false` |
| `clocks` | 全部 | 依赖哪个 Clock |

### 9.10.3 `clocks` 属性的两种含义

规范 2.2.8.3 节：

> Declaring a variable as clocked variable using the `clocks` attribute specifies a dependencies dependency too, but also declares that such a clocked variable can only be accessed when one of the referenced Clocks is active. This also holds for clocked variables of type Clock.

所以 `clocks="1001"` 同时表达了两件事：

1. **依赖关系**：这个变量依赖 Clock 1001（所以 `ModelStructure` 里不必重复声明）。
2. **访问限制**：只能在 Clock 1001 活跃时访问。

> Note: variables referenced by `clocks` and `dependencies` are not strict subsets of one another because `clocks` may list output Clocks that are not part of the known variable set.

`Clocks/FMI3.xml` 里的例子：

```xml
<Clock name="inClock3" valueReference="1003" causality="input" intervalVariability="countdown" priority="2" clocks="1001"/>
<Clock name="outClock" valueReference="1005" causality="output" intervalVariability="triggered" clocks="1001 1002 1003"/>
```

`outClock` 声明依赖三个 input Clock——意思是这三个 Clock 里的任意一个 tick 都可能触发 `outClock`。

### 9.10.4 `ModelStructure` 里的 Clock

```xml
<ModelStructure>
  <Output valueReference="1005" dependencies="1001 1002 1003"/>
  <Output valueReference="2004" dependencies="1001 1002 1003"/>
  ...
</ModelStructure>
```

`outClock`（value reference 1005）既是 `<Output>`，也在 `dependencies` 里列了三个 Clock。这和 2.2.8.3 节说的「Clock 依赖关系声明在 `ModelStructure` 里」一致。

### 9.10.5 三种接口的 XML 对照

这三个元素共享一组**公共能力标志**（`modelIdentifier`、`needsExecutionTool`、`canBeInstantiatedOnlyOncePerProcess`、`canGetAndSetFMUState`、`canSerializeFMUState`、`providesDirectionalDerivatives`、`providesAdjointDerivatives`、`providesPerElementDependencies`），各自再叠加自己的专属标志。

| | `<ModelExchange>` | `<CoSimulation>` | `<ScheduledExecution>` |
| --- | --- | --- | --- |
| 专属属性数 | **2** | **9** | **0** |
| 专属标志 | `needsCompletedIntegratorStep` | `canHandleVariableCommunicationStepSize` | （无） |
| | `providesEvaluateDiscreteStates` | `fixedInternalStepSize` | |
| | | `maxOutputDerivativeOrder` | |
| | | `recommendedIntermediateInputSmoothness` | |
| | | `providesIntermediateUpdate` | |
| | | `mightReturnEarlyFromDoStep` | |
| | | `canReturnEarlyAfterIntermediateUpdate` | |
| | | `hasEventMode` | |
| | | `providesEvaluateDiscreteStates` | |
| 声明在哪 | `<ModelExchange>` | `<CoSimulation>` | `<ScheduledExecution>` |

这份清单可以直接从 `docs/spec-3.0.2/schema/fmi3InterfaceType.xsd` 读出来：

```xml
<xs:complexType name="fmi3ModelExchange">
  <xs:complexContent>
    <xs:extension base="fmi3InterfaceType">
      <xs:attribute name="needsCompletedIntegratorStep" type="xs:boolean" default="false"/>
      <xs:attribute name="providesEvaluateDiscreteStates" type="xs:boolean" default="false"/>
    </xs:extension>
  </xs:complexContent>
</xs:complexType>

<xs:complexType name="fmi3ScheduledExecution">
  <xs:complexContent>
    <xs:extension base="fmi3InterfaceType"/>
  </xs:complexContent>
</xs:complexType>
```

> 注意区分两个同名属性：
>
> - **`canBeDeactivated`** 是 `<Clock>` 的属性（能否被 `fmi3SetClock` 停用），**不是**接口元素的标志。
> - **`canInterpolateInputs`** 是 FMI 2.0 的 ME 标志，**FMI 3.0 已经删除**——3.0 用 `providesIntermediateUpdate` + `recommendedIntermediateInputSmoothness` 取代了它。
> - **`maxOutputDerivativeOrder`** 是 `<CoSimulation>` 的标志，ME 不需要它（ME 的导数本来就是一阶的）。


---

## 9.11 动手实验

> **前置条件**：实验 2–3 需要先编译 Reference FMUs。`build/` 已被 `.gitignore` 忽略。
>
> ```powershell
> cd examples\reference-fmus
> cmake -B build .
> cmake --build build --config Release
> cd ..\..
> ```
>
> 实验 1、4 只读 XML，不需要编译。

### 实验 1：盘点 SE 能力和 Clock 配置

**目标**：找出仓库里哪些 FMU 支持 SE，并列出每个 Clock 的类型、优先级和依赖。

在仓库根目录执行：

```powershell
Get-ChildItem .\examples\reference-fmus -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'FMI3.xml') } |
    ForEach-Object {
        $xml = [xml](Get-Content (Join-Path $_.FullName 'FMI3.xml') -Raw -Encoding UTF8)
        $se  = $xml.fmiModelDescription.ScheduledExecution
        if ($se) {
            "=== $($_.Name) : SE with modelIdentifier $($se.modelIdentifier) ==="
            $xml.fmiModelDescription.ModelVariables.Clock | ForEach-Object {
                [pscustomobject]@{
                    Name       = $_.name
                    VR         = $_.valueReference
                    Causality  = $_.causality
                    Variability = $_.intervalVariability
                    Interval   = if ($_.intervalDecimal) { $_.intervalDecimal } else { '-' }
                    Priority   = if ($_.priority) { $_.priority } else { '-' }
                    Clocks     = if ($_.clocks) { $_.clocks } else { '-' }
                }
            } | Format-Table -AutoSize | Out-String -Width 120
        }
    }
```

预期输出：

```text
=== Clocks : SE with modelIdentifier Clocks ===

Name     VR   Causality Variability Interval Priority Clocks
----     --   --------- ----------- -------- -------- ------
inClock1 1001 input     constant    1.0      0        -
inClock2 1002 input     triggered   -        1        -
inClock3 1003 input     countdown   -        2        1001
outClock 1005 output    triggered   -        -        1001 1002 1003
```

观察：

- 整个仓库只有 `Clocks` 一个 SE FMU。
- `outClock` 是 output Clock，**没有** `priority`（规范禁止）。
- 三个 input Clock 都有 `priority`，SE 中必填。
- `inClock1` 是 `constant` + `intervalDecimal="1.0"`，对应「每 1 秒 tick 一次」。
- `inClock2` 是 `triggered`，节奏完全由导入端决定。
- `inClock3` 是 `countdown`，且 `clocks="1001"` 表示它由 `inClock1` 驱动。

### 实验 2：跑同步 SE 示例，读出完整时序

**目标**：运行 `scs_synchronous.exe`，验证「三个模型分区 + 一个 countdown Clock + 一个 output Clock」的完整闭环。

```powershell
$exe = '.\examples\reference-fmus\build\temp\scs_synchronous.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch9-scs-sync'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

Import-Csv (Join-Path $dir 'scs_synchronous_out.csv') | Format-Table -AutoSize
```

预期输出：

```text
time inClock1Ticks inClock2Ticks inClock3Ticks totalInClockTicks
---- ------------- ------------- ------------- -----------------
0    1             1             0             2
1    2             2             0             4
2    3             2             0             5
3    4             2             0             6
4    5             2             1             8
5    6             2             1             9
6    7             2             1             10
7    8             2             1             11
8    9             3             1             13
9    10            4             1             15
```

三个关键观察：

1. **`t=4` 的 `inClock3Ticks` 从 0 变成 1**，而 `t=0..3` 和 `t=5..9` 都是 0。这唯一的激活来自 countdown Clock 的 `IntervalChanged` 通知。
2. **`t=4` 的 `total` 从 6 跳到 8**（+2），因为同一时刻激活了两个分区（`inClock1` 和 `inClock3`）。
3. **`total` 在 `t=2, 6, 9` 分别是 5, 10, 15**，都是 5 的倍数 → `outClock` tick。

再看日志确认调用序列：

```powershell
$dir  = Join-Path $env:TEMP 'fmi-ch9-scs-sync'
$log  = Get-Content (Join-Path $dir 'scs_synchronous_log.txt')

"ActivateModelPartition calls: $(($log | Select-String 'fmi3ActivateModelPartition' -SimpleMatch).Count)"
"  clock 1001 (inClock1): $(($log | Select-String 'clockReference=1001' -SimpleMatch).Count)"
"  clock 1002 (inClock2): $(($log | Select-String 'clockReference=1002' -SimpleMatch).Count)"
"  clock 1003 (inClock3): $(($log | Select-String 'clockReference=1003' -SimpleMatch).Count)"
"GetClock calls         : $(($log | Select-String 'fmi3GetClock' -SimpleMatch).Count)"
"GetIntervalDecimal     : $(($log | Select-String 'fmi3GetIntervalDecimal' -SimpleMatch).Count)"

'--- at t = 4 ---'
$i = ($log | Select-String 'activationTime=4' | Select-Object -First 1).LineNumber
$log | Select-Object -Skip ($i - 1) -First 4
```

预期输出：

```text
ActivateModelPartition calls: 15
  clock 1001 (inClock1): 10
  clock 1002 (inClock2): 4
  clock 1003 (inClock3): 1
GetClock calls         : 10
GetIntervalDecimal     : 4

--- at t = 4 ---
fmi3ActivateModelPartition(clockReference=1001, activationTime=4) -> OK
fmi3ActivateModelPartition(clockReference=1003, activationTime=4) -> OK
fmi3GetClock(valueReferences={1005}, nValueReferences=1, values={0}) -> OK
fmi3GetInt32(valueReferences={2001, 2002, 2003, 2004}, nValueReferences=4, values={5, 2, 1, 8}, nValues=4) -> OK
```

数字对得上：

- `1001` 激活 10 次（`t = 0..9`，每秒一次）。
- `1002` 激活 4 次（`t = 0, 1, 8, 9`，符合 `time % 8 == 0 || (time - 1) % 8 == 0`）。
- `1003` 激活 **1** 次（只有 `t = 4`）。
- `GetClock` 10 次（每轮一次）。
- `GetIntervalDecimal` 4 次：每次 `clockUpdate` 回调触发一次（回调里无条件查 countdown Clock）。

「`1003` 只激活 1 次」是本章最值得记住的数字。一个 countdown Clock 的模型分区，只在 FMU 明确报告「新间隔已知」时才被调度，而且通常只激活一次——下一次间隔要等 FMU 再通知。

> **`1003` 只激活 1 次是本章最值得记住的数字。** 一个 countdown Clock 的模型分区，只在 FMU 明确报告「新间隔已知」时才被调度，而且通常只激活一次（因为下一次间隔要等 FMU 再通知）。

### 实验 3：跑多线程 SE 示例

**目标**：运行 `scs_threaded.exe`，观察线程创建和优先级设置，并确认 output Clock 的 tick 被检测到。

```powershell
$exe = '.\examples\reference-fmus\build\temp\scs_threaded.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch9-scs-thread'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe 2>&1 } finally { Pop-Location }
```

预期输出（部分）：

```text
Running Scheduled Execution example...
GetCurrentProcessorNumber() => 9 (Mask = 200)
setAndCheckInputClocks: time = 0, inputClocks[InClock1] = 1, inputClocks[InClock2] = 1
==========> time = 0
Starting thread for clock InClock_1 (vr=1001)
Starting thread for clock InClock_2 (vr=1002)
activateModelPartition calling fmi3ActivateModelPartition (1001)
activateModelPartition calling fmi3ActivateModelPartition (1002)
setAndCheckInputClocks: time = 1, inputClocks[InClock1] = 1, inputClocks[InClock2] = 1
==========> time = 1
...
setAndCheckInputClocks: time = 2, inputClocks[InClock1] = 1, inputClocks[InClock2] = 0
==========> time = 2
Starting thread for clock InClock_1 (vr=1001)
activateModelPartition calling fmi3ActivateModelPartition (1001)
Detected ticking of output clock (time=2)
```

> `GetCurrentProcessorNumber()` 的值每次运行都不同（取决于调度到哪个核），它后面跟的 `Mask` 也随之变化。这一行不影响仿真结果。

关键观察：

- `time = 2` 时 `InClock2` 的状态是 `0`（不激活），只有 `InClock_1` 起了线程。
- `Detected ticking of output clock (time=2)` 对应 `totalInClockTicks = 5`（`5 % 5 == 0`），和实验 2 的 CSV 完全一致。
- 线程的输出顺序是不确定的（真实并发），但**每个时刻激活的分区集合是确定的**——这是 SE 的契约。

> **注意**：这个示例只在 Windows 上编译。它的 `Sleep(950)` 是为了模拟「实时系统每 1 秒唤醒一次」，所以跑起来会有几秒延迟。

### 实验 4：从源码读 SE 的 API 使用

**目标**：统计 Reference 实现里 SE 相关函数的状态掩码，理解「哪些调用在哪个状态下合法」。

```powershell
$src = '.\examples\reference-fmus\src\fmi3Functions.c'

Select-String -Path $src -Pattern 'MASK_fmi3(ActivateModelPartition|GetClock|GetIntervalDecimal|GetIntervalFraction|SetClock|GetInt32|SetInt32)' |
    ForEach-Object { '{0,4}: {1}' -f $_.LineNumber, $_.Line.Trim() }
```

预期输出（部分）：

```text
 129: #define MASK_fmi3GetClock                 MASK_AnyState
 137: #define MASK_fmi3SetInt32                 MASK_fmi3SetInt8
 144: #define MASK_fmi3SetClock                 MASK_AnyState
 168: #define MASK_fmi3GetIntervalDecimal        MASK_AnyState
 169: #define MASK_fmi3GetIntervalFraction       MASK_AnyState
 198: #define MASK_fmi3ActivateModelPartition   ClockActivationMode
```

这里有一个值得注意的现象：**Reference 的 `fmi3GetClock` 和 `fmi3GetIntervalDecimal` 用的是 `MASK_AnyState`**，也就是任何状态都允许调用。

而规范 5.2 节把 `fmi3GetClock` 和 `fmi3GetIntervalDecimal` 放在 `ClockUpdateMode` 的允许列表里，5.2 节的 `ClockActivationMode` 只列了 `fmi3GetIntervalDecimal` / `fmi3GetIntervalFraction` 对 `tunable` 和 `changing` Clock 开放。

所以 Reference 实现比规范宽松。**冲突时以规范为准**：生产导入端应假设 `fmi3GetClock` 只在 `ClockUpdateMode` 里可靠。

再确认 `fmi3ActivateModelPartition` 的掩码是严格的：

```powershell
Select-String -Path '.\examples\reference-fmus\src\fmi3Functions.c' `
    -Pattern 'MASK_fmi3ActivateModelPartition' |
    ForEach-Object { $_.Line.Trim() }
```

```text
#define MASK_fmi3ActivateModelPartition   ClockActivationMode
```

只有 `ClockActivationMode` 允许。这和 9.5.2 节的三条硬约束一致。

### 实验 5：`scs_synchronous.c` 的实例化注释与规范签名不符

**目标**：验证 9.8.3 节提出的疑点——Reference 的 SE 示例的行尾注释是从 CS 示例复制来的，没有跟着签名更新。

```powershell
# 规范签名（FMI 3.0.2）
Select-String -Path .\docs\spec-3.0.2\headers\fmi3FunctionTypes.h `
    -Pattern 'fmi3InstantiateScheduledExecutionTYPE' -Context 0,12 |
    ForEach-Object { $_.Context.PostContext } |
    Where-Object { $_ -match 'fmi3\w+' } |
    ForEach-Object { $_.Trim() }

'--- 参考实现签名 ---'
Select-String -Path .\examples\reference-fmus\src\fmi3Functions.c `
    -Pattern 'fmi3Instance fmi3InstantiateScheduledExecution' -Context 0,11 |
    ForEach-Object { $_.Context.PostContext } |
    Where-Object { $_ -match 'fmi3\w+' } |
    ForEach-Object { $_.Trim() }
```

预期输出：

```text
fmi3String                     instanceName,
fmi3String                     instantiationToken,
fmi3String                     resourcePath,
fmi3Boolean                    visible,
fmi3Boolean                    loggingOn,
fmi3InstanceEnvironment        instanceEnvironment,
fmi3LogMessageCallback         logMessage,
fmi3ClockUpdateCallback        clockUpdate,
fmi3LockPreemptionCallback     lockPreemption,
fmi3UnlockPreemptionCallback   unlockPreemption);
--- 参考实现签名 ---
fmi3String                     instanceName,
fmi3String                     instantiationToken,
fmi3String                     resourcePath,
fmi3Boolean                    visible,
fmi3Boolean                    loggingOn,
fmi3InstanceEnvironment        instanceEnvironment,
fmi3LogMessageCallback         logMessage,
fmi3ClockUpdateCallback        clockUpdate,
fmi3LockPreemptionCallback     lockPreemption,
fmi3UnlockPreemptionCallback   unlockPreemption) {
```

规范和实现都是 10 个参数，**没有** `requiredIntermediateVariables`。

再看示例的调用：

```powershell
Select-String -Path .\examples\reference-fmus\examples\scs_synchronous.c `
    -Pattern 'FMI3InstantiateScheduledExecution' -Context 0,11 |
    ForEach-Object { $_.Context.PostContext } |
    ForEach-Object { $_.TrimEnd() }
```

预期输出：

```text
    INSTANTIATION_TOKEN,   // instantiationToken
    NULL,                  // resourceLocation
    fmi3False,             // visible
    fmi3False,             // loggingOn
    NULL,                  // requiredIntermediateVariables
    0,                     // nRequiredIntermediateVariables
    cb_clockUpdate,        // clockUpdate
    NULL,                  // lockPreemption
    NULL                   // unlockPreemption
));
```

**参数个数是 10 个（正确），但第 6、7 个的行尾注释是错的**——它们其实是 `instanceEnvironment` 和 `logMessage`，注释是从 `simulate_fmi3_cs.c` 复制来的。

为什么写错了注释却没出事？因为示例不直接调 C API，而是走 `FMI3.h` 的包装层：

```powershell
Select-String -Path .\examples\reference-fmus\src\FMI3.c `
    -Pattern 'instance->fmi3Functions->fmi3InstantiateScheduledExecution\(' `
    -Context 0,11 |
    ForEach-Object { $_.Line.TrimEnd(); $_.Context.PostContext } |
    ForEach-Object { $_.TrimEnd() }
```

预期输出：

```text
    instance->component = instance->fmi3Functions->fmi3InstantiateScheduledExecution(
        instance->name,
        instantiationToken,
        resourcePath,
        visible,
        loggingOn,
        instance,
        _logMessage,
        clockUpdate,
        lockPreemption,
        unlockPreemption);
```

包装层把 `instanceEnvironment` 固定成自己的 `instance` 指针，把 `logMessage` 固定成统一的 `cb_logMessage3`。所以示例传进去的 `NULL` 和 `0` 会被覆盖掉。

> **教学价值**：注释错了、代码是对的——这类「复制粘贴残留」在真实代码库里非常常见。读代码时**以函数签名为准**。写自己的 SE 导入端时，请严格按 3.0.2 的 10 参数签名，并且把注释改对。

---

## 9.12 常见错误清单

1. **在 SE 中调用 `fmi3SetClock`**。规范明确禁止，必须用 `fmi3ActivateModelPartition`。
2. **调用 `fmi3EnterEventMode` / `fmi3UpdateDiscreteStates`**。SE 没有 `EventMode`。
3. **对 output Clock 调用 `fmi3ActivateModelPartition`**。只能对 input Clock 调用。
4. **同一个 Clock 在同一时间点激活两次**。规范禁止。
5. **同一 Clock 的 `activationTime` 不严格单调递增**。规范要求严格递增。
6. **以为 `fmi3Get{VariableType}` 会触发计算**。在 SE 里不会，计算在 `fmi3ActivateModelPartition` 里。
7. **在 `fmi3Set{VariableType}` 之后、`fmi3ActivateModelPartition` 之前调用 `fmi3Get{VariableType}`**。规范不允许这个顺序。
8. **在模型分区执行或被抢占时调用 `fmi3GetFMUState` / `fmi3SetFMUState`**。这两个作用于整个 FMU。
9. **在 SE 中把 `fmi3Discard` 当作可重试**。SE 里必须当 `fmi3Error` 处理。
10. **假设 `fmi3GetClock` 可以重复读到 `fmi3ClockActive`**。output Clock 的 tick 是一次性的。
11. **把 `fmi3IntervalNotYetKnown` 当作「间隔为 0」**。它的含义是「暂时无法排程该模型分区」。
12. **假设 FMU 的 `priority` 能跨 FMU 比较**。priority 是 FMU 局部的，跨 FMU 顺序由导入端推导。
13. **把 Windows 线程优先级直接套用 FMI priority**。FMI 是「小值高优先级」，Windows 是「大值高优先级」，必须转换。
14. **在锁保护区内调用 `clockUpdate` 回调**。回调可能触发导入端调度，可能死锁。参考的 `Clocks/model.c` 特意把 `clockUpdate` 放在解锁之后。

---

## 小结

- SE 把「何时执行」完全交给导入端。导入端是调度器，FMU 是被调度的算法集合。
- 模型分区是 SE 的基本单位；一个 Clock 对应一个分区；通过 `clocks` 属性关联的变量是 clocked variable，只能在该 Clock 活跃时访问（`InitializationMode` 除外）。
- SE 的状态机只有两个专属状态：`ClockActivationMode`（主循环）和 `ClockUpdateMode`（FMU 主动通知时进入）。SE **没有** `EventMode`。
- `fmi3ActivateModelPartition(clockReference, activationTime)` 是 SE 的推进函数：调用即计算，读变量不计算。
- `fmi3ClockUpdateCallback` 让 FMU 主动报告两件事：triggered output Clock 刚 tick 了、countdown Clock 要 tick 了。导入端在回调里用 `fmi3GetClock` / `fmi3GetIntervalDecimal` 获取详情。
- Clock 的六种类型决定调度方式：周期类（`constant`/`fixed`/`tunable`）由导入端排程；非周期类（`changing`/`countdown`）需要运行时用 `fmi3GetInterval` 改排程；`countdown` 在间隔未知时对应模型分区**无法排程**。
- `fmi3IntervalQualifier` 的三个值：`NotYetKnown = 0`（无法排程）、`Unchanged = 1`（已排程）、`Changed = 2`（重新排程）。
- output Clock 和 `Changed` 状态都是**一次性**的：读过一次就复位。
- `priority` 在 SE 的 input Clock 上必填，数值小 = 优先级高，但只在 FMU 内部有意义。跨 FMU 顺序由导入端按数据流推导。
- 抢占由导入端实现（中断低优先级分区），FMU 用 `lockPreemption` / `unlockPreemption` 回调保护关键代码段。锁要尽量少用、尽量短。
- SE 中 `fmi3Discard` 必须当 `fmi3Error` 处理；`fmi3GetFMUState` 系列在有分区执行时禁止调用。

---

## 习题

### 1. 找出第一个非法调用

下面每个序列都从成功实例化开始。指出**第一个**违反状态机或前置条件的调用，并给出修正方案。

1. SE：`fmi3ExitInitializationMode` → `fmi3EnterEventMode` → `fmi3ActivateModelPartition`
2. SE：`fmi3ActivateModelPartition(clockReference = 输出 Clock 的 VR, activationTime = 1.0)`
3. SE：`fmi3ActivateModelPartition(vr_inClock1, 1.0)` → `fmi3ActivateModelPartition(vr_inClock1, 1.0)`
4. SE：`fmi3ActivateModelPartition(vr_inClock1, 2.0)` → `fmi3ActivateModelPartition(vr_inClock1, 1.0)`
5. SE：`fmi3SetClock`（激活 input Clock）
6. SE：模型分区正在执行时，调用 `fmi3GetFMUState`
7. SE：`fmi3DoStep(t, h, ...)`

<details>
<summary>答案</summary>

1. `fmi3EnterEventMode` 非法。SE 没有 `EventMode`——规范 2.3 节写明「`EventMode` is not available in Scheduled Execution」。修正：删掉该调用。`fmi3ExitInitializationMode` 后 SE 直接进入 `ClockActivationMode`，然后 `fmi3ActivateModelPartition` 是合法的。
2. 非法。规范：「`fmi3ActivateModelPartition` must not be called on output Clocks of an FMU.」output Clock 的 tick 由 FMU 通过 `fmi3ClockUpdateCallback` 报告，导入端只负责调度它的下游。修正：只对 input Clock 调用；output Clock 的下游改由「检测到 output Clock 激活后触发下游任务」来安排。
3. 非法。规范：「`fmi3ActivateModelPartition` must only be called once for the same Clock and time.」修正：同一 Clock 同一时刻只激活一次。
4. 非法。规范：「Consecutive calls to `fmi3ActivateModelPartition` for a `clockReference` must have strictly monotonically increasing `activationTime`.」`2.0` 之后是 `1.0`，不满足严格单调递增。修正：改成大于 `2.0` 的时间。
5. 非法。规范 2.2.8.1 节：「`fmi3SetClock` must not be called in Scheduled Execution, instead `fmi3ActivateModelPartition` must be called.」修正：用 `fmi3ActivateModelPartition(clockReference, activationTime)` 代替。
6. 非法。规范 5.2 节：`fmi3GetFMUState` 等函数「must not be called if any model partition is currently active or preempted」，因为它们作用于整个 FMU。修正：等所有分区都结束后再调用。
7. 非法。`fmi3DoStep` 是 CS 接口，SE 没有。SE 的推进函数是 `fmi3ActivateModelPartition`。

</details>

### 2. 设计一个 SE 调度循环

下面的循环有若干问题。请重写它。

```c
while (time < stopTime) {

    fmi3SetFloat64(fmu, &vrInput, 1, &inputValue, 1);

    fmi3GetFloat64(fmu, &vrOutput, 1, &outputValue, 1);

    fmi3ActivateModelPartition(fmu, vr_inClock1, time);

    time += 0.1;
}
```

回答：

1. 列出所有问题。
2. 写出修正后的循环。要求：在 `ClockActivationMode` 里按 `Set → Activate → Get` 顺序操作；用 `fmi3GetIntervalDecimal` 处理 countdown Clock；处理 `clockUpdate` 回调。

<details>
<summary>答案</summary>

1. 问题清单：
   - `Set` 之后、`Activate` 之前调用了 `Get`。规范 5.2 节不允许这个顺序（Get 后必须跟一次 Activate）。
   - 在 `Activate` 之前读 `vrOutput`，读到的是上一次激活留下的旧值，因为 SE 里读变量不触发计算。
   - 没有处理 countdown Clock：`fmi3GetIntervalDecimal` 从没调用过，`IntervalChanged` 永远不会被发现，对应模型分区永远不会被激活。
   - 没有处理 output Clock：没有 `fmi3GetClock`，导入端不知道哪个 output Clock tick 了。
   - 没有实现 `clockUpdate` 回调（实例化时传的回调必须是可用的）。
   - `time += 0.1` 假定通信步长一定是 0.1。周期 Clock 的间隔应从 XML 的 `intervalDecimal` 读，或用 `fmi3GetIntervalDecimal` 查询。
   - 没有做「同一 Clock 同一时刻只激活一次」「`activationTime` 严格单调递增」的保护。

2. 修正版本（伪代码）：

```c
/* 回调：FMU 说「我要 tick 了 / countdown 间隔变了」 */
static void onClockUpdate(fmi3InstanceEnvironment env) {
    /* 查询 countdown Clock 的新间隔 */
    fmi3Float64 interval[1];
    fmi3IntervalQualifier qualifier[1];
    fmi3GetIntervalDecimal(fmu, &vr_countdown, 1, interval, qualifier);

    if (qualifier[0] == fmi3IntervalChanged) {
        countdownInterval = interval[0];
        countdownPending  = true;      /* 下一次循环里激活该分区 */
    }

    /* 查询哪个 output Clock 刚 tick 了 */
    fmi3Clock states[1];
    fmi3GetClock(fmu, &vr_outClock, 1, states);
    if (states[0] == fmi3ClockActive) {
        scheduleDownstreamTasks();
    }
}

while (time < stopTime) {

    /* 1. Set：设置输入 */
    fmi3SetFloat64(fmu, &vrInput, 1, &inputValue, 1);

    /* 2. Activate：激活模型分区（这里才算） */
    fmi3ActivateModelPartition(fmu, vr_inClock1, time);

    /* 3. Get：读取输出 */
    fmi3GetFloat64(fmu, &vrOutput, 1, &outputValue, 1);

    /* countdown Clock：只有 FMU 报了 IntervalChanged 才激活 */
    if (countdownPending) {
        fmi3ActivateModelPartition(fmu, vr_countdown, time + countdownInterval);
        countdownPending = false;
    }

    time += period;   /* period 来自 XML 的 intervalDecimal，或 fmi3GetIntervalDecimal */
}
```

要点：`Set → Activate → Get` 的顺序；countdown Clock 的激活时间要加上 FMU 给出的间隔；output Clock 的下游任务在回调里安排。

</details>

### 3. Clock 类型判断

对下面每个 Clock，说明导入端什么时候能知道它的下一次 tick 时刻，以及 SE 中如何排程。

1. `causality="input" intervalVariability="constant" intervalDecimal="0.01"`
2. `causality="input" intervalVariability="fixed" intervalDecimal="0.01"`
3. `causality="input" intervalVariability="tunable" intervalDecimal="0.01"`
4. `causality="input" intervalVariability="changing"`
5. `causality="input" intervalVariability="countdown"`
6. `causality="output" intervalVariability="triggered"`

<details>
<summary>答案</summary>

1. **常量周期**：导入端从一开始就完全知道（`0.01` 在 XML 里）。SE 中按固定周期排程，不需要运行时查询。`fmi3SetInterval` 不需要调用（XML 已给出）；`InitializationMode` 里可用 `fmi3GetInterval` 确认。
2. **固定周期**：XML 给了 `intervalDecimal`，所以间隔已知。导入端在 `InitializationMode` 用 `fmi3SetInterval` 告知 FMU 实际采用的间隔（这样 FMU 能适配内部计算）；shift 可选设置。运行时不可改。
3. **可调周期**：间隔已知但可改。导入端在 `InitializationMode` 设置；之后若 `tunable` 参数变化，可以在 `ClockActivationMode` 再次 `fmi3SetInterval` 并重新排程该模型分区。shift 只能在初始化时处理。
4. **变化非周期**：tick 完才知道下次间隔。导入端在 `InitializationMode` 查一次 `fmi3GetInterval`，之后在**该 Clock 激活过的** `ClockActivationMode` / `ClockUpdateMode` 再查。拿到新间隔就重新排程。不允许 `fmi3GetShift` / `fmi3SetShift`。
5. **倒计时非周期**：tick 完时**还不知道**下次间隔。导入端必须在 `InitializationMode`、每个 `EventMode`（SE 中无）、每个 `ClockUpdateMode` 都查。在「未知」期间，**对应的模型分区无法排程**。SE 中 FMU 必须通过 `fmi3ClockUpdateCallback` 提前告知。禁止 shift 操作。
6. **触发式 output Clock**：时刻由 FMU 决定（硬件事件、外部信号等）。导入端不做周期排程，而是在收到 `clockUpdate` 回调后调用 `fmi3GetClock` 得知哪个 output Clock 活跃，然后调度其下游。注意 tick 状态是一次性的：只有第一次 `fmi3GetClock` 返回 `fmi3ClockActive`。

</details>

### 4. `qualifiers` 的调度含义

某 SE FMU 有一个 countdown input Clock，管理一个模型分区。导入端查询它时拿到不同的 `qualifiers`：

| 场景 | `qualifier` | 导入端该做什么 |
| --- | --- | --- |
| A | `fmi3IntervalChanged` | ? |
| B | `fmi3IntervalUnchanged` | ? |
| C | `fmi3IntervalNotYetKnown` | ? |

另外回答：

1. 这三个枚举值的数值分别是多少？
2. 如果导入端在场景 C 仍然排程了该模型分区，会发生什么？
3. 谁负责把 `Changed` 降级成 `Unchanged`？

<details>
<summary>答案</summary>

| 场景 | `qualifier` | 导入端该做什么 |
| --- | --- | --- |
| A | `fmi3IntervalChanged` | **重新排程**该模型分区：用返回的 interval 作为新的延迟 |
| B | `fmi3IntervalUnchanged` | 保持已有排程（该分区已经排过了），什么都不做 |
| C | `fmi3IntervalNotYetKnown` | **不能排程**该模型分区，等待 FMU 下次通过 `clockUpdate` 通知 |

1. 数值：`fmi3IntervalNotYetKnown = 0`、`fmi3IntervalUnchanged = 1`、`fmi3IntervalChanged = 2`（枚举定义顺序即数值顺序）。Reference 的 `Clocks/model.c` 直接用 `2` 表示 `Changed`。
2. 会用错误的时间激活模型分区（延迟为 0 或用旧值），导致该分区在错误时刻执行。规范明确说 `NotYetKnown` 时「the corresponding model partition cannot be scheduled yet」。
3. **FMU 负责**。规范要求 FMU 在 `fmi3GetInterval` 把状态降级（参考实现：`if (qualifier == fmi3IntervalChanged) qualifier = fmi3IntervalUnchanged;`）。这样导入端不会重复排程。

</details>

### 5. 抢占与锁

阅读 `examples/reference-fmus/Clocks/model.c` 的三个 `activateModelPartition*` 函数。

回答：

1. 为什么 `activateModelPartition1` 里没有 `lockPreemption` 调用，而 `activateModelPartition2` 和 `activateModelPartition3` 有？
2. 为什么 `activateModelPartition2` 把 `comp->clockUpdate(...)` 放在 `unlockPreemption()` **之后**？
3. 如果 `Clocks` FMU 的 `inClock1` 的 priority 从 0 改成 2（变成最低优先级），`activateModelPartition1` 还需要加锁吗？
4. 「同一个 FMU 的两个模型分区共享 `totalInClockTicks`」这个设计带来了什么风险？规范建议怎么缓解？

<details>
<summary>答案</summary>

1. `activateModelPartition1` 对应 `inClock1`，priority = 0，是该 FMU 中**最高**优先级。规范 5.1.2 节指出：「a model partition cannot be interrupted if it is the only model partition or if it holds the highest priority. Similarly, a model partition ... might not need to guard data accesses if it is the only model partition of the FMU, or the one with the highest priority. In such cases no locks may be necessary.」所以最高优先级的分区不会被抢占，不需要锁。分区 2（priority 1）和分区 3（priority 2）可能被抢占，要保护共享数据。
2. `clockUpdate` 回调会让导入端去读 Clock 状态并可能调度其它分区。如果还持有锁，导入端的调度逻辑（可能需要获取同一把锁，或者触发另一个需要这把锁的分区）就会死锁。先解锁再通知是标准做法。
3. 需要加锁。改成 priority = 2 后，分区 1 就不再是最高优先级，会被高优先级分区中断，而它修改的 `totalInClockTicks` 是共享变量，必须加锁保护。
4. 风险：并发读写 `totalInClockTicks` 造成竞态条件（读到脏值、丢失更新），而且 `M(outClock) = ((M(outClock) == false) && (M(totalInClockTicks) % 5 == 0))` 这类「读-改-写」在抢占下会丢 tick。规范建议：「it is recommended to reduce dependencies between different model partitions of one FMU by design. In particular a unique assignment of the respective variables to model partitions via its associated Clock is strongly recommended.」即：尽量让每个变量只属于一个模型分区，从设计上避免共享；必须共享时用锁保护，并且锁要短。

</details>

### 6. SE、CS、ME 三选一

给下列需求选最合适的 FMI 接口类型（ME / CS / SE），并说明理由。

1. 一个液压系统模型，要和一个电磁阀模型联合仿真，两者的耦合很强，需要在通信点之间传递中间值。
2. 一个发动机 ECU 的控制算法，要部署到硬件在环（HiL）测试台，测试台有自己的硬实时调度器，按固定周期触发各个控制任务。
3. 一个化学反应的 ODE 模型，要导入到一个使用 Adams/Simulink 求解器的工具里，工具需要访问状态导数。
4. 一个包含三个独立监控任务（采样率分别是 10 ms、50 ms、100 ms）的诊断模块，要和主机上的其它线程并发运行。
5. 一个纯离散的票务系统模型，每笔交易是一个离散事件。

<details>
<summary>答案</summary>

1. **CS**。需求强调「联合仿真」和「通信点之间传递中间值」——中间更新（`IntermediateUpdateMode`）是 CS 的能力，能在通信步内部做输入/输出的插值或外推。ME 虽然也能配合机制的联合仿真，但 ME 没有「中间更新」这个概念。
2. **SE**。测试台有自己的硬实时调度器，按固定周期触发任务——这正是 SE 的模型：导入端就是调度器，FMU 暴露若干由 Clock 触发的模型分区，导入端按周期调用 `fmi3ActivateModelPartition`。CS 要求 FMU 自己推进时间，与「测试台自己调度」冲突。
3. **ME**。工具需要访问状态导数来自己积分，这是 ME 的核心特征（`fmi3GetContinuousStateDerivatives`、`fmi3SetContinuousStates`）。CS 和 SE 都不暴露连续状态。
4. **SE**。要求「和其它线程并发运行」，且每个任务有不同采样率——SE 的模型分区 + `priority` + 抢占正是为这个场景设计的。
5. **CS**（或 SE，取决于是否需要并发）。票务系统本质是离散事件处理，没有连续时间状态，所以不要 ME。如果它只是一个按顺序推进的黑盒模型，CS 最简单；如果每个事件处理任务需要独立的调度优先级和并发能力，才考虑 SE。注意 CS 通过 `eventModeUsed = true` 提供事件处理能力。

</details>

### 7. 判断题

1. SE 中导入端可以不调用 `fmi3ActivateModelPartition` 而只读变量。
2. SE 中 `fmi3Get{VariableType}` 会触发该模型分区的计算。
3. `fmi3ActivateModelPartition` 可以对 output Clock 调用。
4. `priority` 属性在 SE 中对 input Clock 是必填的。
5. `priority` 数值越大，优先级越高。
6. 不同 FMU 的 `priority` 可以直接比较。
7. 相同 `priority` 的 Clock 的激活顺序是确定的。
8. 在 SE 中调用 `fmi3SetClock` 是激活 input Clock 的正确方式。
9. `fmi3GetClock` 对一个 activated 的 output Clock 只有第一次返回 `fmi3ClockActive`。
10. `clockUpdate` 回调可以在导入端持有抢占锁时被调用。
11. SE 中 `fmi3Discard` 可以当作「可以重试」处理。
12. `fmi3GetFMUState` 可以在模型分区执行期间调用。
13. `<ScheduledExecution>` 元素可以有专属属性（如 `fixedInternalStepSize`）。
14. countdown Clock 的模型分区在 `qualifier = fmi3IntervalNotYetKnown` 时不能排程。
15. 周期 Clock 中，周期越短推荐分配的 priority 越小（越高）。

<details>
<summary>答案</summary>

1. 错。`fmi3ActivateModelPartition` 是 SE 中触发计算的唯一途径；读变量不会触发计算。
2. 错。SE 规范明确把计算从读取中拆出：「`fmi3ActivateModelPartition` will perform the actual calculation instead of `fmi3Get{VariableTypeExclClock}`」。计算集中在 `fmi3ActivateModelPartition` 内是为了实时性可预测。
3. 错。规范：「`fmi3ActivateModelPartition` must not be called on output Clocks of an FMU.」
4. 对。规范 2.4 节：「This attribute is mandatory for input Clocks in Scheduled Execution.」
5. 错。「Smaller values signal higher priorities.」数值小 = 优先级高。
6. 错。规范 5.1 节：「The Clock priorities are local to an FMU.」跨 FMU 顺序由导入端按数据流推导。
7. 错。规范：「For multiple Clocks with the same priority the order is undefined.」
8. 错。规范：「`fmi3SetClock` must not be called in Scheduled Execution, instead `fmi3ActivateModelPartition` must be called.」
9. 对。规范 5.2 节：「only the first call of `fmi3GetClock` for a specific activation of this Clock signals `fmi3ClockActive`」，之后 FMU 会立即把状态复位成 `fmi3ClockInactive`。
10. 错。参考实现的做法是**先解锁再通知**。若在持锁期间回调，导入端可能需要同一把锁或触发需要该锁的分区，造成死锁。规范没有直接禁止，但明确提醒锁「should be as rare and short as possible」，且举例说明 `fmi3GetClock`、`fmi3GetIntervalDecimal` 都可能被抢占。
11. 错。规范 5.2 节：「In Scheduled Execution, `fmi3Discard` must be treated like `fmi3Error`.」
12. 错。规范：`fmi3GetFMUState` 等「must not be called if any model partition is currently active or preempted」。
13. 错。规范 5.4 节：「The element `<ScheduledExecution>` does not have any attributes other than defined as common capability flags.」所有调度信息都在 `<Clock>` 上。
14. 对。规范：「In Scheduled Execution this return value means that the corresponding model partition cannot be scheduled yet.」
15. 对。规范 5.1 节推荐 rate monotonic scheduling：「smallest period leads to highest priority, that is, has the smallest priority value」。

</details>

---

## 下一章

第三部分到此结束。我们已经把 FMI 3.0 的三种接口走了一遍：

- **ME**：导入端积分，FMU 提供导数。
- **CS**：FMU 积分，导入端在通信点交换数据。
- **SE**：导入端调度，FMU 提供可被调用的模型分区。

第四部分开始动手：自己写一个最小 FMU，从 `BouncingBall` 裁剪出骨架，实现必需的导出函数，编译、打包，再用 fmusim 验证。

→ [课程大纲：第四部分 动手实现](README.md)
