# 第 8 章 Co-Simulation

> **第三部分：接口与状态机 · 初稿**
> 对应规范：[4.1 Concepts](../spec-3.0.2/html/index.html#concepts-co-simulation) / [4.2 State Machine](../spec-3.0.2/html/index.html#state-machine-co-simulation) / [4.3 Code Examples](../spec-3.0.2/html/index.html#_code_examples) / [4.4 Schema](../spec-3.0.2/html/index.html#co-simulation-schema)
> 预计阅读：45 分钟
> 动手时间：30 分钟

## 学习目标

读完本章，你应该能够：

1. 说清 Co-Simulation（CS）中 FMU 与导入端的分工，解释为什么 CS 没有 `fmi3GetContinuousStates` 和 `fmi3GetEventIndicators`。
2. 画出 CS 从实例化到终止的主调用序列，并区分 `eventModeUsed = true` 与 `false` 两条路径。
3. 正确解释 `fmi3DoStep` 的八个参数，尤其是 `eventHandlingNeeded`、`earlyReturn`、`terminateSimulation`、`lastSuccessfulTime` 四者的区别。
4. 写出对早返回安全的通信循环，知道什么时候把下一个通信点设为 `lastSuccessfulTime`，什么时候保持原计划。
5. 说明中间更新的 get/set 顺序、`intermediateStepFinished` 的含义，以及 `requiredIntermediateVariables` 的作用。
6. 解释通信步长、固定内部步长、输出导数阶数和平滑度标志之间的关系。
7. 使用 `fmi3Set{Interval|Shift}Fraction` 与 decimal 版本，知道哪些 Clock 类型允许设置或查询。
8. 读懂 `simulate_fmi3_cs.c`、`cs_early_return.c`、`cs_event_mode.c`、`cs_intermediate_update.c`，并能指出后两者的简化与缺陷。

第 7 章的 ME 把求解器交给了导入端。本章是另一个极端：

> **CS 的 FMU 自己就是一个完整的仿真器，导入端只负责在通信点上交换数据。**

这句话决定了 CS 的全部 API 形态。导入端不再需要导数、连续状态、事件指示器；它只需要说「从 `t` 开始，走 `h` 秒」，然后检查 FMU 是走完了、提前停了，还是遇到了事件。积分、步长控制、事件定位，全都在 FMU 内部。

但 CS 并没有因此变简单。它把复杂度从「写求解器」转移到了「协调多个仿真器」：通信步长怎么选、早返回怎么接、中间更新怎么用、事件模式开不开、Clock 怎么对齐。本章按这条线索展开。

---

## 8.1 从 ME 到 CS：谁负责什么

先把两种接口的职责摆在一起。

| 职责 | Model Exchange | Co-Simulation |
| --- | --- | --- |
| 连续状态存在哪里 | 导入端 | FMU 内部 |
| 谁积分 | 导入端 | FMU |
| 谁决定内部步长 | 导入端 | FMU |
| 谁定位状态事件 | 导入端 | FMU |
| 导入端能读导数吗 | 能 | 不能（`fmi3GetContinuousStateDerivatives` 不允许） |
| 导入端能读事件指示器吗 | 能 | 不能（`fmi3GetEventIndicators` 不允许） |
| 导入端的主要推进函数 | `fmi3SetTime` + `fmi3GetContinuousStateDerivatives` + `fmi3SetContinuousStates` | `fmi3DoStep` |
| 导入端能看到什么 | 方程、状态、导数、事件指示器 | 通信点上的输入/输出 |
| 信息延迟 | 无（同一时间点立即反馈） | 至少一个通信步（除非用中间更新） |

规范 4.1 对 CS 的描述是：

> The data exchange between FMUs is restricted to discrete communication points $t_i$ (unless IntermediateUpdateMode is used). In the time between two communication points, the subsystem inside an FMU is solved independently by internal means.

这句话里有两个关键词：

- **discrete communication points**：数据交换只发生在离散时刻。
- **solved independently**：通信点之间，FMU 自己说了算。

由此产生一个和 ME 截然不同的性质：**CS 在通信点之间没有直接馈通（direct feedthrough）**。ME 的导入端可以在同一个时间点设置输入、立刻读输出；CS 的导入端设置输入后，必须调用 `fmi3DoStep` 让 FMU 内部推进，才能在下一个通信点看到输出。信息「穿过」FMU 需要时间。

```text
导入端的时间轴
  t0 ─────────── t1 ─────────── t2 ─────────── t3
   │              │              │              │
   │ 设置输入      │ 设置输入      │ 设置输入      │
   │ DoStep(h0)   │ DoStep(h1)   │ DoStep(h2)   │
   ▼              ▼              ▼              ▼
FMU 内部：      [内部步][内部步][内部步] ...
                 ↑
                 中间更新（可选，FMU 主动回调）
```

### 8.1.1 联合仿真算法不在规范里

规范只规定 FMU 的接口，不规定导入端怎么协调多个 FMU。下面这些事情都是**导入端**的责任：

- 推进全局仿真时间。
- 在通信点交换输入和输出。
- 触发输入 Clock。
- 处理事件（如果启用了事件模式）。
- 决定通信步长、是否重做通信步、是否用外推。

所以「CS 怎么用」在不同工具里差别很大。本章讲的是**接口允许什么**，不是某个具体工具的调度策略。

---

## 8.2 CS 的主调用序列

把第 6 章的公共状态机缩到 CS，得到两条分支：

```text
fmi3InstantiateCoSimulation 返回非 NULL
        │
        ▼
   Instantiated
        │ fmi3EnterInitializationMode
        ▼
 InitializationMode
        │ fmi3ExitInitializationMode
        ├──────────────────────────────┐
        │ eventModeUsed = true         │ eventModeUsed = false
        ▼                              ▼
    EventMode                       StepMode
        │ fmi3UpdateDiscreteStates（至少一次）
        │ fmi3EnterStepMode
        ▼
    StepMode ◀───────────────────────┘
        │
        │ fmi3DoStep  ⇄  IntermediateUpdateMode（回调）
        │ fmi3DoStep  ⇄  EventMode（事件，仅 eventModeUsed = true）
        │
        │ fmi3Terminate
        ▼
    Terminated
        │ fmi3FreeInstance
        ▼
     (实例释放)
```

展开成步骤：

| 步骤 | 调用 | 必需性 | 说明 |
| --- | --- | --- | --- |
| 1 | `fmi3InstantiateCoSimulation` | 必需 | 返回 `NULL` 表示失败 |
| 2 | `fmi3EnterConfigurationMode` | 可选 | 修改 `structuralParameter` |
| 3 | `fmi3EnterInitializationMode` | 必需 | 给出 `startTime`、`stopTime`、容差 |
| 4 | `fmi3Set{VariableType}` | 按需 | 设置参数、输入、`initial="exact"` 的变量 |
| 5 | `fmi3ExitInitializationMode` | 必需 | 进入 `EventMode` 或 `StepMode` |
| 6 | `fmi3UpdateDiscreteStates` | 事件模式下必需 | 初始事件迭代，至少一次 |
| 7 | `fmi3EnterStepMode` | 事件模式下必需 | 从 `EventMode` 进入 `StepMode` |
| 8 | `fmi3Set{VariableType}` | 每步按需 | 设置通信点上的输入 |
| 9 | `fmi3DoStep` | 必需 | 推进一个通信步 |
| 10 | `fmi3EnterEventMode` | 事件时 | 仅 `eventModeUsed = true` |
| 11 | `fmi3UpdateDiscreteStates` | 事件时 | 事件迭代，直到收敛 |
| 12 | `fmi3EnterStepMode` | 事件后 | 回到 `StepMode` |
| 13 | `fmi3Terminate` | 正常结束时 | 进入 `Terminated` |
| 14 | `fmi3FreeInstance` | 必需 | 释放实例 |

注意第 6、7 步：**只有 `eventModeUsed = true` 才需要**。如果实例化时传了 `fmi3False`，`fmi3ExitInitializationMode` 直接把状态切到 `StepMode`，此时再调用 `fmi3EnterStepMode` 或 `fmi3UpdateDiscreteStates` 都是非法的。

### 8.2.1 实例化参数

```c
typedef fmi3Instance fmi3InstantiateCoSimulationTYPE(
    fmi3String                     instanceName,
    fmi3String                     instantiationToken,
    fmi3String                     resourcePath,
    fmi3Boolean                    visible,
    fmi3Boolean                    loggingOn,
    fmi3Boolean                    eventModeUsed,
    fmi3Boolean                    earlyReturnAllowed,
    const fmi3ValueReference       requiredIntermediateVariables[],
    size_t                         nRequiredIntermediateVariables,
    fmi3InstanceEnvironment        instanceEnvironment,
    fmi3LogMessageCallback         logMessage,
    fmi3IntermediateUpdateCallback intermediateUpdate);
```

和 ME 相比，多了五个 CS 专属参数：

| 参数 | 作用 | 约束 |
| --- | --- | --- |
| `eventModeUsed` | 导入端是否使用 `EventMode` | 只有 XML 的 `hasEventMode="true"` 才能设 `true`；否则 FMU 必须报错 |
| `earlyReturnAllowed` | 导入端是否允许 FMU 早返回 | 为 `false` 时，FMU 必须走完整个通信步 |
| `requiredIntermediateVariables` | 导入端希望在中间更新中访问的变量 | 必须是 XML 中 `intermediateUpdate="true"` 的连续变量 |
| `nRequiredIntermediateVariables` | 上者长度 | 没有中间变量时为 `0` |
| `intermediateUpdate` | 中间更新回调 | 为 `NULL` 表示不支持中间更新 |

还有两个公共参数值得复习：

- `instanceEnvironment`：回调时原样传回，通常放导入端的上下文指针。
- `logMessage`：日志回调；`loggingOn = false` 时可以不提供。

### 8.2.2 最小可运行骨架

`examples/reference-fmus/examples/simulate_fmi3_cs.c` 是最小示例：

```c
CALL(FMI3InstantiateCoSimulation(S,
    INSTANTIATION_TOKEN, // instantiationToken
    resourcePath(),      // resourcePath
    fmi3False,           // visible
    fmi3False,           // loggingOn
    fmi3False,           // eventModeUsed
    fmi3False,           // earlyReturnAllowed
    NULL,                // requiredIntermediateVariables
    0,                   // nRequiredIntermediateVariables
    NULL                 // intermediateUpdate
));

CALL(FMI3EnterInitializationMode(S, fmi3False, 0.0, startTime, fmi3True, stopTime));
CALL(FMI3ExitInitializationMode(S));

for (uint64_t step = 0;; step++) {

    const fmi3Float64 time = step * h;

    CALL(recordVariables(S, time, outputFile));
    CALL(applyContinuousInputs(S, time, false));
    CALL(applyDiscreteInputs(S, time));

    if (time >= stopTime) {
        break;
    }

    CALL(FMI3DoStep(S, time, h, fmi3True,
                    &eventEncountered, &terminateSimulation,
                    &earlyReturn, &lastSuccessfulTime));
}
```

这段代码有四个刻意的简化，后面会逐一说明：

1. `eventModeUsed = false`，FMU 内部处理事件。
2. `earlyReturnAllowed = false`，FMU 不允许早返回。
3. 不使用中间更新。
4. 通信步长固定，且等于 FMU 的固定内部步长。

---

## 8.3 `fmi3DoStep`：一次通信步

### 8.3.1 签名

```c
typedef fmi3Status fmi3DoStepTYPE(fmi3Instance instance,
                                  fmi3Float64 currentCommunicationPoint,
                                  fmi3Float64 communicationStepSize,
                                  fmi3Boolean noSetFMUStatePriorToCurrentPoint,
                                  fmi3Boolean* eventHandlingNeeded,
                                  fmi3Boolean* terminateSimulation,
                                  fmi3Boolean* earlyReturn,
                                  fmi3Float64* lastSuccessfulTime);
```

它是**唯一**能从外部改变 CS FMU 时间的函数。ME 的 `fmi3SetTime` 不在 CS 的可用函数集里。

### 8.3.2 输入参数

| 参数 | 含义 | 约束 |
| --- | --- | --- |
| `currentCommunicationPoint` | 当前通信点 $t_i$ | 第一次调用必须等于 `startTime` |
| `communicationStepSize` | 通信步长 $h_i$ | 必须 $> 0$ |
| `noSetFMUStatePriorToCurrentPoint` | 导入端承诺不再回到当前点之前 | 用于 FMU 释放旧状态/缓冲区 |

`currentCommunicationPoint` 和 `communicationStepSize` 一起表达目标时间：

```text
t_{i+1} = currentCommunicationPoint + communicationStepSize
```

规范特意把两者都传进来，而不是只传一个「目标时间」，是为了避免导入端和 FMU 各自累加时间造成舍入误差。

### 8.3.3 四个输出参数

| 输出 | 含义 | 导入端动作 |
| --- | --- | --- |
| `eventHandlingNeeded` | FMU 在 `lastSuccessfulTime` 遇到事件 | 调用 `fmi3EnterEventMode`（仅 `eventModeUsed = true`） |
| `terminateSimulation` | FMU 请求终止 | 走终止流程 |
| `earlyReturn` | FMU 没有走到目标时间 | 用 `lastSuccessfulTime` 作为下一个通信点 |
| `lastSuccessfulTime` | FMU 返回时的内部时间 | 记录输出、决定下一步起点 |

这四个输出经常被混为一谈。用一句话区分：

- `eventHandlingNeeded` 说「有事件，需要你处理」。
- `earlyReturn` 说「我没走完，停在这里了」。
- `terminateSimulation` 说「别走了，结束」。
- `lastSuccessfulTime` 说「我实际走到了这里」。

它们可以组合。最常见的是「遇到事件 + 早返回」：

```text
eventHandlingNeeded = true
earlyReturn         = true
lastSuccessfulTime  = 0.453
```

也可能只有早返回、没有事件：

```text
eventHandlingNeeded = false
earlyReturn         = true
lastSuccessfulTime  = 0.12
```

原因是导入端在中间更新里请求了提前停止，或者 FMU 需要一个额外的通信点来避免输入外推导致的不一致。

### 8.3.4 `lastSuccessfulTime` 不等于「目标时间」

规范明确允许两种情况：

1. `earlyReturn = true` 时，`lastSuccessfulTime` 一定小于目标时间（也可能等于 `currentCommunicationPoint`）。
2. 即使 `earlyReturn = false`、返回 `fmi3OK`，`lastSuccessfulTime` 也允许偏离目标时间。

第二种常被忽略。规范给的例子是：

- FMU 内部是固定步长积分器，无法精确落在目标时间。
- FMU 内部是变步长积分器，最小步长使它无法刚好落在目标时间。

所以导入端不能假设：

```c
/* 错误：忽略了 lastSuccessfulTime */
time = time + h;
```

也不能无条件假设：

```c
/* 也不总是对的：正常完成时应保持原通信点调度 */
time = lastSuccessfulTime;
```

正确的规则是：

| 情况 | 下一个 `currentCommunicationPoint` |
| --- | --- |
| `earlyReturn = true` | `lastSuccessfulTime`（FMU 确实停在这里） |
| `earlyReturn = false` | 原计划的目标时间 `t_i + h_i` |

为什么正常完成时不用 `lastSuccessfulTime`？因为通信点是**导入端调度的**，`lastSuccessfulTime` 只是 FMU 内部时间的实际值。它可能比目标时间早或晚一点点，但如果导入端把调度点改成这个带误差的值，通信点会逐渐漂移。早返回则不同：FMU 明确表示「这一步没完成」，导入端必须插入一个新的通信点。

> **实践建议**：让通信步长是 `fixedInternalStepSize` 的整数倍。这样正常完成时 `lastSuccessfulTime` 通常等于目标时间，两种写法不会冲突。Reference 的 CS 示例大多这样做。

### 8.3.5 早返回不是错误

规范对 `earlyReturn` 有一条硬约束：

> `earlyReturn = true` must not be used to signal that the requested step was not completed due to an error. Instead, the function must return with an error code (`fmi3Error` or `fmi3Fatal`). Alternatively, the function can return with `fmi3Discard`, if the FMU is in the same state as before the call.

三种「没走完」要分清：

| 返回 | 含义 | 导入端动作 |
| --- | --- | --- |
| `fmi3OK` + `earlyReturn = true` | 正常提前停止 | 从 `lastSuccessfulTime` 继续 |
| `fmi3Discard` | 这一步被丢弃，FMU 状态回到调用前 | 可以重试、缩小步长或换输入 |
| `fmi3Error` / `fmi3Fatal` | 出错 | 终止或降级处理 |

`fmi3Discard` 是 CS 特有的「可重试失败」。它和早返回的区别是：早返回时 FMU 已经推进到 `lastSuccessfulTime`，输出有效；`fmi3Discard` 时 FMU 回到调用前的状态，输出未定义。

### 8.3.6 第一次调用与后续调用

规范只硬性规定第一次：

> At the first call of `fmi3DoStep`, `currentCommunicationPoint` must be equal to the argument `startTime` of `fmi3EnterInitializationMode`.

后续调用没有一句「必须等于上一次的 `lastSuccessfulTime`」，但逻辑上必须连续。Reference 实现的做法是维护一个内部 `nextCommunicationPoint`，并在每次 `fmi3DoStep` 开头检查：

```c
if (!isClose(currentCommunicationPoint, S->nextCommunicationPoint)) {
    logError(S, "Expected currentCommunicationPoint = %.16g but was %.16g.",
        S->nextCommunicationPoint, currentCommunicationPoint);
    CALL(Error);
}
```

这个检查不是规范要求，但它揭示了一个重要事实：**FMU 对「下一个通信点在哪」有自己的预期**。导入端如果随便传一个时间，Reference 会直接报错。实验 5 会看到一个真实的例子。

---

## 8.4 早返回：为什么、什么时候、怎么接

### 8.4.1 三个原因

规范列出早返回的三类原因：

1. **FMU 内部发生事件**，输出发生不连续变化。
2. **导入端在中间更新中请求停止**（`earlyReturnRequested = true`）。
3. **FMU 请求一个额外的通信点**，例如输出极值、避免输入外推导致的负压等。

第一类最常见。BouncingBall 每次撞地都是一个事件；如果允许早返回，FMU 会停在撞地的那一刻，而不是走完整个通信步。

### 8.4.2 能力标志

| 标志 | 位置 | 含义 |
| --- | --- | --- |
| `earlyReturnAllowed` | 实例化参数 | 导入端是否允许早返回 |
| `mightReturnEarlyFromDoStep` | XML | FMU 声明自己可能早返回 |
| `canReturnEarlyAfterIntermediateUpdate` | XML | FMU 是否支持响应中间更新里的早返回请求 |

`earlyReturnAllowed = false` 时，FMU 必须走完整个通信步，即使内部有事件。它只能在通信步内部处理事件，然后把 `eventHandlingNeeded` 留到步末（如果启用了事件模式），或者完全内部处理（如果没启用）。

`mightReturnEarlyFromDoStep = false` 时，导入端可以假设 FMU 不会早返回。但反过来，`true` 也不保证每次都会早返回。

### 8.4.3 时间线

```text
t_i = 0.45                    目标 0.46
   │                             │
   │──── 内部步 ────│            │
   │                 │            │
   │              0.453          │
   │            earlyReturn=true │
   ▼                 ▼            ▼
   ├─────────────────┤────────────┤
   已完成的通信步      未完成的部分
```

下一次调用必须从 `0.453` 开始，而不是 `0.46`：

```c
/* 正确 */
time = lastSuccessfulTime;   /* 0.453 */

/* 错误：跳过了 0.453 到 0.46 之间的事件后区间 */
time = 0.46;
```

### 8.4.4 对早返回安全的循环

把前面的规则合起来，得到一个健壮的通信循环：

```c
fmi3Float64 t = startTime;
const fmi3Float64 hNominal = 0.01;

while (t < stopTime) {

    /* 不要越过 stopTime */
    const fmi3Float64 h = fmin(hNominal, stopTime - t);

    fmi3Boolean eventNeeded;
    fmi3Boolean terminate;
    fmi3Boolean early;
    fmi3Float64 last;

    const fmi3Status status = fmi3DoStep(fmu, t, h, fmi3True,
                                         &eventNeeded, &terminate,
                                         &early, &last);

    if (status != fmi3OK && status != fmi3Warning) {
        /* fmi3Discard / fmi3Error / fmi3Fatal */
        handleError(status);
        break;
    }

    recordOutputs(fmu, last);

    if (terminate) {
        break;
    }

    if (eventNeeded) {
        fmi3EnterEventMode(fmu);
        /* 设置离散输入、触发输入 Clock */
        fmi3Boolean needUpdate = fmi3True;
        while (needUpdate) {
            fmi3UpdateDiscreteStates(fmu, &needUpdate, &terminate,
                                     &nominalsChanged, &statesChanged,
                                     &nextEventTimeDefined, &nextEventTime);
            if (terminate) break;
        }
        fmi3EnterStepMode(fmu);
    }

    if (early) {
        if (last == t && !eventNeeded) {
            /* 没有事件、也没有前进：防止死循环 */
            handleNoProgress();
            break;
        }
        t = last;          /* 早返回：插入新的通信点 */
    } else {
        t = t + h;         /* 正常完成：保持原调度 */
    }
}
```

这段代码有几个容易写错的地方：

1. **`h` 不能超过 `stopTime - t`**。否则 FMU 可能因为目标时间超过 `stopTime` 而报错（Reference 就会）。
2. **先处理事件，再决定下一个 `t`**。事件处理可能改变状态，但不会改变 `lastSuccessfulTime`。
3. **`early && last == t && !eventNeeded` 是死循环信号**。FMU 没有前进，也没有事件可处理，再调用一次大概率还是原地不动。
4. **正常完成时不要用 `last` 替换 `t + h`**。除非你确认 FMU 的 `lastSuccessfulTime` 就是它的下一个通信点预期。

> **注意**：第 4 条在不同 FMU 上可能有不同实践。有些导入端无条件使用 `lastSuccessfulTime`，并在下一步把 `h` 调成 `stopTime - last`。只要 FMU 接受这个时间，就不违反规范。关键是**不要在没有检查的情况下把两者混用**。

### 8.4.5 读 `cs_early_return.c`

`examples/reference-fmus/examples/cs_early_return.c` 是最小早返回示例：

```c
CALL(FMI3InstantiateCoSimulation(S,
    INSTANTIATION_TOKEN,
    NULL,                // resourcePath
    fmi3False,           // visible
    fmi3False,           // loggingOn
    fmi3False,           // eventModeUsed
    fmi3True,            // earlyReturnAllowed
    NULL,                // requiredIntermediateVariables
    0,                   // nRequiredIntermediateVariables
    NULL                 // intermediateUpdate
));

fmi3Float64 time = startTime;

CALL(FMI3EnterInitializationMode(S, fmi3False, 0.0, time, fmi3True, stopTime));
CALL(FMI3ExitInitializationMode(S));

const fmi3Float64 stepSize = 10 * FIXED_SOLVER_STEP;   // 0.01

while (true) {

    CALL(applyContinuousInputs(S, time, true));
    CALL(applyDiscreteInputs(S, time));
    CALL(recordVariables(S, time, outputFile));

    if (terminateSimulation || time + stepSize > stopTime) {
        break;
    }

    CALL(FMI3DoStep(S,
        time,                 // currentCommunicationPoint
        stepSize,             // communicationStepSize
        fmi3True,             // noSetFMUStatePriorToCurrentPoint
        &eventEncountered,    // eventHandlingNeeded
        &terminateSimulation,
        &earlyReturn,
        &time                 // lastSuccessfulTime
    ));
}
```

注意它把 `&time` 同时用作 `currentCommunicationPoint` 的输入和 `lastSuccessfulTime` 的输出。这在早返回时是正确的：FMU 写入新的时间，下一轮直接用。但如果 `time` 在调用后被别的代码修改，就会出问题——实验 5 会展示这种错误。

这个示例的 `eventModeUsed = false`，所以：

- `eventEncountered` 永远是 `false`（规范禁止在无事件模式时报告事件）。
- 早返回是导入端知道「FMU 内部发生了事件」的唯一信号。
- 导入端不需要进入 `EventMode`，事件由 FMU 内部处理。

---

## 8.5 中间更新：通信步内部的对话

### 8.5.1 它解决什么问题

标准 CS 只在通信点交换数据。如果两个 FMU 用 10 ms 通信步，它们之间的耦合信息每 10 ms 才更新一次。对于强耦合系统，这会导致不稳定或精度损失。

中间更新允许 FMU 在通信步内部主动回调导入端，交换输入/输出，而不结束整个通信步。它适合：

- 输入/输出的多项式外推；
- 传输线建模（TLM）；
- 抗混叠滤波；
- 输入平滑；
- 在事件发生前让其他 FMU 看到中间输出。

规范明确指出：中间更新是 **FMU 主动发起**的，导入端不能要求进入 `IntermediateUpdateMode`。

### 8.5.2 回调签名

```c
typedef void (*fmi3IntermediateUpdateCallback) (
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3Float64  intermediateUpdateTime,
    fmi3Boolean  intermediateVariableSetRequested,
    fmi3Boolean  intermediateVariableGetAllowed,
    fmi3Boolean  intermediateStepFinished,
    fmi3Boolean  canReturnEarly,
    fmi3Boolean* earlyReturnRequested,
    fmi3Float64* earlyReturnTime);
```

| 参数 | 方向 | 含义 |
| --- | --- | --- |
| `instanceEnvironment` | 输入 | 实例化时传入的上下文指针 |
| `intermediateUpdateTime` | 输入 | FMU 当前内部时间，限制在 `[t_i, t_i + h_i]` |
| `intermediateVariableSetRequested` | 输入 | 导入端是否可以设置中间输入 |
| `intermediateVariableGetAllowed` | 输入 | 导入端是否可以读取中间输出 |
| `intermediateStepFinished` | 输入 | 当前内部步是「已接受」还是「试探性」 |
| `canReturnEarly` | 输入 | FMU 是否支持响应早返回请求 |
| `earlyReturnRequested` | 输出 | 导入端是否请求提前结束当前 `fmi3DoStep` |
| `earlyReturnTime` | 输出 | 希望 FMU 停在哪个时间 |

### 8.5.3 状态进入与退出

- FMU 在 `StepMode` 中调用回调，进入 `IntermediateUpdateMode`。
- 回调返回后，FMU 回到 `StepMode`。
- 导入端不能主动进入或退出这个状态。

规范对时间有一条单调性约束：

> The FMU must not call the callback function with an `intermediateUpdateTime` that is smaller than the `intermediateUpdateTime` given in a previous call with `intermediateStepFinished = fmi3True`.

也就是说，已接受的内部步时间不能倒退；试探性步可以回退重算。

### 8.5.4 回调里能做什么

| 操作 | 条件 |
| --- | --- |
| `fmi3Get{VariableType}` 读中间输出 | `intermediateVariableGetAllowed = true` |
| `fmi3Set{VariableType}` 写中间输入 | `intermediateVariableSetRequested = true` |
| `fmi3GetOutputDerivatives` | 只能对允许读取的中间变量 |
| 设置离散输入 | **禁止** |
| 设置 Clock | **禁止**（Clock 只在 `EventMode` 活跃） |

顺序也有规定：**先完成所有 Get，再开始 Set**。这和 `StepMode` 中「Get 不能跟在 Set 后面而不调用 DoStep」的规则同源。

> **Reference 实现注意**：`examples/reference-fmus/src/fmi3Functions.c` 把 `fmi3GetOutputDerivatives` 的状态掩码写成 `StepMode | StepDiscarded | Terminated`，不包含 `IntermediateUpdateMode`，并且 `BEGIN_FUNCTION` 会真的检查掩码。所以在 Reference FMU 的回调里调用它会被拒绝。规范 4.2 节的 `IntermediateUpdateMode` 允许列表是包含 `fmi3GetOutputDerivatives` 的，冲突时以规范为准。

### 8.5.5 哪些变量能访问

两个条件必须同时满足：

1. XML 中该变量有 `intermediateUpdate="true"`。
2. 该变量的 value reference 出现在 `requiredIntermediateVariables` 里。

BouncingBall 的 `h` 和 `v` 都满足第一条：

```xml
<Float64 name="h" valueReference="1" causality="output" variability="continuous"
         initial="exact" declaredType="Position" start="1" reinit="true"
         intermediateUpdate="true"/>
<Float64 name="v" valueReference="3" causality="output" variability="continuous"
         initial="exact" declaredType="Velocity" start="0" reinit="true"
         intermediateUpdate="true"/>
```

但 `cs_intermediate_update.c` 实例化时传的是：

```c
NULL,                // requiredIntermediateVariables
0,                   // nRequiredIntermediateVariables
```

然后在回调里直接 `fmi3GetFloat64` 读 `h`、`v`。**这不符合规范**：没有把变量列入 `requiredIntermediateVariables`，导入端就不应该访问它们。Reference 实现没有强制检查，所以能跑；生产导入端不应照抄。

### 8.5.6 `intermediateStepFinished`：试探 vs 已接受

这是中间更新里最容易被忽略的字段。

| 值 | 含义 | 导入端可以做什么 |
| --- | --- | --- |
| `fmi3False` | 当前是试探性内部步，输出可能还会变 | 可以读，但不要当作最终结果转发 |
| `fmi3True` | 当前内部步已被接受 | 可以安全地把输出转发给其他 FMU |

规范的解释是：变步长求解器可能先试一个步长，发现误差太大就回退重算。回退前产生的输出是「试探性」的，不能当真。只有 `intermediateStepFinished = true` 的输出才是可信的。

### 8.5.7 在回调里请求早返回

如果 `canReturnEarly = true`，导入端可以设置：

```c
*earlyReturnRequested = fmi3True;
*earlyReturnTime = t_stop;
```

约束：

- 只有 `canReturnEarly = true` 时才能请求。
- `earlyReturnTime` 必须在 `[currentCommunicationPoint, currentCommunicationPoint + communicationStepSize]` 内。
- 如果 `earlyReturnTime` 大于当前 `intermediateUpdateTime`，FMU 可以继续算到那个时间。
- FMU 是否真的响应，还取决于 XML 的 `canReturnEarlyAfterIntermediateUpdate`。

如果导入端不请求，必须把 `earlyReturnRequested` 设为 `fmi3False`，不要留下未初始化的值。

### 8.5.8 读 `cs_intermediate_update.c`

回调本身写得很清楚：

```c
void intermediateUpdate(fmi3InstanceEnvironment instanceEnvironment,
                        fmi3Float64 intermediateUpdateTime,
                        fmi3Boolean intermediateVariableSetRequested,
                        fmi3Boolean intermediateVariableGetAllowed,
                        fmi3Boolean intermediateStepFinished,
                        fmi3Boolean canReturnEarly,
                        fmi3Boolean* earlyReturnRequested,
                        fmi3Float64* earlyReturnTime) {

    FMIInstance *S = (FMIInstance *)instanceEnvironment;

    *earlyReturnRequested = fmi3False;
    *earlyReturnTime = 0;

    if (intermediateVariableGetAllowed) {
        recordVariables(S, intermediateUpdateTime, outputFile);

        if (intermediateStepFinished) {
            /* 把输出转发给其他 FMU，或写入结果文件 */
        }
    }

    if (intermediateVariableSetRequested) {
        /* 计算并设置中间输入 */
    }
}
```

它遵守了「先 Get 后 Set」和「初始化输出参数」两条规则。问题在主循环：

```c
CALL(FMI3DoStep(S,
    time,                 // currentCommunicationPoint
    stepSize,
    fmi3True,
    &eventEncountered,
    &terminateSimulation,
    &earlyReturn,
    &time                 // lastSuccessfulTime
));

time += stepSize;         // ← 覆盖了 FMU 刚写入的时间
```

`time` 既作为输入传给 `fmi3DoStep`，又作为 `lastSuccessfulTime` 的输出指针。第一次调用后，FMU 把 `0.01` 写进 `time`；紧接着 `time += stepSize` 把它改成 `0.02`。第二次调用传入 `currentCommunicationPoint = 0.02`，而 Reference 内部期望 `0.01`，于是报错：

```text
fmi3DoStep(currentCommunicationPoint=0.02, communicationStepSize=0.01, ...,
           lastSuccessfulTime=0.02) -> Error
```

这不是 FMU 的问题，是导入端把「输出参数」和「下一步输入」混用了。正确写法是：

```c
fmi3Float64 last = 0;

CALL(FMI3DoStep(S, time, stepSize, fmi3True,
                &eventEncountered, &terminateSimulation,
                &earlyReturn, &last));

time = last;              // 只信 FMU 写回的值，不再加 stepSize
```

---

## 8.6 事件处理：`eventModeUsed` 的两条路径

### 8.6.1 路径 A：`eventModeUsed = true`

前提是 XML 的 `hasEventMode="true"`。流程：

```text
ExitInitializationMode
        │
        ▼
    EventMode
        │ 初始 UpdateDiscreteStates 循环
        │ EnterStepMode
        ▼
    StepMode
        │ DoStep
        │ eventHandlingNeeded = true
        ▼
    EventMode
        │ 设置离散输入 / 触发输入 Clock
        │ UpdateDiscreteStates 循环
        │ EnterStepMode
        ▼
    StepMode
```

事件模式由导入端显式驱动。规范列出四种必须调用 `fmi3EnterEventMode` 的情况：

1. 时间到达 `fmi3UpdateDiscreteStates` 返回的 `nextEventTime`。
2. `fmi3DoStep` 返回 `eventHandlingNeeded = true`。
3. 导入端计划对输入做离散修改。
4. 需要设置输入 Clock。

在 `EventMode` 中，导入端可以：

- 设置 `input` 和 `tunable` 参数（公共状态机还允许设置 `reinit="false"` 的连续状态，但 CS 没有状态访问 API，这条只在 ME 中有实际意义）；
- 读写 Clock；
- 调用 `fmi3UpdateDiscreteStates`；
- 调用 `fmi3GetInterval` / `fmi3GetShift` 查询 Clock 的下一个间隔。

不能做：

- `fmi3GetContinuousStates`（CS 不允许）；
- `fmi3GetContinuousStateDerivatives`（CS 不允许）；
- `fmi3GetEventIndicators`（CS 不允许）；
- `fmi3DoStep`（只在 `StepMode`）。

`fmi3UpdateDiscreteStates` 的 `nominalsOfContinuousStatesChanged` 和 `valuesOfContinuousStatesChanged` 在 CS 中**无效**。规范写明这两个输出只在 ME 中有效。CS 导入端可以忽略它们，但仍然要传非 `NULL` 指针（Reference 的实现会解引用）。

### 8.6.2 路径 B：`eventModeUsed = false`

如果导入端不想实现事件模式，可以传 `fmi3False`。此时：

- `fmi3ExitInitializationMode` 直接进入 `StepMode`。
- FMU 必须在内部检测并处理所有事件。
- `fmi3DoStep` **不得**返回 `eventHandlingNeeded = true`。
- 导入端不能调用 `fmi3EnterEventMode`。
- 时间事件、状态事件都由 FMU 内部处理；导入端不进入 `EventMode`，也就用不到 `nextEventTime`（它只通过 `fmi3UpdateDiscreteStates` 返回，而后者在这条路径上不需要调用）。

这条路径适合「FMU 是黑盒、导入端不想管事件」的场景。代价是导入端看不到事件前后的输出跳变，只能看到通信点上的结果。

### 8.6.3 两条路径对比

| 特性 | `eventModeUsed = true` | `eventModeUsed = false` |
| --- | --- | --- |
| 初始状态 | `EventMode` | `StepMode` |
| 初始 `UpdateDiscreteStates` | 必需 | 不需要 |
| 事件检测 | FMU 报告，导入端处理 | FMU 内部处理 |
| `eventHandlingNeeded` | 可以为 `true` | 必须为 `false` |
| `fmi3EnterEventMode` | 允许 | 禁止 |
| 导入端能看到事件前后的值 | 能 | 只能看到通信点 |
| 适合 | 需要精确事件处理、Clock | 简单黑盒联合仿真 |

### 8.6.4 输入事件

输入事件是导入端主动造成的。分两种：

- **离散输入变化**：必须在 `EventMode` 中设置（`eventModeUsed = true`），或者至少在通信点设置（`eventModeUsed = false`，由 FMU 内部处理）。
- **连续输入跳变**：如果 FMU 支持事件模式，导入端应该进入 `EventMode`，告诉 FMU 这是一个不连续变化。规范 4.1 明确说：

> If a continuous input changes discontinuously ..., the co-simulation algorithm of the importer must raise an event (if supported) to indicate to the FMU a discontinuous change of a continuous input.

如果 FMU 不支持事件模式，导入端只能靠启发式（heuristics）判断，比如检测输入变化率是否超过阈值。规范承认这一点，但不提供具体算法。

### 8.6.5 时间事件

如果 `eventModeUsed = true`，FMU 通过 `fmi3UpdateDiscreteStates` 的 `nextEventTime` 预告下一个时间事件。导入端必须确保仿真推进到至少 `nextEventTime`，然后调用 `fmi3EnterEventMode`。

如果 `eventModeUsed = false`，FMU 自己在内部处理时间事件。它仍然可以在 `fmi3DoStep` 中早返回，告诉导入端「我停在一个事件上了」，但不需要导入端进入事件模式。

### 8.6.6 Reference 实现的事件分支

`examples/reference-fmus/src/fmi3Functions.c` 的 `fmi3DoStep` 里有一段关键分支：

```c
#ifdef EVENT_UPDATE
if (stateEvent || timeEvent) {

    if (S->eventModeUsed) {
        *eventHandlingNeeded = fmi3True;
    } else {
        CALL(eventUpdate(S));
#if MAX_EVENT_INDICATORS > 0
        CALL(getEventIndicators(S, S->prez, S->nz));
#endif
    }

    if (S->earlyReturnAllowed) {
        break;
    }
}
#endif
```

它揭示了 Reference 的两个实现细节：

1. `eventModeUsed = false` 时，FMU 内部调用 `eventUpdate`，并刷新事件指示器的基准 `prez`。
2. `eventModeUsed = true` 时，FMU 只设置 `eventHandlingNeeded`，**不刷新 `prez`**。它假设事件处理会由导入端在 `EventMode` 中完成，但在 `fmi3UpdateDiscreteStates` 里并没有刷新 `prez`。

这会导致一个可观察的副作用：每次真实碰撞后，下一次 `fmi3DoStep` 会再报一次「事件」。第 8.12 节的实验 3 会看到 12 次碰撞产生 24 次 `EnterEventMode`。这是 Reference 实现的缺陷，不是规范要求的行为。导入端仍然应该把每一次 `eventHandlingNeeded = true` 当作真实事件处理，因为它无法访问 `prez`，也无从判断哪一次是多余的。

---

## 8.7 通信步长、内部步长与输出导数

### 8.7.1 三个时间概念

| 概念 | 谁决定 | 说明 |
| --- | --- | --- |
| 通信步长 `h_i` | 导入端 | `fmi3DoStep` 的参数，必须 $> 0$ |
| 内部步长 | FMU | 通信步内部的积分步，可能固定也可能自适应 |
| 中间更新时间 `t_u` | FMU | `IntermediateUpdateMode` 回调的时刻 |

### 8.7.2 能力标志

| 标志 | 默认 | 含义 |
| --- | --- | --- |
| `canHandleVariableCommunicationStepSize` | `false` | 每次 `fmi3DoStep` 的 `h_i` 是否可以不同 |
| `fixedInternalStepSize` | 无 | FMU 的固定内部步长，供导入端对齐 |
| `maxOutputDerivativeOrder` | `0` | 能提供到几阶输出时间导数 |
| `recommendedIntermediateInputSmoothness` | `0` | 中间输入建议的连续可微阶数 $C^k$ |

如果 `canHandleVariableCommunicationStepSize = false`，导入端必须在整个仿真中使用同一个通信步长。规范没有说死「必须相等」，但语义是「不能变」。

### 8.7.3 对齐固定内部步长

规范建议：

> The importer should use an integer multiple of this value as communication step size.

Reference 的 BouncingBall 声明：

```xml
<CoSimulation
    modelIdentifier="BouncingBall"
    canHandleVariableCommunicationStepSize="true"
    providesIntermediateUpdate="true"
    mightReturnEarlyFromDoStep="true"
    canReturnEarlyAfterIntermediateUpdate="true"
    fixedInternalStepSize="1e-3"
    hasEventMode="true"/>
```

内部步长是 1 ms。`cs_event_mode.c` 和 `cs_early_return.c` 用 10 ms 通信步，正好是 10 倍；`simulate_fmi3_cs.c` 用 1 ms，正好相等。

如果通信步长不是内部步长的整数倍，会发生什么？看 Reference 的 `fmi3DoStep`：

```c
const fmi3Float64 nextSolverStepTime = S->time + FIXED_SOLVER_STEP;

nextCommunicationPointReached =
    nextSolverStepTime > nextCommunicationPoint &&
    !isClose(nextSolverStepTime, nextCommunicationPoint);

if (nextCommunicationPointReached || (*eventHandlingNeeded && S->earlyReturnAllowed)) {
    break;
}
```

它每次只走一个固定内部步，直到「再走一步就会超过通信点」为止。因此 `lastSuccessfulTime` 可能停在通信点之前的一个内部步上，而 `earlyReturn` 仍然是 `false`（因为这一步被算作正常完成）。这就是 8.3.4 说的「正常完成也可能偏离目标时间」。

### 8.7.4 输出导数

CS 导入端可以用 `fmi3GetOutputDerivatives` 获取连续输出的时间导数，用于通信点之间的外推/插值。

```c
typedef fmi3Status fmi3GetOutputDerivativesTYPE(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    const fmi3Int32 orders[],
    fmi3Float64 values[],
    size_t nValues);
```

要点：

- `orders` 是 1 基的：`1` 表示一阶导数，`2` 表示二阶，`0` 不允许。
- 如果同一个变量要取多阶导数，在 `valueReferences` 中重复它的 value reference，并在 `orders` 中对齐。
- `values` 的顺序是「先按 `valueReferences[k]` + `orders[k]` 的组合，再按变量序列化」。
- 只有在 `maxOutputDerivativeOrder >= order` 时才能调用。
- 成功调用 `fmi3DoStep` 后，导数值对应通信步末端。

Reference 的 BouncingBall 二进制实现了 `getOutputDerivative`（一阶：`dh/dt = v`，`dv/dt = g`），但 XML 没有写 `maxOutputDerivativeOrder`。按 XSD 默认值 `0`，导入端**不应该**调用 `fmi3GetOutputDerivatives`。这是「实现有能力，但能力标志没声明」的典型例子：规范以 XML 为准，不以二进制内部实现为准。

### 8.7.5 中间输入的平滑度

`recommendedIntermediateInputSmoothness = k` 表示：如果导入端在通信区间内提供的中间输入是 $C^k$ 连续的，FMU 内部求解器的收敛会更好。

- `k = 0`：连续即可，允许导数跳变。
- `k = 1`：一阶连续，导数也连续。
- `k` 越大，导入端需要越高阶的外推多项式。

这不是硬要求，而是性能提示。导入端可以忽略，但可能看到 FMU 内部步长变小、仿真变慢。

---

## 8.8 输入与 Clock 的 Interval/Shift

### 8.8.1 通信点之间的输入

规范 4.1 规定：

> Between communication points, even in `IntermediateUpdateMode`, all changes must be assumed to be continuous. Changes to continuous variables are only considered discrete in `EventMode`.

这意味着：

- 连续输入在通信点之间必须按连续函数处理（通常是零阶保持或多项式外推）。
- 离散输入在通信点之间保持不变。
- 如果连续输入发生跳变，导入端必须按输入事件处理（如果支持事件模式）。

### 8.8.2 Clock 在 CS 中的位置

Clock 是离散变量，用来同步事件。CS 中：

- `hasEventMode` 必须为 `true` 才能使用 Clock。
- 输入 Clock 由导入端在 `EventMode` 中用 `fmi3SetClock` 激活。
- Clocked 变量只能在对应 Clock 活跃时访问；在 `InitializationMode` 中不受此限制。
- `fmi3SetClock` 在 `StepMode` 中不允许。

> Clock 的完整类型、优先级和 SE 中的用法在第 9 章展开。本节只讲 CS 里必须用到的 Interval/Shift。

### 8.8.3 Interval 与 Shift 的定义

对周期 Clock：

```text
t_0 = startTime + T_shift
t_i = t_{i-1} + T_interval, i = 1, 2, 3, ...
```

- `T_shift`：第一次 tick 相对于 `startTime` 的延迟。
- `T_interval`：相邻两次 tick 的间隔。

两者都可以用两种表示：

| 表示 | 设置函数 | 查询函数 |
| --- | --- | --- |
| 浮点秒 | `fmi3SetIntervalDecimal` / `fmi3SetShiftDecimal` | `fmi3GetIntervalDecimal` / `fmi3GetShiftDecimal` |
| 有理数 `counter / resolution` | `fmi3SetIntervalFraction` / `fmi3SetShiftFraction` | `fmi3GetIntervalFraction` / `fmi3GetShiftFraction` |

Fraction 版本适合表示无法用二进制浮点精确表示的间隔，例如 `1/3` 秒。参数含义：

```c
fmi3SetIntervalFraction(instance,
                        valueReferences, nValueReferences,
                        counters, resolutions);
```

第 `i` 个 Clock 的间隔是：

```text
T_interval[i] = counters[i] / resolutions[i]
```

单位是独立变量的单位（通常是秒）。

### 8.8.4 例子：100 Hz 的周期 Clock

假设一个输入 Clock 的 value reference 是 7，周期 10 ms，第一次 tick 在 0.25 s：

```c
const fmi3ValueReference vrClock = 7;
const fmi3UInt64 intervalCounter = 1;
const fmi3UInt64 intervalResolution = 100;   /* 1/100 s = 10 ms */
const fmi3UInt64 shiftCounter = 1;
const fmi3UInt64 shiftResolution = 4;        /* 1/4 s = 0.25 s */

fmi3SetIntervalFraction(fmu, &vrClock, 1,
                        &intervalCounter, &intervalResolution);

fmi3SetShiftFraction(fmu, &vrClock, 1,
                     &shiftCounter, &shiftResolution);
```

tick 时间就是：

```text
0.25, 0.26, 0.27, 0.28, ...
```

如果 `supportsFraction = false`，必须改用 decimal 版本：

```c
const fmi3Float64 interval = 0.01;
const fmi3Float64 shift = 0.25;

fmi3SetIntervalDecimal(fmu, &vrClock, 1, &interval);
fmi3SetShiftDecimal(fmu, &vrClock, 1, &shift);
```

### 8.8.5 什么时候设置，什么时候查询

不同类型的 Clock 规则不同：

| Clock 类型 | Interval | Shift |
| --- | --- | --- |
| 常量周期（constant periodic） | XML 给出，`InitializationMode` 用 `fmi3GetInterval` 查询 | `InitializationMode` 用 `fmi3GetShift` 查询 |
| 固定周期（fixed periodic） | 有 `intervalDecimal`：`InitializationMode` 用 `fmi3SetInterval` 设置；没有：用 `fmi3GetInterval` 查询 | 初始化时由 XML 的 `shiftCounter` / `shiftDecimal` 给出，或按需用 `fmi3GetShift` 查询 |
| 可调周期（tunable periodic） | 初始化时设置；之后可在 `EventMode` / `ClockActivationMode` 修改 | 只能在初始化时设置或查询 |
| 变化非周期（changing aperiodic） | `InitializationMode` 查询；之后只在 Clock tick 过的 `EventMode` / `ClockActivationMode` 查询 | 不允许 `SetShift` / `GetShift` |
| 倒计时非周期（countdown aperiodic） | 初始化、每个 `EventMode`、每个 `ClockUpdateMode` 都查询 | 不允许 `SetShift` / `GetShift` |
| 触发型（triggered） | 不适用 | 不适用 |

如果 XML 没有给出 `intervalDecimal`，导入端必须在 `InitializationMode` 调用 `fmi3GetInterval` 和 `fmi3GetShift`，因为间隔可能依赖固定参数。注意 `supportsFraction`：只有它为 `true` 时才能调用 fraction 版本。

### 8.8.6 `qualifiers`：下一个间隔已知吗

`fmi3GetIntervalDecimal` / `fmi3GetIntervalFraction` 还有一个 `qualifiers` 输出：

```c
typedef enum {
    fmi3IntervalChanged,
    fmi3IntervalUnchanged,
    fmi3IntervalNotYetKnown
} fmi3IntervalQualifier;
```

| 值 | 含义 | 导入端动作 |
| --- | --- | --- |
| `fmi3IntervalChanged` | 间隔变了 | 重新调度这个 Clock 的模型分区 |
| `fmi3IntervalUnchanged` | 和上次一样 | 保持已有调度 |
| `fmi3IntervalNotYetKnown` | 还不知道（countdown aperiodic） | 暂时不能调度 |

这个枚举在 SE 中尤其重要，第 9 章会用它来安排 `fmi3ActivateModelPartition`。

---

## 8.9 逐段读 `simulate_fmi3_cs.c`

这个文件只有 54 行，是规范 4.3 节「Basic Co-Simulation」的原文。它把所有 CS 导入端的骨架都放进去了。

### 8.9.1 文件名与日志（第 1–5 行）

```c
#define OUTPUT_FILE  xstr(MODEL_IDENTIFIER) "_cs_out.csv"
#define LOG_FILE     xstr(MODEL_IDENTIFIER) "_cs_log.txt"

#include "util.h"
```

`xstr` 是把宏展开成字符串的辅助宏。`MODEL_IDENTIFIER` 来自模型的 `config.h`，所以同一个 `simulate_fmi3_cs.c` 可以编译成 `BouncingBall_cs.exe`、`Dahlquist_cs.exe` 等。

### 8.9.2 实例化（第 12–22 行）

```c
CALL(FMI3InstantiateCoSimulation(S,
    INSTANTIATION_TOKEN,
    resourcePath(),
    fmi3False,           // visible
    fmi3False,           // loggingOn
    fmi3False,           // eventModeUsed
    fmi3False,           // earlyReturnAllowed
    NULL,                // requiredIntermediateVariables
    0,                   // nRequiredIntermediateVariables
    NULL                 // intermediateUpdate
));
```

四个 `fmi3False` 决定了整个示例的行为：

- 不显示窗口；
- 不输出日志到控制台（但 `util.h` 仍然写日志文件）；
- 不用事件模式；
- 不允许早返回。

所以这个示例永远不会进入 `EventMode`，也永远不会看到 `earlyReturn = true`。它是最「平」的 CS 循环。

### 8.9.3 初始化（第 24–28 行）

```c
CALL(applyStartValues(S));

CALL(FMI3EnterInitializationMode(S, fmi3False, 0.0,
                                 startTime, fmi3True, stopTime));

CALL(FMI3ExitInitializationMode(S));
```

注意它没有调用 `fmi3UpdateDiscreteStates`，也没有调用 `fmi3EnterStepMode`。因为 `eventModeUsed = false`，`fmi3ExitInitializationMode` 直接进入 `StepMode`。

如果这里把 `eventModeUsed` 改成 `fmi3True`，就必须补上：

```c
fmi3Boolean needUpdate = fmi3True;
while (needUpdate) {
    fmi3UpdateDiscreteStates(fmu, &needUpdate, ...);
}
fmi3EnterStepMode(fmu);
```

否则第一次 `fmi3DoStep` 会因为状态不对而失败。

### 8.9.4 主循环（第 30–49 行）

```c
for (uint64_t step = 0;; step++) {

    const fmi3Float64 time = step * h;

    CALL(recordVariables(S, time, outputFile));

    CALL(applyContinuousInputs(S, time, false));
    CALL(applyDiscreteInputs(S, time));

    if (time >= stopTime) {
        break;
    }

    CALL(FMI3DoStep(S, time, h, fmi3True,
                    &eventEncountered, &terminateSimulation,
                    &earlyReturn, &lastSuccessfulTime));

    if (terminateSimulation) {
        printf("The FMU requested to terminate the simulation.");
        break;
    }
}
```

几个设计选择：

- **`time = step * h`**：用乘法而不是累加，避免浮点误差累积。
- **先记录输出，再设置输入**：记录的是当前通信点的值，输入影响的是下一步。
- **`time >= stopTime` 在 `DoStep` 之前检查**：保证不会请求超过 `stopTime` 的步。
- **`earlyReturn` 和 `lastSuccessfulTime` 被忽略**：因为 `earlyReturnAllowed = false`，FMU 不会早返回；`h` 又等于内部步长，`lastSuccessfulTime` 通常等于 `time + h`。

这个循环在「固定步长 + 不允许早返回 + 通信步长等于内部步长」三个条件下是正确的。换掉任何一个条件，它都会出问题。

### 8.9.5 终止（第 51–53 行）

```c
TERMINATE:
    return tearDown();
```

`tearDown()` 内部会调用 `fmi3Terminate` 和 `fmi3FreeInstance`（取决于 `util.h` 的实现）。示例把资源释放藏在了辅助函数里，阅读时要注意。

---

## 8.10 四个 CS 示例对照

Reference 提供了四个 CS 导入端，正好覆盖本章的四条主线。

| 示例 | `eventModeUsed` | `earlyReturnAllowed` | 中间更新 | 记录内容 | 规范图 |
| --- | --- | --- | --- | --- | --- |
| `simulate_fmi3_cs.c` | `false` | `false` | 无 | 每个通信点 | Basic Co-Simulation |
| `cs_early_return.c` | `false` | `true` | 无 | 每个通信点，事件后 | Early Return |
| `cs_event_mode.c` | `true` | `true` | 无 | 事件前后都记录 | Event Mode |
| `cs_intermediate_update.c` | `false` | `false` | 有 | 每个内部步 | Intermediate Update |

它们的输出差异正好对应规范 4.3 的四张图：

- **Basic**：通信步 0.1 s 时，撞地点被完全错过，因为输出只在通信点采样。
- **Early Return**：撞地点可见，但只记录事件后的值；事件前的接触值没有。
- **Event Mode**：撞地点前后都记录，能看到 `h` 从负值跳到 `DBL_MIN`。
- **Intermediate Update**：每个内部步都记录，曲线最密，但示例本身有一个时间指针 bug。

> **步长提醒**：上面四条对应规范 4.3 的图，那些图用 0.1 s 通信步。Reference 编译出的 `BouncingBall_cs.exe` 用的是 `simulate_fmi3_cs.c` 里的 `h = FIXED_SOLVER_STEP = 1 ms`，所以实验 2 会得到 3001 行、能捕获事件；这不是矛盾，而是通信步长不同。0.1 s 的「错过事件」是我们用实验 2 的 `on 0.1 s grid = 0` 反推出来的结论。

---

## 8.11 XML 与 CS 能力标志

### 8.11.1 一个完整的 `<CoSimulation>` 元素

```xml
<CoSimulation
    modelIdentifier="BouncingBall"
    canGetAndSetFMUState="true"
    canSerializeFMUState="true"
    canHandleVariableCommunicationStepSize="true"
    providesIntermediateUpdate="true"
    mightReturnEarlyFromDoStep="true"
    canReturnEarlyAfterIntermediateUpdate="true"
    fixedInternalStepSize="1e-3"
    hasEventMode="true"/>
```

### 8.11.2 CS 专属属性

| 属性 | 默认 | 含义 |
| --- | --- | --- |
| `canHandleVariableCommunicationStepSize` | `false` | 通信步长是否可变 |
| `fixedInternalStepSize` | 无 | 固定内部步长 |
| `maxOutputDerivativeOrder` | `0` | 输出导数的最高阶 |
| `recommendedIntermediateInputSmoothness` | `0` | 建议的中间输入平滑度 $C^k$ |
| `providesIntermediateUpdate` | `false` | 是否支持中间更新 |
| `mightReturnEarlyFromDoStep` | `false` | 是否可能早返回 |
| `canReturnEarlyAfterIntermediateUpdate` | `false` | 是否响应中间更新里的早返回请求 |
| `hasEventMode` | `false` | 是否支持 `EventMode` |

约束关系：

- `canReturnEarlyAfterIntermediateUpdate = true` 要求 `providesIntermediateUpdate = true`。
- 有 Clock 的 FMU 必须 `hasEventMode = true`。
- 导入端传 `eventModeUsed = true` 时，`hasEventMode` 必须为 `true`，否则 FMU 必须报错。

### 8.11.3 Reference FMUs 的 CS 能力

在第 8.12 节的实验 1 会生成下面这张表。先看结论：

| 模型 | 可变步长 | 固定内部步长 | 事件模式 | 早返回 | 中间更新 |
| --- | --- | --- | --- | --- | --- |
| BouncingBall | yes | `1e-3` | yes | yes | yes |
| Dahlquist | yes | `0.1` | no | no | yes |
| Feedthrough | yes | `0.1` | yes | no | yes |
| Resource | yes | `1` | no | no | yes |
| Roberts | yes | `1e-3` | yes | yes | yes |
| Stair | yes | `0.2` | yes | no | yes |
| StateSpace | yes | `1` | yes | no | yes |
| VanDerPol | yes | `1e-2` | no | no | yes |

两个观察：

- 所有模型都支持中间更新，但不是所有模型都支持事件模式或早返回。
- 所有模型都没有声明 `maxOutputDerivativeOrder`，所以按规范导入端不应调用 `fmi3GetOutputDerivatives`，即使某些模型内部实现了它。

---

## 8.12 动手实验

> **前置条件**：实验 2–5 需要先编译 Reference FMUs。`build/` 已被 `.gitignore` 忽略，仓库里不一定有预编译文件。
>
> ```powershell
> cd examples\reference-fmus
> cmake -B build .
> cmake --build build --config Release
> cd ..\..
> ```
>
> 实验 1 只读 XML，不需要编译。

### 实验 1：从 XML 盘点 CS 能力

**目标**：读出每个模型的 CS 能力、固定内部步长和输出导数阶数，建立「能力标志决定导入端能调用什么」的直觉。

在仓库根目录执行：

```powershell
Get-ChildItem .\examples\reference-fmus -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'FMI3.xml') } |
    ForEach-Object {
        $xml = [xml](Get-Content (Join-Path $_.FullName 'FMI3.xml') -Raw -Encoding UTF8)
        $cs  = $xml.fmiModelDescription.CoSimulation
        if ($cs) {
            [pscustomobject]@{
                Model        = $_.Name
                VarStep      = if ($cs.GetAttribute('canHandleVariableCommunicationStepSize') -eq 'true') { 'yes' } else { 'no' }
                FixedStep    = if ($cs.GetAttribute('fixedInternalStepSize')) { $cs.GetAttribute('fixedInternalStepSize') } else { '-' }
                EventMode    = if ($cs.GetAttribute('hasEventMode') -eq 'true') { 'yes' } else { 'no' }
                EarlyReturn  = if ($cs.GetAttribute('mightReturnEarlyFromDoStep') -eq 'true') { 'yes' } else { 'no' }
                Intermediate = if ($cs.GetAttribute('providesIntermediateUpdate') -eq 'true') { 'yes' } else { 'no' }
                MaxDeriv     = if ($cs.GetAttribute('maxOutputDerivativeOrder')) { $cs.GetAttribute('maxOutputDerivativeOrder') } else { '0' }
            }
        }
    } | Format-Table -AutoSize
```

预期输出：

```text
Model        VarStep FixedStep EventMode EarlyReturn Intermediate MaxDeriv
-----        ------- --------- --------- ----------- ------------ --------
BouncingBall yes     1e-3      yes       yes         yes          0
Dahlquist    yes     0.1       no        no          yes          0
Feedthrough  yes     0.1       yes       no          yes          0
Resource     yes     1         no        no          yes          0
Roberts      yes     1e-3      yes       yes         yes          0
Stair        yes     0.2       yes       no          yes          0
StateSpace   yes     1         yes       no          yes          0
VanDerPol    yes     1e-2      no        no          yes          0
```

观察：

- `Dahlquist`、`Resource`、`VanDerPol` 没有 `hasEventMode`，所以导入端不能对它们传 `eventModeUsed = true`。
- 只有 `BouncingBall` 和 `Roberts` 声明了 `mightReturnEarlyFromDoStep`，但 `cs_early_return` 示例仍然可以对其他模型运行——只是它们不会早返回。
- `MaxDeriv = 0` 表示按规范不能调用 `fmi3GetOutputDerivatives`。BouncingBall 的二进制其实能算一阶导数，但 XML 没声明，导入端应以 XML 为准。

### 实验 2：基础 CS 循环与「错过的撞地点」

**目标**：用 `BouncingBall_cs.exe` 观察 CS 的输出，数出 12 次碰撞，并证明 0.1 s 的采样网格一个都打不中。

```powershell
$exe = '.\examples\reference-fmus\build\temp\BouncingBall_cs.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch8-cs-basic'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

$rows = Import-Csv (Join-Path $dir 'BouncingBall_cs_out.csv')

$events = for ($i = 1; $i -lt $rows.Count; $i++) {
    $prev = [double]$rows[$i - 1].h
    $cur  = [double]$rows[$i].h
    if ($prev -gt 1e-6 -and $cur -lt 1e-6) {
        [double]$rows[$i].time
    }
}

"rows              : $($rows.Count)"
"event transitions : $($events.Count)"
"event times       : $($events -join ', ')"
"on 0.1 s grid     : $(@($events |
    Where-Object { [math]::Abs($_ * 10 - [math]::Round($_ * 10)) -lt 1e-9 }).Count)"
```

预期输出：

```text
rows              : 3001
event transitions : 12
event times       : 0.453, 1.089, 1.537, 1.853, 2.077, 2.237, 2.352, 2.435, 2.496, 2.542, 2.577, 2.604
on 0.1 s grid     : 0
```

这组时间和第 7 章 `bouncing-ball-event-scan.ps1` 的默认输出完全一致。这不是巧合：两者都用 1 ms 显式欧拉、都在步末检测 `h <= 0 && v < 0`、都在事件后把 `h` 设为 `DBL_MIN`。

`on 0.1 s grid = 0` 说明：如果导入端用 0.1 s 通信步，并且只在通信点记录输出，**没有任何一个采样点落在撞地时刻**。规范 4.3 的 Basic 图里说「the points where the ball hits the floor are missed」，指的就是这个现象。

再看撞地附近的原始数据：

```powershell
$rows | Where-Object {
    [double]$_.time -gt 0.450 -and [double]$_.time -lt 0.456
} | Format-Table -AutoSize
```

预期输出：

```text
time  h            v
----  -            -
0.451 0.00453025   -4.42431
0.452 0.00010594   -4.43412
0.453 2.22507e-308 3.11075
0.454 0.00311075   3.10094
0.455 0.00621169   3.09113
```

注意 `0.453` 这一行已经是**事件后**的值：`h = DBL_MIN`，`v = +3.11`。事件前的 `h = -0.0043` 没有出现在 CSV 里，因为 `eventModeUsed = false`，FMU 在 `fmi3DoStep` 内部就完成了事件更新。基础 CS 只给你通信点的结果。

### 实验 3：事件模式下为什么有 24 次事件

**目标**：运行 `cs_event_mode.exe`，观察事件前后的双行记录，并解释为什么 12 次真实碰撞会产生 24 次 `fmi3EnterEventMode`。

```powershell
$exe = '.\examples\reference-fmus\build\temp\cs_event_mode.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch8-cs-event'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

$log  = Get-Content (Join-Path $dir 'cs_event_mode_log.txt')
$rows = Import-Csv (Join-Path $dir 'cs_event_mode_out.csv')

"EnterEventMode      : $(($log | Select-String 'fmi3EnterEventMode' -SimpleMatch).Count)"
"UpdateDiscreteStates: $(($log | Select-String 'fmi3UpdateDiscreteStates' -SimpleMatch).Count)"
"duplicated times    : $(($rows | Group-Object time | Where-Object Count -gt 1).Count)"

'--- first event ---'
$i = ($log | Select-String 'fmi3EnterEventMode' | Select-Object -First 1).LineNumber
$log | Select-Object -Skip ($i - 3) -First 6
```

预期输出：

```text
EnterEventMode      : 24
UpdateDiscreteStates: 25
duplicated times    : 24

--- first event ---
fmi3DoStep(currentCommunicationPoint=0.45, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=1, terminateSimulation=0, earlyReturn=1, lastSuccessfulTime=0.453) -> OK
fmi3GetFloat64(valueReferences={1, 3}, nValueReferences=2, values={-0.004328179999998677, -4.443929999999978}, nValues=2) -> OK
fmi3EnterEventMode() -> OK
fmi3UpdateDiscreteStates(discreteStatesNeedUpdate=0, terminateSimulation=0, nominalsOfContinuousStatesChanged=0, valuesOfContinuousStatesChanged=1, nextEventTimeDefined=0, nextEventTime=0) -> OK
fmi3EnterStepMode() -> OK
fmi3GetFloat64(valueReferences={1, 3}, nValueReferences=2, values={2.225073858507201e-308, 3.110750999999984}, nValues=2) -> OK
```

24 次事件 = 12 次真实碰撞 + 12 次「余震」。看第一次碰撞后的第二次事件：

```powershell
$dir = Join-Path $env:TEMP 'fmi-ch8-cs-event'
$log = Get-Content (Join-Path $dir 'cs_event_mode_log.txt')
$second = @($log | Select-String 'eventHandlingNeeded=1')[1].LineNumber
$log | Select-Object -Skip ($second - 1) -First 5
```

预期输出：

```text
fmi3DoStep(currentCommunicationPoint=0.453, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=1, terminateSimulation=0, earlyReturn=1, lastSuccessfulTime=0.454) -> OK
fmi3GetFloat64(valueReferences={1, 3}, nValueReferences=2, values={0.003110750999999984, 3.100940999999984}, nValues=2) -> OK
fmi3EnterEventMode() -> OK
fmi3UpdateDiscreteStates(discreteStatesNeedUpdate=0, terminateSimulation=0, nominalsOfContinuousStatesChanged=0, valuesOfContinuousStatesChanged=0, nextEventTimeDefined=0, nextEventTime=0) -> OK
fmi3EnterStepMode() -> OK
```

第二次事件的 `valuesOfContinuousStatesChanged = 0`，说明事件更新什么都没改。它是假的。

原因在 `examples/reference-fmus/src/fmi3Functions.c`：

```c
if (stateEvent || timeEvent) {

    if (S->eventModeUsed) {
        *eventHandlingNeeded = fmi3True;
    } else {
        CALL(eventUpdate(S));
#if MAX_EVENT_INDICATORS > 0
        CALL(getEventIndicators(S, S->prez, S->nz));
#endif
    }
}
```

`eventModeUsed = true` 的分支只设置标志，**没有刷新 `prez`**。`prez` 还是碰撞前的负值；下一次 `doFixedStep` 算出 `z = h = +0.0031`，于是 `prez <= 0 && z > 0` 又成立一次。

这是 Reference 实现的缺陷。规范把状态事件定义为事件指示器相对「上一次已完成积分步」的符号变化，事件处理后 FMU 应以事件时刻的指示器值作为新的比较基准。Reference 在 `eventModeUsed = true` 时没有保存这个基准，所以在下一次内部步又报一次；导入端无法访问 `prez`，也没有 API 能让它刷新。所以：

- 对 Reference 的 BouncingBall，24 次事件是预期现象。
- 导入端仍应把每次 `eventHandlingNeeded` 当作真实事件处理，否则可能漏掉真正的事件。
- 不要根据「事件次数应该等于物理碰撞次数」来写断言。

### 实验 4：早返回只给你事件后的值

**目标**：运行 `cs_early_return.exe`，确认 12 次早返回、0 次事件模式，并观察它记录的是事件后的值。

```powershell
$exe = '.\examples\reference-fmus\build\temp\cs_early_return.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch8-cs-early'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

$log = Get-Content (Join-Path $dir 'cs_early_return_log.txt')

"DoStep calls        : $(($log | Select-String 'fmi3DoStep' -SimpleMatch).Count)"
"earlyReturn=1       : $(($log | Select-String 'earlyReturn=1' -SimpleMatch).Count)"
"eventHandlingNeeded : $(($log | Select-String 'eventHandlingNeeded=1' -SimpleMatch).Count)"
"EnterEventMode      : $(($log | Select-String 'fmi3EnterEventMode' -SimpleMatch).Count)"

'--- first 3 early returns ---'
$log | Select-String 'earlyReturn=1' | Select-Object -First 3 | ForEach-Object { $_.Line }
```

预期输出：

```text
DoStep calls        : 305
earlyReturn=1       : 12
eventHandlingNeeded : 0
EnterEventMode      : 0

--- first 3 early returns ---
fmi3DoStep(currentCommunicationPoint=0.45, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=0, terminateSimulation=0, earlyReturn=1, lastSuccessfulTime=0.453) -> OK
fmi3DoStep(currentCommunicationPoint=1.083, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=0, terminateSimulation=0, earlyReturn=1, lastSuccessfulTime=1.089) -> OK
fmi3DoStep(currentCommunicationPoint=1.529, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=0, terminateSimulation=0, earlyReturn=1, lastSuccessfulTime=1.537) -> OK
```

三个关键数字：

- `earlyReturn=1` 出现 12 次，正好对应 12 次碰撞。
- `eventHandlingNeeded=1` 出现 0 次，因为 `eventModeUsed = false`，规范禁止报告事件。
- `EnterEventMode` 出现 0 次。

看 `0.453` 附近 CSV：

```powershell
Import-Csv (Join-Path $dir 'cs_early_return_out.csv') |
    Where-Object { [double]$_.time -ge 0.440 -and [double]$_.time -le 0.480 } |
    Format-Table -AutoSize
```

预期输出：

```text
time  h            v
----  -            -
0.44  0.0525502    -4.3164
0.45  0.00894475   -4.4145
0.453 2.22507e-308 3.11075
0.463 0.0306661    3.01265
0.473 0.0603511    2.91455
```

注意 `0.454` 不存在：早返回后，下一个通信点是 `0.453 + 0.01 = 0.463`，中间没有 10 ms 网格上的点。这正是「早返回插入新通信点」的直接证据。

只有事件后的值。对比实验 3 的事件模式，那里会先记录一行 `0.453, -0.0043, -4.44`，再记录一行 `0.453, DBL_MIN, +3.11`。早返回给你「事件发生了」的信号，但不给你事件前的接触状态。

### 实验 5：中间更新示例的指针 bug

**目标**：运行 `cs_intermediate_update.exe`，观察它只跑了 10 个内部步就报错，并定位原因。

```powershell
$exe = '.\examples\reference-fmus\build\temp\cs_intermediate_update.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch8-cs-intermediate'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

$rows = Import-Csv (Join-Path $dir 'cs_intermediate_update_out.csv')
$log  = Get-Content (Join-Path $dir 'cs_intermediate_update_log.txt')

"csv rows : $($rows.Count)"
"callbacks: $(($log | Select-String 'intermediateUpdate(' -SimpleMatch).Count))"
'--- tail ---'
$log | Select-Object -Last 4
```

预期输出：

```text
csv rows : 10
callbacks: 10

--- tail ---
intermediateUpdate(instanceEnvironment=..., intermediateUpdateTime=0.01, intermediateVariableSetRequested=0, intermediateVariableGetAllowed=1, intermediateStepFinished=1, canReturnEarly=0, earlyReturnRequested=0, earlyReturnTime=0)
fmi3DoStep(currentCommunicationPoint=0, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=0, terminateSimulation=0, earlyReturn=0, lastSuccessfulTime=0.01) -> OK
fmi3DoStep(currentCommunicationPoint=0.02, communicationStepSize=0.01, noSetFMUStatePriorToCurrentPoint=1, eventHandlingNeeded=0, terminateSimulation=0, earlyReturn=0, lastSuccessfulTime=0.02) -> Error
fmi3FreeInstance() -> OK
```

10 行 CSV 对应 10 次回调，时间从 `0.001` 到 `0.010`。第一个 `fmi3DoStep` 成功走完 10 ms，`lastSuccessfulTime = 0.01`。第二个 `fmi3DoStep` 传入 `currentCommunicationPoint = 0.02`，Reference 期望 `0.01`，所以报错。

根因是主循环的这两行：

```c
CALL(FMI3DoStep(S, time, stepSize, ..., &time));   // 同一个 time 既输入又输出
time += stepSize;                                   // 覆盖 FMU 写回的值
```

`&time` 让 FMU 把 `0.01` 写进 `time`，紧接着 `time += 0.01` 把它变成 `0.02`。下一次调用传 `0.02`，但 FMU 的内部通信点还停在 `0.01`。

修复：

```c
fmi3Float64 last = 0;

CALL(FMI3DoStep(S, time, stepSize, fmi3True,
                &eventEncountered, &terminateSimulation,
                &earlyReturn, &last));

time = last;
```

这个实验的教训不是「Reference 的 FMU 有 bug」，而是：**输出指针和输入变量不能共用同一个存储，除非你确定调用后不会再改它**。C 语言不会阻止这种别名（aliasing），但 FMI 的时间语义会。

---

## 8.13 常见错误清单

1. **早返回后 `time += h`**。跳过了 FMU 实际停留的时间，下一次 `currentCommunicationPoint` 对不上。
2. **把 `&time` 同时用作 `lastSuccessfulTime` 和下一步输入，然后修改它**。实验 5 的错误。
3. **`eventModeUsed = true` 时在 `StepMode` 改离散输入**。规范要求先 `fmi3EnterEventMode`；`eventModeUsed = false` 时才只能在通信点改。
4. **`eventModeUsed = false` 还调用 `fmi3EnterEventMode`**。状态机不允许，FMU 应报错。
5. **忽略 `eventHandlingNeeded`**。FMU 已经停在事件上，不处理就继续走，会得到不一致的状态。
6. **把 `earlyReturn` 当错误**。它是正常控制流；真正的错误是 `fmi3Error` / `fmi3Fatal`。
7. **假设 `lastSuccessfulTime == currentCommunicationPoint + communicationStepSize`**。规范明确允许偏离。
8. **只在通信点记录输出**。会错过事件前后的跳变，就像 Basic CS 图里那样。
9. **在 CS 调用 `fmi3GetEventIndicators` 或 `fmi3GetContinuousStates`**。这些函数只属于 ME。
10. **`requiredIntermediateVariables = NULL` 却在回调里读中间变量**。Reference 不检查，但规范不允许。
11. **`hasEventMode = false` 却传 `eventModeUsed = true`**。FMU 必须报错。
12. **`canReturnEarlyAfterIntermediateUpdate = true` 但 `providesIntermediateUpdate = false`**。XML 自相矛盾。

---

## 小结

- CS 的 FMU 自己积分、自己定位事件；导入端只负责通信点、输入输出和（可选的）事件调度。
- 主路径：`Instantiate → InitializationMode → EventMode/StepMode → DoStep 循环 → Terminate`。
- `eventModeUsed = true` 时，`ExitInitializationMode` 进入 `EventMode`，必须先做初始 `UpdateDiscreteStates` 循环，再 `EnterStepMode`。
- `fmi3DoStep` 的四个输出各司其职：`eventHandlingNeeded`（有事件）、`earlyReturn`（没走完）、`terminateSimulation`（要终止）、`lastSuccessfulTime`（实际到哪）。
- 早返回不是错误；`fmi3Discard` 才是「可重试失败」。早返回后下一次从 `lastSuccessfulTime` 继续。
- 正常完成时保持原通信点调度 `t + h`，不要盲目用 `lastSuccessfulTime` 替换；让 `h` 是 `fixedInternalStepSize` 的整数倍可以避免大部分麻烦。
- 中间更新由 FMU 主动回调；先 Get 后 Set，离散输入禁止，`intermediateStepFinished` 区分试探与已接受。
- 事件模式两条路径：`eventModeUsed = true` 由导入端显式处理；`false` 由 FMU 内部处理，且不得报告 `eventHandlingNeeded`。
- Clock 只在 `EventMode` 活跃；`Interval`/`Shift` 有 decimal 和 fraction 两种表示，`qualifiers` 告诉你下一个间隔是否已知。
- Reference 的 CS 示例是「调用序列说明书」，不是生产导入端：`cs_intermediate_update.c` 有时间指针 bug，`cs_event_mode.c` 会看到 24 次事件（12 次真实 + 12 次实现缺陷导致的重复）。

---

## 习题

### 1. 找出第一个非法调用

下面每个序列都从成功实例化开始。指出**第一个**违反状态机或前置条件的调用，并给出修正方案。

1. CS，`eventModeUsed = false`：`fmi3ExitInitializationMode` → `fmi3EnterEventMode`
2. CS：`fmi3InstantiateCoSimulation` → `fmi3DoStep`
3. CS，`eventModeUsed = true`：`fmi3ExitInitializationMode` → `fmi3DoStep`
4. CS，已在 `StepMode`：`fmi3GetEventIndicators`
5. CS，`eventModeUsed = true`，已在 `StepMode`：`fmi3SetFloat64` 修改一个 `variability="discrete"` 的输入
6. CS：上一次 `fmi3DoStep` 返回 `lastSuccessfulTime = 0.15`，下一次调用 `fmi3DoStep(0.20, 0.1, ...)`

<details>
<summary>答案</summary>

1. `fmi3EnterEventMode` 非法。`eventModeUsed = false` 时没有 `EventMode`，`fmi3ExitInitializationMode` 直接进入 `StepMode`。修正：删掉该调用，事件由 FMU 内部处理。
2. `fmi3DoStep` 非法。此时还在 `Instantiated`，必须先 `fmi3EnterInitializationMode`、设置参数/输入、`fmi3ExitInitializationMode`。`fmi3DoStep` 只允许在 `StepMode`。
3. `fmi3DoStep` 非法。`eventModeUsed = true` 时，`fmi3ExitInitializationMode` 进入 `EventMode`，必须先做初始 `fmi3UpdateDiscreteStates` 循环，再 `fmi3EnterStepMode`。修正：补上这两步。
4. 非法。`fmi3GetEventIndicators` 只属于 ME；CS 中事件指示器由 FMU 内部管理。修正：删掉；如果需要事件信息，用 `eventHandlingNeeded` / `earlyReturn`。
5. 在 `eventModeUsed = true` 时非法。规范要求导入端在对输入做离散修改前调用 `fmi3EnterEventMode`；`StepMode` 的 `fmi3Set{VariableType}` 虽然语法上接受 `input`，但离散变化属于事件。修正：先 `fmi3EnterEventMode`，设置离散输入，做事件迭代，再 `fmi3EnterStepMode`。如果 `eventModeUsed = false`，没有 `EventMode`，离散输入只能在通信点设置，由 FMU 内部处理。
6. 非法（对 Reference 实现而言）。上一次 FMU 停在 `0.15`，下一次 `currentCommunicationPoint` 应为 `0.15`，而不是 `0.20`。规范只硬性规定第一次等于 `startTime`，但时间必须连续；Reference 会检查内部 `nextCommunicationPoint` 并报错。修正：用 `lastSuccessfulTime` 作为下一次的起点。

</details>

### 2. `fmi3DoStep` 返回值判断

某 CS 导入端在一次 `fmi3DoStep` 后得到下面四组输出。分别说明导入端下一步应该做什么。

| 场景 | `eventHandlingNeeded` | `terminateSimulation` | `earlyReturn` | `lastSuccessfulTime` |
| --- | --- | --- | --- | --- |
| A | `true` | `false` | `true` | `0.453` |
| B | `false` | `false` | `true` | `0.120` |
| C | `false` | `false` | `false` | `0.299`（目标 `0.300`） |
| D | `false` | `true` | `true` | `2.500` |

假设 `eventModeUsed = true`，`currentCommunicationPoint = 0.450`（A）、`0.110`（B）、`0.000`（C）、`2.400`（D）。

<details>
<summary>答案</summary>

- **A**：FMU 在 `0.453` 遇到事件并早返回。导入端应记录 `0.453` 的输出，调用 `fmi3EnterEventMode`，设置离散输入/Clock，循环 `fmi3UpdateDiscreteStates` 直到 `discreteStatesNeedUpdate = false`，再 `fmi3EnterStepMode`。下一次 `fmi3DoStep` 从 `0.453` 开始。
- **B**：FMU 早返回但没有事件（可能是导入端在中间更新中请求停止，或 FMU 需要额外通信点）。导入端记录 `0.120` 的输出，不进入事件模式，下一次从 `0.120` 开始。可以检查是否需要调整步长。
- **C**：FMU 正常完成，但 `lastSuccessfulTime` 比目标时间早 `0.001`。导入端记录 `0.299` 的输出，但下一个通信点仍应是原计划的 `0.300`（保持调度）。不要用 `0.299` 替换 `0.300`，否则通信点会漂移。Reference 的做法正是把内部 `nextCommunicationPoint` 设为 `currentCommunicationPoint + communicationStepSize`，即 `0.300`；FMU 下一次会从内部时间 `0.299` 继续积分到新的目标。
- **D**：FMU 请求终止。导入端记录 `2.500` 的输出，跳出循环，调用 `fmi3Terminate` 和 `fmi3FreeInstance`。不要继续 `fmi3DoStep`。

</details>

### 3. 修早返回循环

下面的循环有两个 bug：

```c
fmi3Float64 time = startTime;

while (time < stopTime) {

    CALL(FMI3DoStep(S, time, 0.01, fmi3True,
                    &eventEncountered, &terminateSimulation,
                    &earlyReturn, &time));

    time += 0.01;

    if (eventEncountered) {
        CALL(FMI3EnterEventMode(S));
        CALL(FMI3EnterStepMode(S));
    }
}
```

回答：

1. 第一个 bug 是什么？会导致什么现象？
2. 第二个 bug 是什么？`fmi3EnterEventMode` 和 `fmi3EnterStepMode` 之间漏了什么？
3. 写出修正后的循环（至少包含早返回、终止、事件迭代和 `stopTime` 保护）。

<details>
<summary>答案</summary>

1. `&time` 既作为 `lastSuccessfulTime` 输出，又在下一行 `time += 0.01` 被覆盖。早返回时 FMU 写入的 `0.453` 会被改成 `0.463`，下一次 `currentCommunicationPoint` 对不上，Reference 会报错；其他 FMU 可能静默跳过事件后的区间。
2. `fmi3EnterEventMode` 和 `fmi3EnterStepMode` 之间漏了 `fmi3UpdateDiscreteStates` 循环。规范要求每个超密集时间点至少调用一次；不调用则离散状态没有更新，`nextEventTime` 也没有刷新。另外，事件处理前应设置离散输入/Clock。
3. 修正版本：

```c
fmi3Float64 time = startTime;
const fmi3Float64 hNominal = 0.01;

while (time < stopTime) {

    const fmi3Float64 h = fmin(hNominal, stopTime - time);
    fmi3Boolean eventNeeded, terminate, early;
    fmi3Float64 last = 0;

    const fmi3Status status = fmi3DoStep(fmu, time, h, fmi3True,
                                         &eventNeeded, &terminate,
                                         &early, &last);

    if (status != fmi3OK && status != fmi3Warning) {
        handleError(status);
        break;
    }

    recordOutputs(fmu, last);

    if (terminate) {
        break;
    }

    if (eventNeeded) {
        fmi3EnterEventMode(fmu);
        /* 设置离散输入、触发输入 Clock */
        fmi3Boolean needUpdate = fmi3True;
        while (needUpdate) {
            fmi3UpdateDiscreteStates(fmu, &needUpdate, &terminate,
                                     &nominalsChanged, &statesChanged,
                                     &nextEventTimeDefined, &nextEventTime);
            if (terminate) break;
        }
        fmi3EnterStepMode(fmu);
    }

    if (early) {
        if (last == time && !eventNeeded) {
            handleNoProgress();
            break;
        }
        time = last;
    } else {
        time = time + h;
    }
}
```

关键点：`last` 是独立变量；早返回才用 `last`，正常完成用 `time + h`；事件处理包含完整的 `UpdateDiscreteStates` 循环；`h` 不超过 `stopTime - time`。

</details>

### 4. 中间更新的允许操作

判断下列操作在 `IntermediateUpdateMode` 中是否允许，并说明条件。

1. `fmi3GetFloat64` 读取一个 `intermediateUpdate="true"` 且已列入 `requiredIntermediateVariables` 的输出。
2. `fmi3SetFloat64` 设置一个 `intermediateUpdate="true"` 且已列入 `requiredIntermediateVariables` 的连续输入。
3. `fmi3SetFloat64` 设置一个离散输入。
4. 先 `fmi3SetFloat64` 设置输入，再 `fmi3GetFloat64` 读取输出。
5. `fmi3GetOutputDerivatives` 读取一个中间变量的二阶导数，XML 的 `maxOutputDerivativeOrder = 1`。
6. 在回调里设置 `*earlyReturnRequested = fmi3True`，但 `canReturnEarly = fmi3False`。

<details>
<summary>答案</summary>

1. 允许，前提是 `intermediateVariableGetAllowed = true`。
2. 允许，前提是 `intermediateVariableSetRequested = true`。
3. 不允许。规范明确禁止在中间更新中设置离散输入。
4. 不允许。顺序必须是先完成所有 Get，再开始 Set；反过来会破坏 FMU 的双缓冲/原地计算假设。
5. 不允许。`maxOutputDerivativeOrder = 1` 只允许一阶；二阶调用应返回错误。
6. 不允许。只有 `canReturnEarly = true` 时才能请求早返回；否则导入端必须把 `earlyReturnRequested` 设为 `fmi3False`。

</details>

### 5. 通信步长与时间计算

某 CS FMU 的 `fixedInternalStepSize = 1e-3`，导入端使用 `h = 0.0025`，从 `t = 0` 开始。

1. 第一次 `fmi3DoStep` 后，`lastSuccessfulTime` 最可能是多少？`earlyReturn` 是什么？
2. 下一次 `currentCommunicationPoint` 应该传什么？为什么不是 `lastSuccessfulTime`？
3. 如果导入端把 `h` 改成 `0.003`，情况会怎样？
4. 如果 FMU 在 `t = 0.0015` 发生事件并允许早返回，第一次 `fmi3DoStep` 的四个输出可能是什么？

<details>
<summary>答案</summary>

1. 内部步是 1 ms，从 0 开始能走 `0.001`、`0.002`；再走一步到 `0.003` 就超过 `0.0025`，所以停在 `0.002`。`earlyReturn = false`，因为这是「正常完成」，FMU 没有提前中止，只是无法精确落在目标时间。
2. 应传 `0.0025`（原计划的目标时间），不是 `0.002`。通信点是导入端调度的；`lastSuccessfulTime` 只是 FMU 内部时间。Reference 实现会检查 `currentCommunicationPoint` 是否等于它记录的 `nextCommunicationPoint = 0 + 0.0025`，传 `0.002` 会报错（除非在 `isClose` 容差内）。
3. `h = 0.003` 是内部步长的整数倍，FMU 可以走 `0.001`、`0.002`、`0.003`，`lastSuccessfulTime = 0.003`，`earlyReturn = false`。这就是规范建议「用整数倍」的原因。
4. 可能返回：

```text
eventHandlingNeeded = true
terminateSimulation  = false
earlyReturn          = true
lastSuccessfulTime   = 0.0015
```

导入端应进入 `EventMode` 处理事件，下一次从 `0.0015` 继续。

</details>

### 6. XML 能力标志一致性

判断下列 XML 是否合法，并说明理由。

1. `<CoSimulation hasEventMode="false" .../>`，导入端传 `eventModeUsed = true`。
2. `<CoSimulation hasEventMode="false" .../>`，FMU 内部有 Clock 变量。
3. `<CoSimulation providesIntermediateUpdate="false" canReturnEarlyAfterIntermediateUpdate="true" .../>`。
4. `<CoSimulation maxOutputDerivativeOrder="0" .../>`，导入端调用 `fmi3GetOutputDerivatives` 取一阶导数。
5. `<CoSimulation canHandleVariableCommunicationStepSize="false" .../>`，导入端每次 `fmi3DoStep` 用不同的 `h`。

<details>
<summary>答案</summary>

1. 不合法。`eventModeUsed = true` 要求 `hasEventMode = true`；否则 FMU 必须报错（实例化失败或返回错误）。
2. 不合法。有 Clock 的 FMU 必须 `hasEventMode = true`，因为 Clock 只在 `EventMode` 活跃。
3. 不合法。`canReturnEarlyAfterIntermediateUpdate = true` 要求 `providesIntermediateUpdate = true`。
4. 不合法。`maxOutputDerivativeOrder = 0` 表示不能提供任何阶的输出导数；一阶也不允许。导入端应检查标志后再调用。
5. 不合法（语义上）。`canHandleVariableCommunicationStepSize = false` 表示通信步长必须恒定；导入端不应改变 `h`。规范没有规定 FMU 必须报错，但这是明确的契约违反。

</details>

### 7. Clock 的 Interval/Shift

某 CS FMU 有一个固定周期输入 Clock，value reference 为 5，周期 `1/50` 秒，第一次 tick 在 `startTime + 0.1` 秒。

1. 用 fraction API 写出设置 interval 和 shift 的代码。
2. 用 decimal API 写出等价的代码。
3. 计算前三个 tick 的时间（`startTime = 0`）。
4. 如果这个 Clock 是 aperiodic，能否调用 `fmi3SetShiftFraction`？为什么？
5. 如果 `fmi3GetIntervalFraction` 返回 `qualifiers = fmi3IntervalNotYetKnown`，导入端应该做什么？

<details>
<summary>答案</summary>

1. Fraction：

```c
const fmi3ValueReference vr = 5;
const fmi3UInt64 intervalCounter = 1;
const fmi3UInt64 intervalResolution = 50;   /* 1/50 s = 20 ms */
const fmi3UInt64 shiftCounter = 1;
const fmi3UInt64 shiftResolution = 10;      /* 1/10 s = 0.1 s */

fmi3SetIntervalFraction(fmu, &vr, 1,
                        &intervalCounter, &intervalResolution);
fmi3SetShiftFraction(fmu, &vr, 1,
                     &shiftCounter, &shiftResolution);
```

这些调用应在 `InitializationMode` 中完成（固定周期 Clock 的规则）。

2. Decimal：

```c
const fmi3ValueReference vr = 5;
const fmi3Float64 interval = 0.02;
const fmi3Float64 shift = 0.1;

fmi3SetIntervalDecimal(fmu, &vr, 1, &interval);
fmi3SetShiftDecimal(fmu, &vr, 1, &shift);
```

3. tick 时间：

```text
t0 = 0 + 0.1  = 0.1
t1 = 0.1 + 0.02 = 0.12
t2 = 0.12 + 0.02 = 0.14
```

4. 不能。规范规定 aperiodic Clock 不允许调用 `fmi3SetShift` / `fmi3GetShift`；它的第一次 tick 由 `fmi3GetInterval` 在初始化时给出。

5. 这个 Clock 的模型分区暂时不能调度。导入端应等待下一次 `EventMode` / `ClockUpdateMode` 再查询，不能假设一个间隔或盲目调度。这个返回值主要用于 countdown aperiodic Clock。

</details>

### 8. 判断题

1. CS 的 `fmi3DoStep` 可以在 `EventMode` 中调用。
2. `eventModeUsed = false` 时，`fmi3DoStep` 可以返回 `eventHandlingNeeded = true`。
3. `earlyReturn = true` 表示 FMU 发生了错误。
4. `lastSuccessfulTime` 在 `earlyReturn = false` 时一定等于 `currentCommunicationPoint + communicationStepSize`。
5. `fmi3Discard` 表示 FMU 回到了调用前的状态，可以重试。
6. 中间更新的回调里可以先 Set 再 Get。
7. `intermediateStepFinished = false` 的输出是试探性的，可能还会变。
8. `requiredIntermediateVariables` 中的变量必须在 XML 中标记 `intermediateUpdate="true"`。
9. CS 中可以用 `fmi3GetContinuousStates` 读取 FMU 内部状态。
10. `hasEventMode = false` 的 FMU 仍然可以有 Clock。

<details>
<summary>答案</summary>

1. 错。`fmi3DoStep` 只允许在 `StepMode`；`EventMode` 中应使用 `fmi3UpdateDiscreteStates`，处理完再 `fmi3EnterStepMode`。
2. 错。规范明确禁止：`eventHandlingNeeded = true` 不得在 `eventModeUsed = false` 时报告。
3. 错。早返回是正常控制流；错误用 `fmi3Error` / `fmi3Fatal`，可重试失败用 `fmi3Discard`。
4. 错。规范明确允许偏离，例如固定内部步长无法精确落在目标时间。
5. 对。`fmi3Discard` 表示这一步被丢弃，FMU 状态与调用前相同，输出未定义；导入端可以缩小步长或换输入后重试。
6. 错。必须先完成所有 Get，再开始 Set。
7. 对。`intermediateStepFinished = false` 表示当前是试探性内部步，求解器可能回退重算。
8. 对。两个条件必须同时满足：XML 标记 `intermediateUpdate="true"`，且列入 `requiredIntermediateVariables`。
9. 错。`fmi3GetContinuousStates` 只属于 ME；CS 的连续状态在 FMU 内部，导入端不可见。
10. 错。有 Clock 的 FMU 必须 `hasEventMode = true`，因为 Clock 只在 `EventMode` 活跃。

</details>

---

## 下一章

CS 把时间推进、事件定位都封装在 FMU 内部，导入端只需要按通信步调用 `fmi3DoStep`。下一章看第三种接口：Scheduled Execution。它把「什么时候执行哪个模型分区」完全交给导入端，用 Clock 和 `fmi3ActivateModelPartition` 取代 `fmi3DoStep`。我们会讲清 Clock 的类型、优先级、SE 的状态机，以及 `scs_synchronous.c` / `scs_threaded.c` 的单线程与多线程调度。

→ [第 9 章 Scheduled Execution 与 Clock](09-scheduled-execution.md)
