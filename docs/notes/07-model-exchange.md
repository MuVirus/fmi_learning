# 第 7 章 Model Exchange

> **第三部分：接口与状态机 · 初稿**
> 对应规范：[3.1 Concepts](../spec-3.0.2/html/index.html#concepts-model-exchange) / [3.2 State Machine](../spec-3.0.2/html/index.html#state-machine-model-exchange) / [3.3 Code Example](../spec-3.0.2/html/index.html#_code_example) / [3.4 Schema](../spec-3.0.2/html/index.html#model-exchange-schema)
> 预计阅读：45 分钟
> 动手时间：25 分钟

## 学习目标

读完本章，你应该能够：

1. 说清 Model Exchange（ME）中 FMU 与导入端的分工：谁保存状态、谁积分、谁定位事件。
2. 画出 ME 从实例化到终止的主调用序列，并指出初始事件迭代和 `fmi3EnterContinuousTimeMode` 的位置。
3. 解释 `ContinuousTimeMode` 中哪些方程被激活、哪些变量被冻结，以及「关系冻结」为什么必要。
4. 用事件指示器的**符号域变化**判断状态事件，而不是用「乘积小于等于零」。
5. 区分输入事件、时间事件、状态事件、步事件，并知道每种事件由谁检测。
6. 正确使用 `fmi3SetTime`、`fmi3SetContinuousStates`、`fmi3CompletedIntegratorStep` 的前置条件。
7. 读懂 `simulate_fmi3_me.c` 的六段结构，并指出它在事件定位和步长控制上的简化。
8. 从 `modelDescription.xml` 读出 ME 的能力标志、连续状态顺序和事件指示器顺序。

第 6 章把三种接口的公共骨架讲完了：实例化、初始化、事件迭代、终止。本章进入第一条接口专线——Model Exchange。

ME 的核心一句话可以概括为：

> **FMU 提供方程，导入端提供求解器。**

这句话听起来简单，但它决定了后面所有 API 的形态。CS 的 FMU 自己会走时间步，导入端只要说「从 0 走到 1 秒」；ME 的 FMU 不会走时间步，它只会说「在当前时间、当前状态、当前输入下，导数是这些，事件指示器是这些」。积分、步长控制、事件定位、误差估计，全都落在导入端身上。

所以本章的重点不是「怎么调用一个函数」，而是「导入端要自己实现一个什么样的混合系统求解器」。

---

## 7.1 谁在积分：ME 与 CS 的分工

先用一张表把两种接口的职责摆清楚。

| 职责 | Model Exchange | Co-Simulation |
| --- | --- | --- |
| 连续状态 `x_c` 存在哪里 | 导入端 | FMU 内部 |
| 谁推进连续状态 | 导入端积分器 | FMU 内部求解器 |
| 谁决定积分步长 | 导入端 | FMU（通信步长内） |
| 谁定位状态事件 | 导入端 | FMU |
| 导入端能看到事件指示器吗 | 能，`fmi3GetEventIndicators` | 不能 |
| 主推进函数 | `fmi3GetContinuousStateDerivatives` + `fmi3SetContinuousStates` | `fmi3DoStep` |
| 事件如何暴露 | `fmi3EnterEventMode` + `EventMode` | `eventHandlingNeeded` / 早返回 / 中间更新 |
| 典型使用场景 | FMU 嵌入宿主求解器，与宿主方程联合求解 | 两个仿真工具松耦合，按通信点交换数据 |

可以把 ME 想成「发动机散件」：曲轴、活塞、点火时序都给你，但变速箱和油门要你自己装。CS 则是「整车」：你告诉它目的地和速度，它自己决定怎么换挡。

这也解释了一个常见误解：**ME 不是「简化版 CS」，而是「把求解器职责交给导入端」的接口**。对导入端来说，ME 往往比 CS 更难写，因为要自己处理事件定位和积分误差。

> **规范依据**：3.2 节明确写道，在 `ContinuousTimeMode` 中「continuous-time equations are active and integrator steps are performed by the importer」。事件定位也在 3.1 节被明确分配给导入端。

---

## 7.2 ME 的主调用序列

先看主干。把第 6 章的公共状态机缩到 ME，得到下面这条线：

```text
fmi3InstantiateModelExchange 返回非 NULL
        │
        ▼
   Instantiated
        │ fmi3EnterInitializationMode
        ▼
 InitializationMode
        │ fmi3ExitInitializationMode
        ▼
    EventMode
        │ fmi3UpdateDiscreteStates（至少一次，直到收敛）
        │ fmi3EnterContinuousTimeMode
        ▼
 ContinuousTimeMode ──────────────┐
        ▲                         │ 检测到事件
        │                         │ fmi3EnterEventMode
        │                         ▼
        │                    EventMode
        │                         │ 事件迭代
        │                         │ fmi3EnterContinuousTimeMode
        └─────────────────────────┘
        │
        │ fmi3Terminate
        ▼
    Terminated
        │ fmi3FreeInstance
        ▼
     (实例释放)
```

把这条线展开成可执行的步骤：

| 步骤 | 调用 | 必需性 | 说明 |
| --- | --- | --- | --- |
| 1 | `fmi3InstantiateModelExchange` | 必需 | 返回 `NULL` 表示实例化失败 |
| 2 | `fmi3EnterConfigurationMode` | 可选 | 仅当要改 `structuralParameter` |
| 3 | `fmi3EnterInitializationMode` | 必需 | 给出 `startTime`、`stopTime`、容差 |
| 4 | `fmi3Set{VariableType}` | 按需 | 设置参数、输入、`initial="exact"` 的状态 |
| 5 | `fmi3ExitInitializationMode` | 必需 | 进入 `EventMode` |
| 6 | `fmi3UpdateDiscreteStates` | 必需 | 初始事件迭代，至少一次 |
| 7 | `fmi3EnterContinuousTimeMode` | 必需 | 进入积分 |
| 8 | `fmi3GetEventIndicators` | 有指示器时 | 保存 `previous_z` |
| 9 | `fmi3GetContinuousStates` | 有状态时 | 取初始 `x` |
| 10 | `fmi3GetNominalsOfContinuousStates` | 按需 | 用于误差缩放/绝对容差 |
| 11 | 积分循环 | 必需 | 见 7.8 节 |
| 12 | `fmi3EnterEventMode` | 事件时 | 从 `ContinuousTimeMode` 进入 |
| 13 | `fmi3UpdateDiscreteStates` | 事件时 | 事件迭代，直到 `discreteStatesNeedUpdate = false` |
| 14 | `fmi3EnterContinuousTimeMode` | 事件后 | 重启积分 |
| 15 | `fmi3Terminate` | 正常结束时 | 进入 `Terminated` |
| 16 | `fmi3FreeInstance` | 必需 | 释放实例 |

注意第 6 步和第 13 步的区别：第 6 步是**初始化后的初始事件迭代**；第 13 步是**运行中每次事件的迭代**。两者的循环写法一样，但触发原因不同。

一个最小骨架如下（省略错误处理）：

```c
fmi3Instance fmu = fmi3InstantiateModelExchange(
    "plant", token, resourcePath,
    fmi3False, fmi3False, NULL, logMessage);

fmi3EnterInitializationMode(fmu, fmi3False, 0.0, 0.0, fmi3True, 3.0);

/* 设置参数、输入、initial="exact" 的状态 */
fmi3SetFloat64(fmu, &vr_g, 1, &g, 1);

fmi3ExitInitializationMode(fmu);

/* 初始事件迭代 */
fmi3Boolean terminate = fmi3False;
fmi3Boolean needUpdate = fmi3True;
fmi3Boolean nominalsChanged = fmi3False;
fmi3Boolean statesChanged = fmi3False;
fmi3Boolean nextEventTimeDefined = fmi3False;
fmi3Float64 nextEventTime = 0.0;

while (needUpdate) {
    fmi3UpdateDiscreteStates(fmu, &needUpdate, &terminate,
                             &nominalsChanged, &statesChanged,
                             &nextEventTimeDefined, &nextEventTime);
}

fmi3EnterContinuousTimeMode(fmu);

/* 之后才是积分循环 */
```

这里最容易漏掉的是 `while (needUpdate)`。很多导入端在 `fmi3ExitInitializationMode` 之后直接调用 `fmi3EnterContinuousTimeMode`，结果离散状态还停在旧值，积分从错误的状态出发。

---

## 7.3 连续时间模式里到底发生了什么

规范 3.2 用一张表描述 `ContinuousTimeMode`。把这张表翻译成一句话：

> 在 `ContinuousTimeMode` 中，FMU 只计算连续时间方程 `f_cont`，所有离散时间变量保持冻结。

具体来说，FMU 在当前时间 `t`、当前连续状态 `x_c`、当前连续输入 `u_c`、参数 `p`、冻结的关系 `•r`、冻结的缓冲区 `•b` 下计算：

```text
(y_c, ẋ_c, z, w_c) := f_cont(x_c, •x_d, u_c, •u_d, p, •r, •b, t)
```

各符号的含义：

| 符号 | 含义 | 在 ME 中由谁提供 |
| --- | --- | --- |
| `x_c` | 连续状态 | 导入端通过 `fmi3SetContinuousStates` 设置 |
| `ẋ_c` | 连续状态导数 | FMU 通过 `fmi3GetContinuousStateDerivatives` 返回 |
| `u_c` | 连续输入 | 导入端通过 `fmi3Set{VariableType}` 设置 |
| `•x_d` | 上一超密集时间点的离散状态 | FMU 内部保存 |
| `•u_d` | 上一超密集时间点的离散输入 | FMU 内部保存 |
| `p` | 参数 | 导入端在初始化/事件模式设置 |
| `•r` | 冻结的关系 | FMU 在离开 `EventMode` 时更新 |
| `•b` | 冻结的缓冲区 | FMU 内部保存 |
| `z` | 事件指示器 | FMU 通过 `fmi3GetEventIndicators` 返回 |
| `y_c` | 连续输出 | 导入端通过 `fmi3Get{VariableType}` 读取 |
| `w_c` | 连续局部变量 | 一般不直接暴露 |

### 7.3.1 关系冻结：为什么 `if` 不能在积分中来回跳

看规范 3.1 给出的例子：

```c
y = ((x1 > x2) || (x1 < x3)) ? +1 : -1;
```

如果 FMU 在每次计算 `f_cont` 时都重新判断 `x1 > x2`，那么当 `x1` 在积分步内穿过 `x2` 时，`y` 会突然从 `+1` 跳到 `-1`。积分器假设右端函数在步内连续，这个跳变会直接破坏误差估计，甚至导致步长不断缩小。

FMI 的解决办法是：**把关系的结果冻结起来**。FMU 在 `EventMode` 中计算关系 `r`，离开 `EventMode` 时把 `r` 复制到 `•r`；整个 `ContinuousTimeMode` 期间，`f_cont` 只读 `•r`，不重新计算。

```c
/* 事件指示器：始终根据当前 x 计算 */
z1 = x1 - x2;
z2 = x3 - x1;

/* 关系：只在 InitializationMode / EventMode 更新 */
if (state == InitializationMode || state == EventMode) {
    r1 = z1 > 0;
    r2 = z2 > 0;

    /* 离开 EventMode 时，把 r 冻结成 •r（这里用 prev_r 表示） */
    prev_r1 = r1;
    prev_r2 = r2;
}

/* 连续方程：只读冻结的 •r，不重新判断 x1 > x2 */
y = (prev_r1 || prev_r2) ? +1 : -1;
```

这就是 `fmi3EnterContinuousTimeMode` 的隐藏动作：规范在 `EventMode` 表的最后一行写明，调用它时要执行 `•r := r`，停用 `f_event`，激活 `f_cont`。反过来，`fmi3EnterEventMode` 会停用 `f_cont`、激活 `f_event`，并把时间重置为 `(t_R, 0)`。

> **教学提示**：如果你自己写 FMU，所有依赖 `>`、`<`、`>=`、`<=` 的布尔关系，都应该在 `EventMode` 中求值并缓存，而不是在 `f_cont` 中临时判断。Reference FMUs 用 `comp->state` 做这个区分。

### 7.3.2 连续时间模式里能改什么

规范 3.2 的「Allowed Function Calls」写得很窄：

- `fmi3Set{VariableType}`：**只允许** `causality="input"` 且 `variability="continuous"` 的变量，以及连续状态。
- `fmi3Get{VariableType}`：允许，且可能触发选择性计算。
- `fmi3SetContinuousStates`：设置连续状态。
- `fmi3SetTime`：设置独立变量。
- `fmi3GetContinuousStateDerivatives`：取导数。
- `fmi3GetEventIndicators`：取事件指示器。
- `fmi3GetContinuousStates`、`fmi3GetNominalsOfContinuousStates`：取状态和标称值。
- `fmi3CompletedIntegratorStep`：完成一个积分步。

注意这里**没有** `fmi3Set` 离散输入，也**没有** `fmi3Set` 参数。离散输入和 `tunable` 参数的变化必须通过 `EventMode`。如果你在 `ContinuousTimeMode` 里改了一个离散输入，FMU 应当返回 `fmi3Error`。

这条限制不是官僚主义。离散输入一变，`f_event` 的右端就变了，当前积分步的连续性假设不再成立；正确做法是进入 `EventMode`，重新计算离散状态，再重启积分。

---

## 7.4 事件指示器：用「符号域」而不是「过零」

状态事件的定义是本章最容易被写错的地方。规范 3.1 的原文是：

> An event indicator, and only an event indicator, signals a state event with the domain change from `z_j > 0` to `z_j <= 0` or from `z_j <= 0` to `z_j > 0`.

注意两个细节：

1. 事件由**符号域的变化**定义，不是由 `z = 0` 定义。
2. `z = 0` 属于 `z <= 0` 这一边。

所以判断逻辑应该是：

```c
if (previous_z[i] <= 0 && z[i] > 0) {
    rootsFound[i] = 1;    /* -\+ */
} else if (previous_z[i] > 0 && z[i] <= 0) {
    rootsFound[i] = -1;   /* +/- */
} else {
    rootsFound[i] = 0;
}
```

而不是常见的：

```c
/* 错误：会多报事件 */
if (previous_z[i] * z[i] <= 0) { ... }
```

为什么乘积判断会多报？举两个例子：

- `previous_z = 0`，`z = -0.1`：乘积为 0，会报事件；但两者都属于 `<= 0` 域，**没有**域变化。
- `previous_z = 0`，`z = 0`：乘积为 0，会报事件；但域根本没变。

规范特意解释了为什么不用「过零函数」这个术语：状态事件是**域变化**，不是某个变量过零。这个区别在事件指示器恰好落在 0 上时非常关键。

### 7.4.1 离开事件模式后必须 `z != 0`

规范还有一条硬要求：

> The FMU must guarantee that after leaving `EventMode` `z_j != 0`, for example, by shifting `z_j` with a small value.

原因是：如果事件处理后 `z` 仍然精确等于 0，它仍然留在 `<= 0` 域。FMU 以为事件已经处理完，导入端却看不到域变化；下一次真正离开 0 时，可能被当成一次新事件，或者因为 `previous_z = 0` 而漏掉。规范要求 `z != 0`，是为了让事件后的符号域明确，下一次域变化能被唯一地判断。

BouncingBall 用了两个技巧：

**技巧一：事件指示器带滞回。**

```c
/* examples/reference-fmus/BouncingBall/model.c */
if (M(h) > -EVENT_EPSILON && M(h) <= 0 && M(v) > 0) {
    z[0] = -EVENT_EPSILON;
} else {
    z[0] = M(h);
}
```

当球已经落到 `(-ε, 0]` 且正在向上运动时，把 `z` 人为压到 `-ε`，避免 `z` 在 0 附近抖动。

**技巧二：事件更新把高度抬到 `DBL_MIN`。**

```c
Status eventUpdate(ModelInstance *comp) {
    if (M(h) <= 0 && M(v) < 0) {
        M(h) = DBL_MIN;          /* 略大于 0，避免零穿越 */
        M(v) = -M(v) * M(e);

        if (M(v) < V_MIN) {
            M(v) = 0;
            M(g) = 0;
        }

        comp->valuesOfContinuousStatesChanged = true;
    }
    ...
}
```

`DBL_MIN` 约等于 `2.2e-308`，不是 0。这样离开 `EventMode` 后 `z = h > 0`，符号域从 `<= 0` 回到 `> 0`，下一次碰撞才能被正确检测到。

### 7.4.2 事件指示器必须是连续的，并且量级约为 1

规范还给了两条建议：

- 事件指示器在事件之间应当连续。
- 事件指示器应当用它的标称值缩放，使返回值的量级约为 1。

第一条是给积分器用的：如果 `z` 在步内本身就有跳变，导入端无法用插值/二分定位事件。第二条是给容差用的：如果 `z` 的量级是 `1e9`，导入端的「零点附近」阈值就会失去意义。

BouncingBall 的 `z = h`，量级是米，标称值 1 m，正好满足。Roberts 的两个指示器则用阈值平移（`y1 - 0.0001`、`y3 - 0.01`），把零点放在有物理意义的位置。

---

## 7.5 四类事件：谁检测，谁处理

ME 中有四类事件。它们的检测者和处理方式不同，不能混为一谈。

| 事件类型 | 谁检测 | 检测依据 | 导入端动作 |
| --- | --- | --- | --- |
| 输入事件 | 导入端 | 输入发生不连续变化 | 在超密集时间点设置输入，然后 `fmi3EnterEventMode` |
| 时间事件 | FMU 预告，导入端触发 | `nextEventTime` / `GetInterval` | 积分到至少 `nextEventTime`，然后 `fmi3EnterEventMode` |
| 状态事件 | 导入端 | 事件指示器符号域变化 | 定位事件时间，然后 `fmi3EnterEventMode` |
| 步事件 | FMU | `fmi3CompletedIntegratorStep` 返回 `enterEventMode = true` | 调用 `fmi3EnterEventMode` |

### 7.5.1 输入事件

输入事件是最直观的：导入端自己改变了输入。

- 如果改变的是**离散输入**，必须在 `EventMode` 中改。因为离散输入参与 `f_event`，不能在 `ContinuousTimeMode` 里偷偷改。
- 如果改变的是**连续输入**，并且变化是光滑的，可以在 `ContinuousTimeMode` 中直接 `fmi3Set`；如果变化是跳变的，应该按输入事件处理，进入 `EventMode`。
- 如果 FMU 有 input Clock，设置 Clock 也要求进入 `EventMode`（详见第 9 章）。

`simulate_fmi3_me.c` 的做法是：在积分循环开头比较 `time >= nextInputEventTime(time)`，如果到了输入事件时刻，先 `fmi3EnterEventMode`，再调用 `applyContinuousInputs(..., true)` 和 `applyDiscreteInputs(...)`。

### 7.5.2 时间事件

时间事件由 FMU 提前预告。最常见的来源是 `fmi3UpdateDiscreteStates` 的 `nextEventTime`：

```c
fmi3Boolean nextEventTimeDefined;
fmi3Float64 nextEventTime;

fmi3UpdateDiscreteStates(fmu, &needUpdate, &terminate,
                         &nominalsChanged, &statesChanged,
                         &nextEventTimeDefined, &nextEventTime);
```

如果 `nextEventTimeDefined = fmi3True`，导入端必须把仿真推进到至少 `nextEventTime`，然后调用 `fmi3EnterEventMode`。规范允许「稍微超过」这个时间，因为导入端的时间分辨率不一定能精确命中；但 FMU 必须在该次 `EventMode` 中处理这个时间事件。

一个重要的细节：**如果另一个事件在 `nextEventTime` 之前发生，原来的 `nextEventTime` 就作废了**。规范原文是「the previous definition of `nextEventTime` becomes obsolete」。所以导入端不能把 `nextEventTime` 当成一个永远不会变的闹钟。

### 7.5.3 状态事件

状态事件由导入端用事件指示器检测。完整流程是：

1. 积分器从 `t_n` 走到 `t_{n+1}`，得到新的 `x`。
2. 调用 `fmi3GetEventIndicators` 得到 `z(t_{n+1})`。
3. 与 `previous_z` 比较符号域。如果发生变化，说明步内有一个状态事件。
4. 在 `[t_n, t_{n+1}]` 内定位事件时间 `t*`。常用方法是二分法或 Hermite 插值。
5. 在 `t*` 处设置时间、状态、输入，调用 `fmi3CompletedIntegratorStep`（规范要求事件定位后调用）。
6. 调用 `fmi3EnterEventMode`，让 FMU 处理事件。

第 4 步是 ME 导入端最需要自己实现的部分。`simulate_fmi3_me.c` **没有做**第 4 步：在源码逻辑上（假设 `NX`/`NZ` 正常定义），它把 `t_{n+1}` 直接当成事件时间。这就是为什么按它的算法跑 BouncingBall，第一次碰撞会落在 `t = 0.453`、高度已经是 `-0.0043 m`，而不是精确的 `h = 0`。对教学示例来说可以接受，对生产求解器来说不够。

### 7.5.4 步事件

步事件是 FMU 主动发起的，和「时间到了」「指示器变号」都无关。典型场景是：

- **动态状态选择**（dynamic state selection）：FMU 发现当前选作状态的那组变量在数值上不再合适，需要换一组状态。
- **投影**：FMU 表示的是 DAE，需要在积分步后把状态投影回约束流形。

FMU 通过 `fmi3CompletedIntegratorStep` 的 `enterEventMode` 返回 `fmi3True` 来请求步事件：

```c
fmi3Boolean enterEventMode;
fmi3Boolean terminateSimulation;

fmi3CompletedIntegratorStep(fmu, fmi3True,
                            &enterEventMode, &terminateSimulation);

if (enterEventMode) {
    fmi3EnterEventMode(fmu);
    /* 事件迭代 */
}
```

规范特别强调：`fmi3CompletedIntegratorStep` **不用于**检测时间事件或状态事件。时间事件和状态事件由导入端自己检测；即使 `enterEventMode = fmi3False`，导入端也必须在该进事件模式的时候进。

---

## 7.6 超密集时间与事件迭代

ME 的时间不是普通实数，而是「超密集时间」（super-dense time）：

```text
t := (t_R, t_I)
```

- `t_R` 是实数部分，通常理解的仿真时间。
- `t_I` 是整数部分，用来区分同一实数时间上的多次离散更新。

`fmi3EnterEventMode` 会把时间重置为 `(t_R, 0)`。每次 `fmi3UpdateDiscreteStates` 结束时，`t_I` 加一。所以在同一个 `t_R` 上，可以发生任意多次离散状态更新，而积分器不会前进。

事件迭代的标准写法：

```c
fmi3Boolean needUpdate = fmi3True;

while (needUpdate) {
    fmi3UpdateDiscreteStates(fmu,
        &needUpdate,
        &terminateSimulation,
        &nominalsChanged,
        &statesChanged,
        &nextEventTimeDefined,
        &nextEventTime);

    if (terminateSimulation) {
        break;
    }
}
```

规范要求：**每个超密集时间点至少调用一次 `fmi3UpdateDiscreteStates`**。即使模型没有离散状态，也要调用，因为 FMU 要借此推进 `t_I`、更新 `nextEventTime`、结算本超密集时间点的离散状态。

六个输出参数的含义：

| 输出 | 含义 | 导入端要做什么 |
| --- | --- | --- |
| `discreteStatesNeedUpdate` | 还需要再迭代一次 | 留在 `EventMode`，再调用一次 |
| `terminateSimulation` | FMU 请求终止 | 跳出循环，走终止流程 |
| `nominalsOfContinuousStatesChanged` | 连续状态的标称值变了 | 重新调用 `fmi3GetNominalsOfContinuousStates` |
| `valuesOfContinuousStatesChanged` | 连续状态被 `reinit` 改了 | 重新调用 `fmi3GetContinuousStates`，或逐个读 `reinit="true"` 的状态 |
| `nextEventTimeDefined` | 有下一个时间事件 | 与 `nextEventTime` 配合使用 |
| `nextEventTime` | 下一个时间事件的绝对时间 | 积分到至少这个时间 |

`valuesOfContinuousStatesChanged` 和 `nominalsOfContinuousStatesChanged` 是 **ME 专属**的；CS 和 SE 中这两个输出无效。

BouncingBall 在每次碰撞时把 `valuesOfContinuousStatesChanged` 置为 `true`，因为 `h` 和 `v` 都被 `reinit` 了。导入端必须重新取状态，否则会继续用碰撞前的 `x` 积分。

### 7.6.1 `fmi3EnterContinuousTimeMode` 做了什么

事件迭代收敛后，导入端调用：

```c
fmi3EnterContinuousTimeMode(fmu);
```

这个函数不是「切换一个布尔标志」那么简单。规范在 `EventMode` 表的最后一行写明，它要：

1. 更新关系缓存：`•r := r`。
2. 停用事件方程 `f_event`。
3. 激活连续方程 `f_cont`。

也就是说，**事件模式中算出来的关系，从这里开始被冻结**，直到下一次 `fmi3EnterEventMode`。

如果你在事件迭代中改变了某个 `tunable` 参数，而它参与了一个 `if` 关系，那么关系的新值会先在 `f_event` 中参与计算，再在 `fmi3EnterContinuousTimeMode` 时被复制到 `•r` 冻结下来。顺序不能反：先更新关系，再冻结。

---

## 7.7 `fmi3SetTime` 与 `fmi3CompletedIntegratorStep` 的边界

这两个函数是 ME 导入端最容易用错的地方。它们的限制不是「建议」，而是规范里的硬约束。

### 7.7.1 `fmi3SetTime` 能倒退多少

规范 3.2 规定，`fmi3SetTime` 的参数 `time` 必须大于或等于以下三者中的最大值：

1. `startTime`。
2. **倒数第二次** `fmi3CompletedIntegratorStep` 的时间。
3. 最后一次 `fmi3EnterEventMode` 的时间。

为什么是「倒数第二次」而不是「最后一次」？因为事件定位需要在当前积分步内回退。假设积分器从 `0.3` 走到 `0.4`，在 `0.4` 发现事件指示器变号，它需要回到 `0.3` 和 `0.4` 之间做二分。此时最后一次 `CompletedIntegratorStep` 是 `0.3`，倒数第二次是 `0.2`，所以允许回到 `0.2` 之后的任何时间。

用时间线表示：

```text
startTime = 0
CIS(0.1)     CIS(0.2)     CIS(0.3)          CIS(0.35)   EnterEventMode(0.35)
   │            │            │                  │              │
   ▼            ▼            ▼                  ▼              ▼
  0.1          0.2          0.3                0.35           0.35
                            ▲                  ▲
                     倒数第二次 CIS        最后一次 CIS
```

- 在事件定位阶段（还没 `EnterEventMode`），允许的最早时间是 `max(0, 0.2) = 0.2`。
- 进入 `EventMode` 后，允许的最早时间变成 `max(0, 0.3, 0.35) = 0.35`。

一旦进了事件模式，就不能再回到事件之前。规范的解释是：`fmi3EnterEventMode` / `fmi3UpdateDiscreteStates` 只能计算「下一个」离散状态，不能倒推「上一个」。所以事件之后的时间旅行被禁止。

### 7.7.2 `fmi3CompletedIntegratorStep` 到底管什么

先看它的签名：

```c
typedef fmi3Status fmi3CompletedIntegratorStepTYPE(
    fmi3Instance instance,
    fmi3Boolean  noSetFMUStatePriorToCurrentPoint,
    fmi3Boolean* enterEventMode,
    fmi3Boolean* terminateSimulation);
```

除 `instance` 外的三个参数：

- `noSetFMUStatePriorToCurrentPoint = fmi3True`：导入端承诺，本次仿真运行中不会再调用 `fmi3SetFMUState` 回到当前时间之前。FMU 可以据此释放旧状态。
- `enterEventMode`：FMU 请求步事件。
- `terminateSimulation`：FMU 请求终止。

它的调用条件是：

> 如果 XML 中 `needsCompletedIntegratorStep = true`，导入端必须在**每个完成的积分步**之后调用它。如果为 `false`，调用它也没有效果。

注意「每个完成的积分步」不等于「每个事件」。如果积分器因为事件定位而在步内回退，只有最终接受的步才叫「完成」。

Reference FMUs 的所有 ME 模型都没有设置 `needsCompletedIntegratorStep`，也就是用默认值 `false`。但 `simulate_fmi3_me.c` 仍然在每个循环里调用它：

```c
CALL(FMI3CompletedIntegratorStep(S, fmi3True, &stepEvent, &terminateSimulation));
```

这不是错误，而是**面向未来的写法**：如果某个模型把标志改成 `true`，导入端已经准备好了。Reference 的实现则直接返回两个 `false`，相当于空操作：

```c
fmi3Status fmi3CompletedIntegratorStep(...) {
    ...
    *enterEventMode = fmi3False;
    *terminateSimulation = fmi3False;
    ...
}
```

还有一个容易误解的点：`fmi3CompletedIntegratorStep` 不是用来检测时间事件或状态事件的。规范明确说，时间事件和状态事件由导入端检测；即使它返回 `enterEventMode = fmi3False`，导入端在该进事件模式时仍然要进。

### 7.7.3 调用顺序：先定位，再完成步，再进事件

把 7.5.3 的流程和 7.7.2 的约束合起来，状态事件附近的正确顺序是：

```text
1. 积分器走一步：t_n → t_{n+1}
2. SetTime(t_{n+1}) + SetContinuousStates(x_{n+1})
3. GetEventIndicators(z_{n+1})
4. 发现符号域变化
5. 在 [t_n, t_{n+1}] 内定位 t*
6. SetTime(t*) + SetContinuousStates(x*)
7. CompletedIntegratorStep(...)      ← 告诉 FMU：这一步的值被接受了
8. EnterEventMode()
9. UpdateDiscreteStates() 循环
10. EnterContinuousTimeMode()
11. 从 t* 重启积分器
```

第 7 步的位置很容易放错。它应该在**事件定位完成之后**，而不是在第一次发现变号时。因为 `CompletedIntegratorStep` 的语义是「当前时间、当前输入、当前状态都是有效的、被接受的」，而定位之前的值还不是最终值。

---

## 7.8 逐段读 `simulate_fmi3_me.c`

`examples/reference-fmus/examples/simulate_fmi3_me.c` 是规范 3.3 节引用的官方示例。它只有 228 行，但把 ME 的主循环完整走了一遍。下面按功能分成六段。

### 7.8.1 准备：步长、状态数组、事件数组（第 13–28 行）

```c
const fmi3Float64 fixedStep = FIXED_SOLVER_STEP;
const fmi3Float64 stopTime  = DEFAULT_STOP_TIME;

#if NZ > 0
fmi3Int32 rootsFound[NZ] = { 0 };
fmi3Float64 z[NZ] = { 0 };
fmi3Float64 previous_z[NZ] = { 0 };
#else
fmi3Int32 *rootsFound = NULL;
#endif

#if NX > 0
fmi3Float64 x[NX] = { 0 };
fmi3Float64 x_nominal[NX] = { 0 };
fmi3Float64 der_x[NX] = { 0 };
#endif
```

- `fixedStep` 和 `stopTime` 来自模型的 `config.h`。
- `rootsFound` 记录每个指示器的变化方向：`+1` 表示 `-→+`，`-1` 表示 `+→-`，`0` 表示没变。
- `previous_z` 保存上一步的指示器值，用来做符号域比较。
- `x`、`x_nominal`、`der_x` 分别是连续状态、标称值、导数。

> **重要陷阱**：这段代码用了 `NX` 和 `NZ`，但本仓库的 `simulate_fmi3_me.c` 并没有定义它们，构建系统也没有传 `-DNX=...`。预处理器会把未定义的标识符当成 `0`，于是 `#if NX > 0` 和 `#if NZ > 0` 全部为假。结果是：**这个示例在 BouncingBall 上不会调用任何状态/导数/事件指示器函数**。7.10 节的实验 3 会验证这一点。

### 7.8.2 实例化与初始化（第 46–66 行）

```c
CALL(FMI3InstantiateModelExchange(S,
    INSTANTIATION_TOKEN, // instantiationToken
    resourcePath(),      // resourcePath
    fmi3False,           // visible
    fmi3False            // loggingOn
));

fmi3Float64 time = 0;

CALL(applyStartValues(S));

CALL(FMI3EnterInitializationMode(S, fmi3False, 0.0, time, fmi3True, stopTime));

CALL(applyContinuousInputs(S, time, false));
CALL(applyDiscreteInputs(S, time));

CALL(FMI3ExitInitializationMode(S));
```

顺序值得注意：

1. 先实例化。
2. 设置 `start` 值（`applyStartValues`）。
3. 进入初始化模式。
4. 设置输入。
5. 退出初始化模式。

`fmi3EnterInitializationMode` 的第二个参数是 `toleranceDefined`，这里是 `fmi3False`；第四个参数是 `startTime`，第五个是 `stopTimeDefined`，第六个是 `stopTime`。

### 7.8.3 初始事件迭代与进入连续时间（第 69–96 行）

```c
while (discreteStatesNeedUpdate) {
    CALL(FMI3UpdateDiscreteStates(S,
        &discreteStatesNeedUpdate,
        &terminateSimulation,
        &nominalsOfContinuousStatesChanged,
        &valuesOfContinuousStatesChanged,
        &nextEventTimeDefined,
        &nextEventTime));

    if (terminateSimulation) {
        goto TERMINATE;
    }
}

CALL(FMI3EnterContinuousTimeMode(S));

#if NZ > 0
CALL(FMI3GetEventIndicators(S, previous_z, NZ));
#endif

#if NX > 0
CALL(FMI3GetContinuousStates(S, x, NX));
CALL(FMI3GetNominalsOfContinuousStates(S, x_nominal, NX));
#endif

CALL(recordVariables(S, time, outputFile));
```

这里做了四件事：

1. 初始事件迭代，直到 `discreteStatesNeedUpdate = fmi3False`。
2. 进入 `ContinuousTimeMode`。
3. 取初始事件指示器、连续状态、标称值。
4. 记录 `t = startTime` 的输出。

注意 `previous_z` 是在进入 `ContinuousTimeMode` 之后取的。因为 `fmi3GetEventIndicators` 在 `EventMode` 和 `ContinuousTimeMode` 都允许，示例选择在进入连续模式之后取，确保拿到的是积分起点对应的值。

### 7.8.4 事件检测与处理（第 103–163 行）

这是整个示例的核心：

```c
while (!terminateSimulation) {

    inputEvent = time >= nextInputEventTime(time);
    timeEvent  = nextEventTimeDefined && time >= nextEventTime;

    const bool eventOccurred = inputEvent || timeEvent || stateEvent || stepEvent;

    if (eventOccurred) {

        CALL(FMI3EnterEventMode(S));

        if (inputEvent) {
            CALL(applyContinuousInputs(S, time, true));
            CALL(applyDiscreteInputs(S, time));
        }

        nominalsOfContinuousStatesChanged = fmi3False;
        valuesOfContinuousStatesChanged   = fmi3False;

        do {
            fmi3Boolean nominalsChanged = fmi3False;
            fmi3Boolean statesChanged   = fmi3False;

            CALL(FMI3UpdateDiscreteStates(S, &discreteStatesNeedUpdate,
                &terminateSimulation, &nominalsChanged, &statesChanged,
                &nextEventTimeDefined, &nextEventTime));

            nominalsOfContinuousStatesChanged |= nominalsChanged;
            valuesOfContinuousStatesChanged   |= statesChanged;

            if (terminateSimulation) {
                goto TERMINATE;
            }
        } while (discreteStatesNeedUpdate);

        CALL(FMI3EnterContinuousTimeMode(S));

        CALL(recordVariables(S, time, outputFile));

#if NX > 0
        if (valuesOfContinuousStatesChanged) {
            CALL(FMI3GetContinuousStates(S, x, NX));
        }
        if (nominalsOfContinuousStatesChanged) {
            CALL(FMI3GetNominalsOfContinuousStates(S, x_nominal, NX));
        }
#endif
    }
    ...
}
```

几个要点：

- **事件检测在循环开头**：`inputEvent` 和 `timeEvent` 都是「当前时间是否到达」。`stateEvent` 和 `stepEvent` 是上一轮积分结束时留下的标志。
- **先 `EnterEventMode`，再设置输入**：因为输入变化属于事件的一部分，必须在 `EventMode` 中应用。
- **事件迭代用 `do/while`**：至少调用一次 `fmi3UpdateDiscreteStates`，然后根据 `discreteStatesNeedUpdate` 决定是否继续。
- **标志用 `|=` 累积**：`nominalsChanged` 和 `statesChanged` 可能在多次迭代中先后为真，导入端要记住「曾经变过」。
- **事件后重新取状态**：如果 `valuesOfContinuousStatesChanged` 为真，必须重新 `fmi3GetContinuousStates`。BouncingBall 的碰撞就是这种情况。
- **事件后记录输出**：在 `EnterContinuousTimeMode` 之后记录，得到的是事件处理后的值。

### 7.8.5 积分推进（第 165–188 行）

```c
if (time >= stopTime) {
    goto TERMINATE;
}

#if NX > 0
CALL(FMI3GetContinuousStateDerivatives(S, der_x, NX));
#endif

time = ++step * fixedStep;

CALL(FMI3SetTime(S, time));
CALL(applyContinuousInputs(S, time, false));

#if NX > 0
for (size_t i = 0; i < NX; i++) {
    x[i] += fixedStep * der_x[i];   // forward Euler
}

CALL(FMI3SetContinuousStates(S, x, NX));
#endif
```

这是一个显式欧拉步：

1. 在当前 `time` 取导数 `der_x`。
2. 时间前进 `fixedStep`。
3. 设置新时间。
4. 设置新时间的连续输入。
5. 用 `x += h * der_x` 更新状态。
6. 把新状态写回 FMU。

示例先 `fmi3SetTime`，再 `fmi3SetContinuousStates`。状态的含义依赖于时间，先写状态再改时间，会让 FMU 在旧时间上解释新状态。`fmi3SetContinuousStates` 又必须在 `fmi3GetEventIndicators` 之前，因为指示器是 `x` 的函数。

### 7.8.6 事件指示器与完成步（第 190–222 行）

```c
#if NZ > 0
stateEvent = fmi3False;

if (eventOccurred) {
    CALL(FMI3GetEventIndicators(S, previous_z, NZ));
} else {
    CALL(FMI3GetEventIndicators(S, z, NZ));

    for (size_t i = 0; i < NZ; i++) {
        if (previous_z[i] <= 0 && z[i] > 0) {
            rootsFound[i] = 1;
        } else if (previous_z[i] > 0 && z[i] <= 0) {
            rootsFound[i] = -1;
        } else {
            rootsFound[i] = 0;
        }

        stateEvent |= rootsFound[i];
        previous_z[i] = z[i];
    }
}
#endif

CALL(FMI3CompletedIntegratorStep(S, fmi3True, &stepEvent, &terminateSimulation));

CALL(recordVariables(S, time, outputFile));
```

这段有两个容易忽略的设计：

**第一，事件发生后要重置 `previous_z`。** 事件处理可能把 `z` 从负值抬到正值（BouncingBall 的 `h = DBL_MIN`）。如果不重置，下一轮会看到 `previous_z < 0`、`z > 0`，误判为一次新的状态事件。代码用 `if (eventOccurred) GetEventIndicators(previous_z)` 把基准重置到事件后的值。

**第二，先取指示器，再调用 `CompletedIntegratorStep`。** 规范说 `CompletedIntegratorStep` 要在事件定位之后调用；对于没有定位的示例，至少要在状态更新和指示器读取之后调用。代码把 `GetEventIndicators` 放在前面，是为了让 `stateEvent` 参与本轮的事件判断。

### 7.8.7 这段代码的四个简化

作为教学示例，它有意省略了生产求解器必须做的事：

1. **没有事件定位**。发现符号域变化后，直接把步末当成事件时间。BouncingBall 第一次碰撞因此落在 `t = 0.453`、`h = -0.0043`，而不是精确的 `h = 0`。
2. **固定步长显式欧拉**。没有误差估计、没有步长自适应、没有刚性处理。Dahlquist 这类模型可以跑，Roberts 这类刚性模型会不稳定。
3. **没有利用 `needsCompletedIntegratorStep`**。示例无条件调用 `CompletedIntegratorStep`；Reference 的所有 ME 模型都返回 `false`，所以它是空操作。
4. **`NX` / `NZ` 未定义**。这是本仓库快照的构建缺陷，导致 BouncingBall 的 ME 可执行文件实际上没有积分。7.10 节会专门验证。

这四点不影响我们学习调用顺序，但提醒我们：**示例代码是「调用序列的说明书」，不是「求解器的参考实现」**。

---

## 7.9 XML 与 ME 能力标志

ME 的 XML 元素只比公共属性多一个专属标志：

```xml
<ModelExchange
    modelIdentifier="BouncingBall"
    canGetAndSetFMUState="true"
    canSerializeFMUState="true"
    needsCompletedIntegratorStep="false"/>
```

`needsCompletedIntegratorStep` 的含义在 3.4 节：

> 如果为 `true`，每个完成的积分步之后必须调用 `fmi3CompletedIntegratorStep`；如果为 `false`，即使调用也没有效果。

其余标志来自公共能力表：

| 标志 | 默认 | 对 ME 的含义 |
| --- | --- | --- |
| `modelIdentifier` | 必需 | DLL/共享库名，也是 C 函数前缀 |
| `needsExecutionTool` | `false` | 是否需要外部工具才能运行 |
| `canBeInstantiatedOnlyOncePerProcess` | `false` | 一个进程是否只能实例化一次 |
| `canGetAndSetFMUState` | `false` | 是否支持 `fmi3GetFMUState` / `fmi3SetFMUState` / `fmi3FreeFMUState` |
| `canSerializeFMUState` | `false` | 是否支持序列化状态；为 `true` 时 `canGetAndSetFMUState` 必须也为 `true` |
| `providesDirectionalDerivatives` | `false` | 是否支持 `fmi3GetDirectionalDerivative` |
| `providesAdjointDerivatives` | `false` | 是否支持 `fmi3GetAdjointDerivative` |
| `providesPerElementDependencies` | `false` | 是否支持运行时查询逐元素依赖 |
| `providesEvaluateDiscreteStates` | `false` | 是否支持 `fmi3EvaluateDiscreteStates` |

Reference FMUs 的 ME 模型全部设置：

- `canGetAndSetFMUState="true"`
- `canSerializeFMUState="true"`
- `needsCompletedIntegratorStep` 缺省（即 `false`）

其中 `Roberts` 和 `VanDerPol` 还设置了 `providesDirectionalDerivatives="true"` 和 `providesAdjointDerivatives="true"`。

### 7.9.1 `ModelStructure` 决定数组顺序

ME 的两个核心数组——连续状态 `x` 和事件指示器 `z`——的顺序不是随便定的，而是由 `ModelStructure` 的子元素顺序决定：

```xml
<ModelStructure>
  <Output valueReference="1" dependencies=""/>
  <Output valueReference="3" dependencies=""/>
  <ContinuousStateDerivative valueReference="2" dependencies="3" dependenciesKind="constant"/>
  <ContinuousStateDerivative valueReference="4" dependencies="5" dependenciesKind="constant"/>
  <InitialUnknown valueReference="2" dependencies="3" dependenciesKind="constant"/>
  <InitialUnknown valueReference="4" dependencies="5" dependenciesKind="constant"/>
  <EventIndicator valueReference="1"/>
</ModelStructure>
```

对 BouncingBall：

- `x[0]` 对应 `der(h)` 的 `valueReference="2"`，也就是 `h`。
- `x[1]` 对应 `der(v)` 的 `valueReference="4"`，也就是 `v`。
- `z[0]` 对应 `EventIndicator valueReference="1"`，也就是 `h`。

`fmi3SetContinuousStates`、`fmi3GetContinuousStates`、`fmi3GetContinuousStateDerivatives`、`fmi3GetNominalsOfContinuousStates` 都使用这个顺序。`fmi3GetEventIndicators` 使用 `EventIndicator` 的顺序。

如果模型有数组状态，数组按 FMI 的序列化规则展平（行优先），顺序仍然是 `ContinuousStateDerivative` 的顺序。

### 7.9.2 状态数/指示器数什么时候会变

正常情况下，状态数和指示器数在 XML 里就确定了，不需要运行时查询。但有两种情况需要调用：

```c
size_t nx, nz;
fmi3GetNumberOfContinuousStates(fmu, &nx);
fmi3GetNumberOfEventIndicators(fmu, &nz);
```

- 数组状态的维度引用了 `structuralParameter`，并且该参数在 `ConfigurationMode` / `ReconfigurationMode` 中被修改。
- 事件指示器相关变量的维度引用了 `structuralParameter`，并且被修改。

这两个函数只能用于 ME。没有结构参数变化时，直接读 XML 的 `ModelStructure` 就够了。

---

## 7.10 动手实验

本章的实验设计成「不依赖预编译 ME 可执行文件也能完成」。第 3 个实验会解释为什么。

### 实验 1：从 XML 盘点 ME 能力

**目标**：读出每个模型的 ME 能力、连续状态数、事件指示器数，建立「模型结构 → 数组长度」的直觉。

在仓库根目录执行：

```powershell
function Count-Nodes($node) {
    if ($null -eq $node) { 0 }
    elseif ($node -is [System.Xml.XmlElement]) { 1 }
    else { @($node).Count }
}

Get-ChildItem .\examples\reference-fmus -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'FMI3.xml') } |
    ForEach-Object {
        $xml = [xml](Get-Content (Join-Path $_.FullName 'FMI3.xml') -Raw -Encoding UTF8)
        $md  = $xml.fmiModelDescription
        $me  = $md.ModelExchange
        [pscustomobject]@{
            Model      = $_.Name
            ME         = if ($me) { 'yes' } else { 'no' }
            States     = Count-Nodes $md.ModelStructure.ContinuousStateDerivative
            Indicators = Count-Nodes $md.ModelStructure.EventIndicator
            NeedsCIS   = if ($me) {
                if ($me.GetAttribute('needsCompletedIntegratorStep') -eq 'true') { 'true' } else { 'false' }
            } else { 'n/a' }
            GetSet     = if ($me) {
                if ($me.GetAttribute('canGetAndSetFMUState') -eq 'true') { 'true' } else { 'false' }
            } else { 'n/a' }
        }
    } | Format-Table -AutoSize
```

预期输出：

```text
Model        ME  States Indicators NeedsCIS GetSet
-----        --  ------ ---------- -------- ------
BouncingBall yes      2          1 false    true
Clocks       no       0          0 n/a      n/a
Dahlquist    yes      1          0 false    true
Feedthrough  yes      0          0 false    true
Resource     yes      0          0 false    true
Roberts      yes      2          2 false    true
Stair        yes      0          0 false    true
StateSpace   yes      1          0 false    true
VanDerPol    yes      2          0 false    true
```

观察：

- `Clocks` 没有 `<ModelExchange>`，它只用于 SE/CS 的时钟示例。
- `Feedthrough`、`Resource`、`Stair` 的 `States = 0`、`Indicators = 0`，所以它们的 ME 导入端可以跳过所有状态/事件指示器代码。
- 所有 ME 模型的 `NeedsCIS` 都是 `false`，说明 `fmi3CompletedIntegratorStep` 在当前 Reference 实现中是空操作。
- `BouncingBall` 是唯一同时有 2 个状态和 1 个指示器的模型，适合做事件实验。

### 实验 2：扫描 BouncingBall 的事件序列

**目标**：用导入端视角复现 BouncingBall 的碰撞事件，理解「事件指示器符号域变化」和「事件后重初始化」。

仓库里提供了一个不依赖 FMU 二进制的脚本：

```powershell
.\examples\scripts\bouncing-ball-event-scan.ps1
```

预期输出（节选）：

```text
Step = 0.001 s, StopTime = 3 s, e = 0.7
Events found: 12

Event  Time HeightBefore VelocityBefore VelocityAfter Stopped
-----  ---- ------------ -------------- ------------- -------
    1 0.453    -0.004328        -4.4439        3.1108   False
    2 1.089    -0.002496        -3.1284        2.1899   False
    3 1.537    -0.001187         -2.205        1.5435   False
    4 1.853    -0.000499        -1.5565        1.0895   False
   ...
   11 2.577     -7.8E-05        -0.1788        0.1252   False
   12 2.604     -6.4E-05        -0.1397             0   True

Ball stopped after event 12 (|v| < 0.1 m/s).
```

把脚本当成一个「手工写的 ME 导入端」，对照代码看：

1. `h += Step * v`、`v += Step * g` 对应显式欧拉。
2. `if ($h -le 0 -and $v -lt 0)` 对应事件指示器 `z = h` 从 `> 0` 变到 `<= 0`。
3. `$h = 2.2250738585072014E-308` 对应 `M(h) = DBL_MIN`，保证事件后 `z > 0`。
4. `$v = -$v * $e` 对应恢复系数。
5. `|v| < 0.1` 时停止，对应 `V_MIN`。

试试改变步长：

```powershell
.\examples\scripts\bouncing-ball-event-scan.ps1 -Step 0.0005
```

事件时间会变化：第一次碰撞从 `0.453` 变成 `0.452`，最后一次从 `2.604` 变成 `2.553`。继续减小步长到 `0.0001`，事件次数甚至会从 12 变成 11——小球在最后一次反弹后的速度刚好跨过 `|v| < 0.1` 的停止阈值。

这不是事件指示器定义的问题，而是两个数值效应叠加：

1. **显式欧拉有累积误差**，步长越大，弹跳周期偏差越大。
2. **停止条件本身是一个离散决策**：`|v|` 接近 `0.1` 时，积分误差会改变「是否停止」的判断。

所以这个脚本只适合观察事件序列的定性行为，不适合验证事件时间的精度。真正的 ME 导入端应该在步内定位事件时间；带阈值的离散决策也应该加滞回，避免在阈值附近抖动。

### 实验 3：验证 `simulate_fmi3_me.c` 的 `NX` / `NZ` 陷阱

**目标**：通过静态分析证明「示例代码不一定是可直接运行的求解器」，并理解预处理器条件编译的影响。

先看 `NX` / `NZ` 在文件里出现在哪里：

```powershell
Select-String -Path .\examples\reference-fmus\examples\simulate_fmi3_me.c `
    -Pattern '\bNX\b|\bNZ\b' |
    ForEach-Object { $_.LineNumber.ToString() + ': ' + $_.Line.Trim() }
```

你会看到 20 多行，全部在 `#if NX > 0` / `#if NZ > 0` 或数组声明、循环里。再确认 `simulate_fmi3_me.c` 这个编译单元里没有定义它们：

```powershell
$files = @(
    '.\examples\reference-fmus\examples\simulate_fmi3_me.c',
    '.\examples\reference-fmus\examples\BouncingBall.c',
    '.\examples\reference-fmus\examples\util.h',
    '.\examples\reference-fmus\BouncingBall\config.h',
    '.\examples\reference-fmus\examples\Examples.cmake'
)

Select-String -Path $files -Pattern '#define\s+NX|#define\s+NZ|-DNX|-DNZ'
```

预期没有任何输出。

> **注意**：仓库里确实有一处 `#define NX 2`，在 `examples/jacobian.c` 里。它只属于 Jacobian 示例，和 `simulate_fmi3_me.c` 的编译单元无关。全局搜索时看到它，不要误以为 `BouncingBall_me` 也拿到了 `NX`。这正是宏定义最容易骗人的地方：**同名宏在不同编译单元里含义不同，甚至根本不存在**。

这意味着预处理器把 `NX`、`NZ` 都当成 `0`，于是：

- `fmi3GetContinuousStateDerivatives` 不会被调用。
- `fmi3SetContinuousStates` 不会被调用。
- `fmi3GetEventIndicators` 不会被调用。
- 整个积分循环只做 `fmi3SetTime`、`fmi3CompletedIntegratorStep` 和输出记录。

再统计一下示例里各 FMI 函数的调用次数（文本出现次数，不是运行时次数）：

```powershell
Select-String -Path .\examples\reference-fmus\examples\simulate_fmi3_me.c `
    -Pattern 'FMI3([A-Za-z0-9]+)\(' -AllMatches |
  ForEach-Object { $_.Matches } |
  ForEach-Object { $_.Groups[1].Value } |
  Group-Object |
  Sort-Object Count -Descending |
  Format-Table Count, Name -AutoSize
```

预期输出：

```text
Count Name
----- ----
    3 GetEventIndicators
    2 EnterContinuousTimeMode
    2 GetNominalsOfContinuousStates
    2 UpdateDiscreteStates
    2 GetContinuousStates
    1 GetContinuousStateDerivatives
    1 SetTime
    1 SetContinuousStates
    1 CompletedIntegratorStep
    1 ExitInitializationMode
    1 EnterInitializationMode
    1 EnterEventMode
    1 InstantiateModelExchange
```

这些调用都在源码里，但是否执行取决于 `#if`。这正是条件编译的危险：**代码看起来完整，运行时却可能整段被裁掉**。

> **结论**：本章不把 `BouncingBall_me.exe` 的输出当作 ME 行为的证据。要验证真实行为，需要给示例补上 `NX`/`NZ` 的定义，或者使用会生成这些宏的构建系统。实验 4 只把预编译示例当作「调用日志」来看，不作为数值正确性的依据。

### 实验 4（可选）：运行 ME 导入端，观察超密集时间

**目标**：观察事件时刻的重复时间戳，理解「同一 `t_R` 上的多次离散更新」。

前置条件：已经按 `examples/README.md` 编译过 Reference FMUs：

```powershell
cd examples/reference-fmus
cmake -B build .
cmake --build build --config Release
```

`build/` 已被 `.gitignore` 忽略，所以预编译的 `.exe` 可能不存在。下面的命令会先检查。

#### 4a. Feedthrough：三次输入事件

```powershell
$exe = '.\examples\reference-fmus\build\temp\Feedthrough_me.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch7-feedthrough'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

Import-Csv (Join-Path $dir 'Feedthrough_me_out.csv') |
    Group-Object time |
    Where-Object Count -gt 1 |
    Select-Object Name, Count |
    Format-Table -AutoSize

'EnterEventMode calls: ' +
    (Select-String -Path (Join-Path $dir 'Feedthrough_me_log.txt') `
        -Pattern 'fmi3EnterEventMode' -SimpleMatch).Count
```

预期输出：

```text
Name Count
---- -----
0.5      2
1        2
1.5      2

EnterEventMode calls: 3
```

CSV 里每个事件时刻出现两行，因为：

- 第一行是积分循环走到该时刻、事件处理**之前**的输出。
- 第二行是 `fmi3EnterEventMode` → `fmi3UpdateDiscreteStates` → `fmi3EnterContinuousTimeMode` 之后的输出。

同一个 `time` 值对应两个不同的超密集时间点 `(0.5, 0)` 和 `(0.5, 1)`。CSV 只记录 `t_R`，所以看起来像重复时间戳。

再看日志里的第一段事件：

```powershell
Select-String -Path (Join-Path $dir 'Feedthrough_me_log.txt') `
    -Pattern 'fmi3SetTime\(time=0.5\)|fmi3EnterEventMode|fmi3UpdateDiscreteStates|fmi3EnterContinuousTimeMode' |
    Select-Object -First 6 |
    ForEach-Object { $_.Line }
```

预期能看到：

```text
fmi3SetTime(time=0.5) -> OK
fmi3EnterEventMode() -> OK
fmi3UpdateDiscreteStates(...) -> OK
fmi3EnterContinuousTimeMode() -> OK
```

这个顺序对应 ME 的事件循环：设置时间 → 进入事件模式 → 事件迭代 → 回到连续时间模式。注意这是**输入事件**，不需要像状态事件那样先做步内定位，所以没有出现 `CompletedIntegratorStep` 的定位过程。

#### 4b. BouncingBall：验证 `NX = 0` 的后果

```powershell
$exe = '.\examples\reference-fmus\build\temp\BouncingBall_me.exe'
if (-not (Test-Path $exe)) {
    throw 'Build the examples first: see examples/README.md'
}
$exe = (Resolve-Path $exe).Path

$dir = Join-Path $env:TEMP 'fmi-ch7-bouncingball'
New-Item -ItemType Directory -Force $dir | Out-Null

Push-Location $dir
try { & $exe | Out-Null } finally { Pop-Location }

'Distinct h values: ' +
    ((Get-Content (Join-Path $dir 'BouncingBall_me_out.csv') |
        Select-Object -Skip 1 |
        ForEach-Object { ($_ -split ',')[1] } |
        Sort-Object -Unique) -join ', ')

'Derivative calls: ' +
    (Select-String -Path (Join-Path $dir 'BouncingBall_me_log.txt') `
        -Pattern 'fmi3GetContinuousStateDerivatives' -SimpleMatch).Count

'EventIndicator calls: ' +
    (Select-String -Path (Join-Path $dir 'BouncingBall_me_log.txt') `
        -Pattern 'fmi3GetEventIndicators' -SimpleMatch).Count
```

预期输出：

```text
Distinct h values: 1
Derivative calls: 0
EventIndicator calls: 0
```

`h` 始终是初始值 1，导数和事件指示器一次都没调用。这不是 BouncingBall 模型的问题，而是导入端示例的 `NX`/`NZ` 没有定义。实验 3 已经解释了原因。

> **教学价值**：这段实验告诉我们，看到「程序退出码 0」不等于「仿真正确」。导入端必须检查自己是否真的调用了状态、导数、事件指示器函数；否则可能只是把初始输出重复打印了 3000 次。

---

## 7.11 常见错误清单

1. **初始化后直接进连续时间模式**。漏掉初始 `fmi3UpdateDiscreteStates` 循环，离散状态还是旧值。
2. **在 `ContinuousTimeMode` 改离散输入或参数**。规范只允许连续输入和连续状态；离散变化必须进 `EventMode`。
3. **用 `previous_z * z <= 0` 判断状态事件**。会把 `0 → 负数` 和 `0 → 0` 误判为事件。应比较符号域。
4. **事件后不重置 `previous_z`**。BouncingBall 这类模型在事件后会把 `z` 从负抬到正，不重置会误触发第二次事件。
5. **事件后不重启积分器**。`fmi3EnterContinuousTimeMode` 之后，积分器必须丢弃事件前的步长历史，从事件时间重新开始。
6. **把 `fmi3CompletedIntegratorStep` 当成事件检测器**。它只负责步事件和缓冲区更新；时间/状态事件由导入端检测。
7. **`fmi3SetTime` 倒退过头**。不能早于 `startTime`、倒数第二次 `CompletedIntegratorStep`、最后一次 `EnterEventMode` 三者中的最大值。
8. **在 `EventMode` 里忘记 `fmi3UpdateDiscreteStates`**。每个超密集时间点至少调用一次。
9. **把 ME 当 CS 调 `fmi3DoStep`**。ME 没有 `StepMode`，`fmi3DoStep` 只属于 CS。
10. **忽略 `valuesOfContinuousStatesChanged`**。BouncingBall 碰撞后 `h`、`v` 都被 `reinit`，不重新取状态会继续用旧值积分。

---

## 小结

- ME 是「FMU 提供方程，导入端提供求解器」：状态存储、积分、步长控制、事件定位都在导入端。
- 主路径是 `Instantiate → InitializationMode → EventMode → (初始事件迭代) → ContinuousTimeMode → 积分 ⇄ EventMode → Terminate`。
- `ContinuousTimeMode` 只计算 `f_cont`；离散变量冻结，关系 `•r` 冻结。`fmi3EnterContinuousTimeMode` 负责 `•r := r`、停用 `f_event`、激活 `f_cont`。
- 状态事件由事件指示器的**符号域变化**定义：`z > 0` ↔ `z <= 0`；`z = 0` 属于 `<= 0` 一侧。离开 `EventMode` 后 FMU 必须保证 `z != 0`。
- 四类事件：输入事件（导入端）、时间事件（FMU 预告、导入端触发）、状态事件（导入端用 `z` 检测）、步事件（FMU 通过 `CompletedIntegratorStep` 请求）。
- `fmi3SetTime` 的回退下限是 `startTime`、倒数第二次 `CompletedIntegratorStep`、最后一次 `EnterEventMode` 三者的最大值。
- `fmi3CompletedIntegratorStep` 只在 `needsCompletedIntegratorStep = true` 时必须调用；它不负责时间/状态事件检测。
- `simulate_fmi3_me.c` 展示了完整调用序列，但它是教学示例：没有事件定位、固定步长显式欧拉，而且本仓库快照的 `NX`/`NZ` 未定义，导致 BouncingBall 的 ME 可执行文件实际上没有积分。
- XML 中 `ModelStructure/ContinuousStateDerivative` 的顺序决定 `x` 的顺序，`EventIndicator` 的顺序决定 `z` 的顺序。

---

## 习题

### 1. 找出第一个非法调用

下面每个序列都从成功实例化开始。指出**第一个**违反状态机或前置条件的调用，并给出修正方案。

1. ME：`fmi3InstantiateModelExchange` → `fmi3GetContinuousStates`
2. ME：`fmi3EnterInitializationMode` → `fmi3ExitInitializationMode` → `fmi3EnterEventMode`
3. ME，已在 `ContinuousTimeMode`：`fmi3SetFloat64` 修改一个 `variability="discrete"` 的输入
4. ME，已在 `ContinuousTimeMode`：`fmi3CompletedIntegratorStep` → `fmi3EnterEventMode` → `fmi3CompletedIntegratorStep`
5. ME，`startTime = 0`，倒数第二次 `CompletedIntegratorStep` 在 `0.2`，最后一次在 `0.3`，最后一次 `EnterEventMode` 在 `0.35`：`fmi3SetTime(0.34)`
6. ME：`fmi3ExitInitializationMode` → `fmi3EnterContinuousTimeMode` → `fmi3EnterContinuousTimeMode`

<details>
<summary>答案</summary>

1. 第一个非法调用是 `fmi3GetContinuousStates`：此时还在 `Instantiated`，该函数只允许在 `InitializationMode`、`EventMode`、`ContinuousTimeMode`、`Terminated` 等状态。修正：先 `fmi3EnterInitializationMode`，再初始化，再 `fmi3ExitInitializationMode`。
2. 第一个非法调用是 `fmi3EnterEventMode`：`fmi3ExitInitializationMode` 之后已经在 `EventMode`，而 `fmi3EnterEventMode` 只能从 `ContinuousTimeMode` 进入。修正：直接做初始事件迭代，然后 `fmi3EnterContinuousTimeMode`。
3. 非法。`ContinuousTimeMode` 中 `fmi3Set{VariableType}` 只允许连续输入和连续状态；离散输入必须在 `EventMode` 中设置。修正：先 `fmi3EnterEventMode`，设置离散输入，做事件迭代，再 `fmi3EnterContinuousTimeMode`。
4. 第二个 `fmi3CompletedIntegratorStep` 非法：它只能在 `ContinuousTimeMode` 调用，而 `fmi3EnterEventMode` 已经把状态切到 `EventMode`。修正：删掉第二个调用；事件处理完、回到 `ContinuousTimeMode` 后再调用。
5. 非法。允许的最早时间是 `max(0, 0.2, 0.35) = 0.35`，`0.34` 早于最后一次 `EnterEventMode`。修正：不要回到事件之前；如果确实需要，只能从更早的保存状态恢复（且受 `noSetFMUStatePriorToCurrentPoint` 约束）。
6. 第二个 `fmi3EnterContinuousTimeMode` 非法：第一次调用后状态已经是 `ContinuousTimeMode`，该函数只能从 `EventMode` 进入。修正：删掉重复调用。

</details>

### 2. 事件指示器的符号域

某 ME 模型只有一个事件指示器。积分器在每个网格点的 `z` 值为：

```text
step:   1     2     3     4     5     6     7     8
z:    1.0   0.4   0.0  -0.2  -0.1   0.3   0.0  -0.05
```

回答：

1. 哪些步之间发生了状态事件？
2. 第 3 步的 `z = 0` 属于哪个符号域？
3. 如果导入端用 `previous_z * z <= 0` 判断，会多报哪些事件？
4. 如果这是 BouncingBall，事件处理后 `z` 应该变成什么符号？为什么？

<details>
<summary>答案</summary>

1. 第 2→3 步（`0.4 > 0` → `0.0 <= 0`）、第 5→6 步（`-0.1 <= 0` → `0.3 > 0`）和第 6→7 步（`0.3 > 0` → `0.0 <= 0`）发生状态事件。一共 3 次。
2. `z = 0` 属于 `z <= 0` 域。
3. 乘积判断会在第 2→3、3→4、5→6、6→7、7→8 步都报「乘积 ≤ 0」。其中第 3→4 步（`0 * -0.2 = 0`）和第 7→8 步（`0 * -0.05 = 0`）是误报：两者都在 `<= 0` 域，没有域变化。第 2→3、5→6、6→7 步是真事件。也就是说，乘积判断把真事件和「0 乘任何数」混在一起，无法区分。
4. 应该变成正号（`z > 0`）。BouncingBall 在事件更新中把 `h` 设为 `DBL_MIN`，略大于 0；这样离开 `EventMode` 后 `z = h > 0`，避免 `z = 0` 导致的重复事件，并为下一次碰撞准备正确的初始符号域。

</details>

### 3. `fmi3SetTime` 的合法范围

某 ME 仿真的时间线如下：

```text
startTime = 0
CompletedIntegratorStep 调用于：0.1, 0.2, 0.3
事件定位后，CompletedIntegratorStep 调用于：0.35
随后 EnterEventMode 调用，时间为：0.35
```

回答：

1. 在事件定位阶段（`EnterEventMode` 之前），`fmi3SetTime` 允许的最早时间是多少？
2. 进入 `EventMode` 之后，允许的最早时间是多少？
3. 下列调用哪些合法：`SetTime(0.15)`、`SetTime(0.25)`、`SetTime(0.35)`、`SetTime(0.4)`？分别说明是在哪个阶段。
4. 为什么规范用「倒数第二次」`CompletedIntegratorStep`，而不是「最后一次」？

<details>
<summary>答案</summary>

1. `max(startTime, 倒数第二次 CIS) = max(0, 0.2) = 0.2`。事件定位需要在最后一个积分步 `0.3 → 0.35` 内回退，所以允许回到 `0.2` 之后。
2. `max(0, 0.3, 0.35) = 0.35`。最后一次 `EnterEventMode` 把下限抬到了事件时间。
3. 事件定位阶段：`0.25`、`0.35`、`0.4` 合法；`0.15` 非法（早于 0.2）。进入 `EventMode` 后：`0.35`、`0.4` 合法；`0.15`、`0.25` 非法（早于 0.35）。
4. 因为事件定位需要在当前积分步内回退。如果下限是最后一次 `CompletedIntegratorStep`，导入端就无法回到这一步的起点做二分；用倒数第二次，正好允许「回退一个已完成步」。而一旦进入 `EventMode`，就不能再回到事件之前，因为离散状态只能向前计算。

</details>

### 4. 碰撞事件的输出标志

BouncingBall 在 `t = 0.453` 发生碰撞。假设事件迭代的最后一次 `fmi3UpdateDiscreteStates` 返回：

```text
discreteStatesNeedUpdate          = false
terminateSimulation               = false
nominalsOfContinuousStatesChanged = false
valuesOfContinuousStatesChanged   = true
nextEventTimeDefined              = false
nextEventTime                     = 0
```

回答：

1. 事件迭代是否结束？下一步调用什么？
2. 导入端必须重新读取什么？在 `EnterContinuousTimeMode` 之前还是之后读？
3. `nextEventTimeDefined = false` 意味着什么？导入端接下来如何决定步长？
4. 为什么 BouncingBall 要把 `valuesOfContinuousStatesChanged` 置为 `true`，而不是让导入端自己从 `h` 推断？

<details>
<summary>答案</summary>

1. 结束。`discreteStatesNeedUpdate = false` 表示当前超密集时间点已收敛；下一步调用 `fmi3EnterContinuousTimeMode`。
2. 必须重新读取连续状态 `x`（`h` 和 `v`），可以调用 `fmi3GetContinuousStates`，也可以对 `reinit="true"` 的状态逐个 `fmi3GetFloat64`。规范允许在 `EventMode` 或 `ContinuousTimeMode` 读取；示例选择在 `EnterContinuousTimeMode` 之后读，两者都可以，但必须在继续积分之前完成。
3. 没有已知的下一个时间事件。导入端只根据积分器的误差控制和 `stopTime` 决定步长；如果之后有输入事件，由导入端自己的输入调度决定。
4. 因为 `h` 和 `v` 的 `reinit="true"`，事件更新直接改了状态值，但没有通过 `fmi3SetContinuousStates` 通知导入端。`valuesOfContinuousStatesChanged` 是 FMU 主动告诉导入端「你手里的 `x` 已经过期了」的唯一通道。让导入端从 `h` 推断不可靠：它不知道 FMU 内部是否还改了别的状态，也不知道 `reinit` 的具体规则。

</details>

### 5. 读代码：为什么这样安排顺序

回看 7.8.6 的代码：

```c
if (eventOccurred) {
    CALL(FMI3GetEventIndicators(S, previous_z, NZ));
} else {
    CALL(FMI3GetEventIndicators(S, z, NZ));
    /* 比较 previous_z 和 z，设置 stateEvent */
}

CALL(FMI3CompletedIntegratorStep(S, fmi3True, &stepEvent, &terminateSimulation));
```

回答：

1. 为什么事件发生后要单独把 `z` 读进 `previous_z`，而不是继续用旧的 `previous_z`？
2. 为什么 `fmi3GetEventIndicators` 要在 `fmi3CompletedIntegratorStep` 之前调用？
3. `stateEvent |= rootsFound[i];` 中 `rootsFound[i]` 可能是 `-1`，为什么还能用 `|=`？
4. 如果把 `fmi3CompletedIntegratorStep` 移到 `if (eventOccurred)` 之前，会有什么问题？

<details>
<summary>答案</summary>

1. 事件处理可能改变状态，从而改变 `z` 的符号域。BouncingBall 把 `h` 从负值抬到 `DBL_MIN`，`z` 从 `<= 0` 跳到 `> 0`。如果不重置 `previous_z`，下一轮会把这个跳变误判为新的状态事件。重置后，基准是事件后的值，下一次碰撞才能被正确检测。
2. 因为 `CompletedIntegratorStep` 的语义是「当前时间、当前输入、当前状态都有效，步被接受」。事件指示器是当前状态的函数，先读它才能在本轮判断是否需要事件；同时，规范要求 `CompletedIntegratorStep` 在事件定位之后调用，先读指示器符合这个顺序。
3. `rootsFound[i]` 取值是 `-1`、`0`、`1`。`stateEvent` 是 `fmi3Boolean`，在 C 中通常用 `0/1` 表示；`stateEvent |= -1` 会把 `stateEvent` 变成一个非零值（通常是 `-1` 或全 1），在布尔判断中仍然为真。示例只把它当布尔用，所以能工作。更严谨的写法是 `stateEvent = stateEvent || (rootsFound[i] != 0);`。
4. 如果把它移到 `if (eventOccurred)` 之前，它会在读取指示器、判断符号域之前被调用，也就是在事件定位之前。这违反规范「事件定位后调用」的语义；FMU 可能据此认为当前步已被接受，从而更新缓冲区或返回错误的步事件。状态机层面它仍在 `ContinuousTimeMode`，不一定立刻报错，但语义已经错了。

</details>

### 6. 能力标志与 XML 一致性

某 ME FMU 的 XML 片段：

```xml
<ModelExchange
    modelIdentifier="Plant"
    canGetAndSetFMUState="false"
    canSerializeFMUState="true"
    needsCompletedIntegratorStep="true"
    providesDirectionalDerivatives="false"/>
```

回答：

1. 这个 XML 本身是否合法？依据是什么？
2. 如果忽略第 1 问的问题，导入端在每个完成的积分步后必须做什么？
3. 导入端可以调用 `fmi3GetDirectionalDerivative` 吗？
4. 导入端可以调用 `fmi3SerializeFMUState` 吗？
5. 如果导入端仍然调用了 `fmi3CompletedIntegratorStep`，但 XML 把 `needsCompletedIntegratorStep` 改成 `false`，会发生什么？

<details>
<summary>答案</summary>

1. 不合法。规范规定 `canSerializeFMUState = true` 时，`canGetAndSetFMUState` 必须也为 `true`。这里前者为 `true`、后者为 `false`，自相矛盾。导出端不应生成这样的 XML，导入端应报错或拒绝序列化功能。
2. 必须调用 `fmi3CompletedIntegratorStep`，并且要传入有效的 `time`、连续输入和连续状态；然后检查 `enterEventMode` 和 `terminateSimulation`。
3. 不可以。`providesDirectionalDerivatives = false` 表示不支持方向导数；调用应返回错误。
4. 不可以。虽然 XML 写了 `canSerializeFMUState="true"`，但前提条件不满足，整个状态序列化能力不可信；严格实现应拒绝。
5. 没有效果。规范说 `needsCompletedIntegratorStep = false` 时，即使调用 `fmi3CompletedIntegratorStep` 也不产生作用。导入端可以保留这个调用以兼容其他模型，但不能依赖它做任何状态更新。

</details>

### 7. 设计题：把 CS 循环改写成 ME 循环

某导入端原本按 CS 方式写循环：

```c
fmi3ExitInitializationMode(fmu);
fmi3EnterStepMode(fmu);

while (time < stopTime) {
    fmi3DoStep(fmu, time, stepSize, fmi3True,
               &eventHandlingNeeded, &terminate, &earlyReturnTime);
    time += stepSize;
    recordOutputs(fmu, time);
}
```

现在要换成一个 **ME** FMU，模型有连续状态、事件指示器和一个 `nextEventTime`。请回答：

1. 哪些 CS 调用在 ME 中不存在？用什么替代？
2. 初始事件迭代应该放在哪里？
3. 主循环中，检测状态事件需要哪三个数组/变量？
4. 检测到状态事件后，进入 `EventMode` 之前至少要做什么？
5. 为什么 ME 循环不能像 CS 那样只按固定 `stepSize` 记录输出？

<details>
<summary>答案</summary>

1. `fmi3EnterStepMode` 和 `fmi3DoStep` 在 ME 中不存在。替代方案是：`fmi3EnterContinuousTimeMode` + 自己实现积分器（`fmi3GetContinuousStateDerivatives`、`fmi3SetContinuousStates`），事件检测用 `fmi3GetEventIndicators`，事件处理用 `fmi3EnterEventMode` + `fmi3UpdateDiscreteStates`。
2. 在 `fmi3ExitInitializationMode` 之后、`fmi3EnterContinuousTimeMode` 之前。必须循环调用 `fmi3UpdateDiscreteStates` 直到 `discreteStatesNeedUpdate = fmi3False`。
3. `previous_z`（上一步的指示器值）、`z`（当前步的指示器值）、`rootsFound`（每个指示器的变化方向）；还需要 `stateEvent` 作为汇总布尔量。
4. 至少要在步内定位事件时间（二分/插值），在事件时间设置 `time` 和连续状态，然后调用 `fmi3CompletedIntegratorStep`。规范要求事件定位后调用它，再 `fmi3EnterEventMode`。
5. CS 的 FMU 自己保证在通信步内处理事件和积分误差；ME 的导入端必须自己决定什么时候记录输出。固定 `stepSize` 记录会错过事件时刻的跳变，也会在刚性模型中产生不稳定的结果。ME 导入端通常按积分器的接受步记录，并在每个事件时刻额外记录一次（包括同一 `t_R` 的多个超密集时间点）。

</details>

### 8. 判断题

1. ME 的 FMU 内部保存连续状态，导入端通过 `fmi3GetContinuousStates` 读取即可，不需要 `fmi3SetContinuousStates`。
2. `fmi3EnterEventMode` 可以从 `EventMode` 调用，用于再次触发事件迭代。
3. 在 `ContinuousTimeMode` 中，关系 `r` 会在每次 `fmi3GetContinuousStateDerivatives` 时重新计算。
4. `fmi3CompletedIntegratorStep` 可以用来检测时间事件。
5. `fmi3SetTime` 允许在 `EventMode` 中调用，所以可以在事件模式里随意倒退时间。
6. `fmi3UpdateDiscreteStates` 在每个超密集时间点至少调用一次。
7. `valuesOfContinuousStatesChanged = true` 时，导入端必须重新读取连续状态。
8. `needsCompletedIntegratorStep = false` 时，调用 `fmi3CompletedIntegratorStep` 会返回 `fmi3Error`。
9. 事件指示器 `z` 在离开 `EventMode` 后必须非零。
10. ME 的 `x` 顺序由 XML 中变量的声明顺序决定。

<details>
<summary>答案</summary>

1. 错。ME 的连续状态由导入端保存和推进；导入端必须通过 `fmi3SetContinuousStates` 把积分后的状态写回 FMU，否则 FMU 还在用旧状态计算导数和事件指示器。
2. 错。`fmi3EnterEventMode` 只能从 `ContinuousTimeMode`（ME）或 `StepMode`（CS）进入；在 `EventMode` 中再次调用是非法的。重复事件迭代靠继续调用 `fmi3UpdateDiscreteStates`，不是重新 `EnterEventMode`。
3. 错。`ContinuousTimeMode` 中关系是冻结的，使用 `•r`；关系只在 `EventMode` 中更新，离开事件模式时复制到 `•r`。
4. 错。时间事件由导入端根据 `nextEventTime` 检测；`fmi3CompletedIntegratorStep` 只用于步事件和缓冲区更新。
5. 错。规范 3.2 只在 `ContinuousTimeMode` 中定义 `fmi3SetTime`；即使某些实现（如 Reference 的掩码）允许在 `EventMode` 调用，也不能倒退到事件之前，因为离散状态不能倒推。
6. 对。规范要求每个超密集时间点至少调用一次，即使没有离散状态。
7. 对。这是 FMU 通知导入端「状态被 `reinit` 改了」的唯一通道；应调用 `fmi3GetContinuousStates` 或逐个读取 `reinit="true"` 的状态。
8. 错。规范说 `needsCompletedIntegratorStep = false` 时调用它「没有效果」，不是报错。
9. 对。FMU 必须保证离开 `EventMode` 后 `z != 0`，通常通过滞回或小幅平移实现。
10. 错。`x` 的顺序由 `ModelStructure/ContinuousStateDerivative` 的顺序决定，不是 `ModelVariables` 中变量的声明顺序。

</details>

---

## 下一章

ME 把求解器的工作交给了导入端。下一章看另一种极端：FMU 自己就是一个完整的仿真器，导入端只需要按通信步长调用 `fmi3DoStep`。我们会讲清楚早返回、中间更新、通信步长和 `fmi3Set{Interval|Shift}Fraction`，并逐段读 `simulate_fmi3_cs.c`。

→ [第 8 章 Co-Simulation](08-co-simulation.md)
