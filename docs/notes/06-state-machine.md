# 第 6 章 公共状态机

> **第三部分：接口与状态机 · 初稿**
> 对应规范：[2.3 State Machine and Semantics](../spec-3.0.2/html/index.html#common-state-machine)
> 预计阅读：40 分钟
> 动手时间：20 分钟

## 学习目标

读完本章，你应该能够：

1. 解释为什么 FMI 用状态机规定「什么时候能调用哪个函数」，而不只是描述生命周期。
2. 说出 6 个公共状态和 2 个超级状态，并说明 `FMU State Settable` 与 `Initialized` 的边界。
3. 正确使用 `fmi3Instantiate*` 的参数，并区分返回 `NULL`、`fmi3Error`、`fmi3Fatal` 三种失败。
4. 画出 ME、CS、SE 三条从实例化到终止的主路径，指出它们的分岔点。
5. 解释 `fmi3UpdateDiscreteStates` 的事件迭代，以及每个输出标志的含义。
6. 区分 `ConfigurationMode` 与 `ReconfigurationMode`，知道同一对函数为什么会进入两个不同状态。
7. 在 `Terminated` 状态下只做允许的读取，并能用 `fmi3Reset` 开始第二次运行。
8. 对照 Reference FMUs 的实现检查一个导入端的调用序列，并识别「实现比规范宽松」的地方。

第 3–5 章把 FMU 当成一个静态包来读：XML 里有哪些元素、变量有哪些属性、单位怎么换算。从本章开始，FMU 动起来了。导入端会依次调用几十个 C 函数，而**不是所有函数在任何时候都能调用**。状态机就是这份调用契约。

本章只讲三种接口共享的部分。`ContinuousTimeMode`、`StepMode`、`ClockActivationMode` 这些接口专属状态会在第 7–9 章展开；这里先把它们放在图中的正确位置，知道它们从哪里来、回到哪里去。

---

## 6.1 状态机是调用契约

先看两个真实会犯的错误。

**错误一**：实例化后立刻读连续状态。

```c
fmi3Instance fmu = fmi3InstantiateModelExchange(...);

fmi3Float64 x[2];
fmi3GetContinuousStates(fmu, x, 2);   /* 此时还在 Instantiated */
```

`fmi3GetContinuousStates` 在 Model Exchange 中只允许出现在 `InitializationMode`、`EventMode`、`ContinuousTimeMode`、`Terminated` 等状态。`Instantiated` 下调用，FMU 应当返回 `fmi3Error`，并且 `x` 的内容没有定义。

**错误二**：CS 开了事件模式，`fmi3ExitInitializationMode` 之后直接 `fmi3DoStep`。

```c
fmi3InstantiateCoSimulation(..., fmi3True /* eventModeUsed */, ...);
fmi3EnterInitializationMode(...);
fmi3ExitInitializationMode(...);      /* 进入 EventMode，不是 StepMode */
fmi3DoStep(...);                      /* 非法：DoStep 只允许在 StepMode */
```

正确顺序是：先做初始事件迭代，再调用 `fmi3EnterStepMode`，然后才能 `fmi3DoStep`。

这两个例子的共同点是：**函数名没写错，参数也大致正确，错的是调用时机**。状态机把「时机」变成了可检查的规则。

### 6.1.1 规范怎么要求 FMU 处理非法调用

规范在 2.2 节写得很直接：

> When detecting illegal arguments or a function call not allowed in the current state according to the respective state machine, the FMU must return `fmi3Error`.

也就是说，非法调用不是「未定义但也许能跑」，而是 FMU **必须**报错。Reference FMUs 的实现用一个状态位掩码来检查：

```c
/* examples/reference-fmus/src/fmi3Functions.c */
static bool allowedState(ModelInstance *instance, int statesExpected, char *name) {

    if (!instance) {
        return false;
    }

    if (!(instance->state & statesExpected)) {
        logError(instance, "fmi3%s: Illegal call sequence.", name);
        return false;
    }

    return true;
}
```

每个函数入口用 `BEGIN_FUNCTION` 宏带上自己的掩码：

```c
#define BEGIN_FUNCTION(F) \
Status status = OK; \
if (!instance) return fmi3Error; \
ModelInstance *S = (ModelInstance *)instance; \
if (!allowedState(S, MASK_fmi3##F, #F)) CALL(Error);
```

这套写法值得借鉴：**状态检查放在函数入口，失败时统一走错误路径**，而不是在函数体各处零散判断。

### 6.1.2 合法调用 ≠ 结果正确

状态机只回答「能不能调用」，不保证「调用后值有意义」。例如：

- 在 `InitializationMode` 里 `fmi3GetFloat64` 是合法的，但如果某个变量还没有被 `f_init` 计算，返回的可能是它的 `start` 值。
- 在 `EventMode` 里 `fmi3GetFloat64` 是合法的，但离散状态还没通过 `fmi3UpdateDiscreteStates` 收敛，读到的是中间值。
- 在 `Terminated` 里 `fmi3GetFloat64` 是合法的，但如果是因为 `fmi3Error` 进入的，值只适合调试。

所以状态机要和每个状态的「方程与动作」表一起读：前者管调用顺序，后者管这次调用会激活哪些方程。

### 6.1.3 公共状态与接口专属状态

规范 2.3 只定义**至少被两种接口使用**的公共状态。三种接口各自还有专属状态：

| 状态 | ME | CS | SE | 作用 |
| --- | :---: | :---: | :---: | --- |
| `FMUStateSettable`（超级状态） | ✅ | ✅ | ✅ | 从成功实例化到释放的整个生命周期 |
| `Instantiated` | ✅ | ✅ | ✅ | 已实例化，尚未初始化 |
| `InitializationMode` | ✅ | ✅ | ✅ | 求一致初值 |
| `Initialized`（超级状态） | ✅ | ✅ | ✅ | 初始化完成后的运行期 |
| `EventMode` | ✅ | ✅（可选） | ❌ | 处理离散事件 |
| `ConfigurationMode` | ✅ | ✅ | ✅ | 初始化前设置结构参数 |
| `ReconfigurationMode` | ✅ | ✅ | ✅ | 运行中设置可调结构参数 |
| `Terminated` | ✅ | ✅ | ✅ | 终止，读取最终值 |
| `ContinuousTimeMode` | ✅ | ❌ | ❌ | ME 的连续时间积分 |
| `StepMode` | ❌ | ✅ | ❌ | CS 的通信步 |
| `ClockActivationMode` | ❌ | ❌ | ✅ | SE 的模型分区调度 |
| `IntermediateUpdateMode` | ❌ | ✅ | ❌ | CS 的中间更新回调 |
| `ClockUpdateMode` | ❌ | ❌ | ✅ | SE 的时钟更新回调 |

注意 CS 的 `EventMode` 是**有条件**的：只有 XML 里 `hasEventMode="true"`，并且导入端在实例化时传 `eventModeUsed=fmi3True`，才会有 `EventMode`。两个条件缺一不可。

---

## 6.2 一张图与一张表

公共状态机的主干可以压成下面这条线：

```text
fmi3Instantiate* 返回非 NULL
        │
        ▼
   Instantiated
        │ fmi3EnterInitializationMode
        ▼
 InitializationMode
        │ fmi3ExitInitializationMode
        ▼
    Initialized  ── ME ──▶ EventMode ⇄ ContinuousTimeMode
        │        ├─ CS ──▶ EventMode ⇄ StepMode   (eventModeUsed = true)
        │        ├─ CS ──▶ StepMode               (eventModeUsed = false)
        │        └─ SE ──▶ ClockActivationMode
        │
        │ fmi3Terminate（只能在初始化完成之后）
        ▼
    Terminated
        │ fmi3FreeInstance
        ▼
     (实例释放)
```

另外有三个旁路：

```text
Instantiated ⇄ ConfigurationMode
EventMode / StepMode / ClockActivationMode ⇄ ReconfigurationMode
任何有效实例状态 ──fmi3Reset──▶ Instantiated
```

把主干和旁路合起来，就是规范 2.3 的公共状态迁移表：

| 当前状态 | 调用 | 目标状态 | 约束 |
| --- | --- | --- | --- |
| （无） | `fmi3Instantiate*` 返回非 `NULL` | `Instantiated` | 对应 XML 中必须存在该接口元素 |
| `Instantiated` | `fmi3EnterInitializationMode` | `InitializationMode` | 记录 `startTime`、`stopTime` |
| `InitializationMode` | `fmi3ExitInitializationMode` | ME：`EventMode`；CS：`EventMode` 或 `StepMode`；SE：`ClockActivationMode` | 分岔点，见 6.5 |
| `Instantiated` | `fmi3EnterConfigurationMode` | `ConfigurationMode` | FMU 至少有一个 `structuralParameter` |
| `ConfigurationMode` | `fmi3ExitConfigurationMode` | `Instantiated` | 退出时重分配数组 |
| `EventMode` / `StepMode` / `ClockActivationMode` | `fmi3EnterConfigurationMode` | `ReconfigurationMode` | FMU 至少有一个 `tunable` 的 `structuralParameter` |
| `ReconfigurationMode` | `fmi3ExitConfigurationMode` | ME：`EventMode`；CS：`StepMode`；SE：`ClockActivationMode` | 退出时重分配数组 |
| `EventMode` | `fmi3EnterContinuousTimeMode` | `ContinuousTimeMode` | 仅 ME |
| `ContinuousTimeMode` | `fmi3EnterEventMode` | `EventMode` | 仅 ME |
| `EventMode` | `fmi3EnterStepMode` | `StepMode` | 仅 CS |
| `StepMode` | `fmi3EnterEventMode` | `EventMode` | 仅 CS，且 `eventModeUsed = true` |
| `EventMode` / `ContinuousTimeMode` / `StepMode` / `ClockActivationMode` | `fmi3Terminate` | `Terminated` | 初始化完成之后 |
| 任何有效实例状态 | `fmi3Reset` | `Instantiated` | 变量回到默认值，需要重新初始化 |
| 任何有效实例状态 | `fmi3FreeInstance` | （释放） | `NULL` 实例被忽略 |
| `FMUStateSettable` 内任意状态 | 某函数返回 `fmi3Error` | `Terminated` | 可用 `fmi3SetFMUState` 或 `fmi3Reset` 恢复 |
| `FMUStateSettable` 内任意状态 | 某函数返回 `fmi3Fatal` | （状态未定义） | 规范要求不再调用任何 FMI 函数 |

这张表有两个容易看漏的地方：

1. **没有 `fmi3ExitEventMode`**。离开 `EventMode` 靠的是 `fmi3EnterContinuousTimeMode`（ME）或 `fmi3EnterStepMode`（CS），名字看起来像「进入下一个模式」，实际上同时完成了「离开事件模式」。
2. **`fmi3EnterEventMode` 不能从 `EventMode` 调用**。它只从 `ContinuousTimeMode`（ME）或 `StepMode`（CS）进入。初始化刚结束时已经在 `EventMode`，不要再调一次。

---

## 6.3 生命周期起点：`fmi3Instantiate*`

三个实例化函数分别对应三种接口：

```c
fmi3Instance fmi3InstantiateModelExchange(
    fmi3String              instanceName,
    fmi3String              instantiationToken,
    fmi3String              resourcePath,
    fmi3Boolean             visible,
    fmi3Boolean             loggingOn,
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3LogMessageCallback  logMessage);

fmi3Instance fmi3InstantiateCoSimulation(
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

fmi3Instance fmi3InstantiateScheduledExecution(
    fmi3String                   instanceName,
    fmi3String                   instantiationToken,
    fmi3String                   resourcePath,
    fmi3Boolean                  visible,
    fmi3Boolean                  loggingOn,
    fmi3InstanceEnvironment      instanceEnvironment,
    fmi3LogMessageCallback       logMessage,
    fmi3ClockUpdateCallback      clockUpdate,
    fmi3LockPreemptionCallback   lockPreemption,
    fmi3UnlockPreemptionCallback unlockPreemption);
```

### 6.3.1 参数逐项看

| 参数 | 含义 | 常见错误 |
| --- | --- | --- |
| `instanceName` | 实例的唯一名字，用于日志和错误消息 | 传空串；同一进程内多个实例重名 |
| `instantiationToken` | 导出端生成的不透明字符串，必须与 XML 的 `instantiationToken` 一致 | 手写或复制错；用了另一个 FMU 的 token |
| `resourcePath` | 解包后 `resources/` 目录的绝对路径，带结尾分隔符 | 忘记结尾 `\`；目录不存在；没有资源却传了无效路径 |
| `visible` | `fmi3False` 表示批处理，`fmi3True` 表示可交互 | 在服务器/CI 中传 `true`，FMU 等待用户确认 |
| `loggingOn` | `fmi3False` 关闭所有日志；`fmi3True` 打开所有类别 | 关闭日志后排查实例化失败，只看到 `NULL` |
| `instanceEnvironment` | 导入端自己的上下文指针，会原样传给回调 | 传栈上临时变量，FMU 在回调里解引用时已失效 |
| `logMessage` | 日志回调，可为 `NULL` | 传 `NULL` 又期望看到失败原因 |

CS 还多三个参数：

- `eventModeUsed`：导入端**是否支持**事件模式。只有 XML 里 `hasEventMode="true"` 时才能传 `fmi3True`；FMU 有 Clock 时**必须**传 `fmi3True`。传 `fmi3False` 表示「事件由 FMU 内部处理，别把我叫进 EventMode」。
- `earlyReturnAllowed`：导入端是否能处理 `fmi3DoStep` 的早返回。只有为 `true` 时，FMU 才可能返回 `earlyReturn = fmi3True`。它和事件模式是两件事。
- `requiredIntermediateVariables` / `nRequiredIntermediateVariables`：导入端打算在 `IntermediateUpdateMode` 中访问的输入/输出变量。只有这个集合里的变量，才能在中间更新时被 `fmi3Get*` / `fmi3Set*` 访问；它们还必须在 XML 里标了 `intermediateUpdate="true"`。

SE 则多三个回调：`clockUpdate`、`lockPreemption`、`unlockPreemption`，分别用于时钟更新和抢占保护。

### 6.3.2 返回值：只有实例化返回指针

这是 FMI 3.0 API 的一个刻意设计：

- `fmi3Instantiate*` 返回 `fmi3Instance` 指针；失败返回 `NULL`。
- 绝大多数函数返回 `fmi3Status`；`fmi3GetVersion` 返回版本字符串，`fmi3FreeInstance` 返回 `void`。

如果返回 `NULL`，说明**没有可用的实例**。此时没有实例需要释放；规范规定 `fmi3FreeInstance(NULL)` 会被忽略，但绝不要把 `NULL` 传给其他 FMI 函数。规范要求 FMU 通过 `logMessage` 说明失败原因（受 `loggingOn` 和回调是否可用的约束）。常见原因包括 token 不匹配、资源目录缺失、内存不足、平台二进制不兼容。

一个最小但完整的实例化检查：

```c
fmi3Instance fmu = fmi3InstantiateCoSimulation(
    "instance1",
    "{1AE5E10D-9521-4DE3-80B9-D0EAAA7D5AF1}",
    "C:\\temp\\BouncingBall\\resources\\",
    fmi3False,   /* visible */
    fmi3False,   /* loggingOn */
    fmi3False,   /* eventModeUsed */
    fmi3False,   /* earlyReturnAllowed */
    NULL, 0,     /* requiredIntermediateVariables */
    NULL,        /* instanceEnvironment */
    logMessage,  /* logMessage */
    NULL         /* intermediateUpdate */
);

if (fmu == NULL) {
    /* 实例化失败：没有 fmi3Instance 可释放 */
    return -1;
}
```

### 6.3.3 一个 FMU 可以同时实现多种接口

Reference FMUs 里的 `BouncingBall` 同时有 `<ModelExchange>` 和 `<CoSimulation>` 元素，所以既可以调 `fmi3InstantiateModelExchange`，也可以调 `fmi3InstantiateCoSimulation`。`Clocks` 只有 `<ScheduledExecution>`，因此只能调 `fmi3InstantiateScheduledExecution`。

**调哪个实例化函数，不由导入端喜好决定，而由 XML 中存在的元素决定。** 调用一个不存在的接口，FMU 应返回 `NULL` 并记录错误。

同一进程内可以创建多个实例，除非 XML 的 `canBeInstantiatedOnlyOncePerProcess="true"`。这个标志默认是 `false`，所以「一个进程只能有一个实例」不是 FMI 的默认假设。

### 6.3.4 Reference 导入端的写法

Reference 的导入端把 `instanceName`、`instanceEnvironment`、`logMessage` 放进了自己的 `FMIInstance` 包装对象，所以调用看起来比原始 API 少几个参数：

```c
/* examples/reference-fmus/examples/simulate_fmi3_me.c */
CALL(FMI3InstantiateModelExchange(S,
    INSTANTIATION_TOKEN, // instantiationToken
    resourcePath(),      // resourcePath
    fmi3False,           // visible
    fmi3False            // loggingOn
));
```

```c
/* examples/reference-fmus/examples/simulate_fmi3_cs.c */
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
```

这里的 `S` 是导入端的包装对象，不是 `fmi3Instance`。读示例代码时要分清这一层，否则会误以为 FMI 的 `fmi3Instantiate*` 少参数。

---

## 6.4 `Instantiated`：初始化前的准备区

`Instantiated` 是实例化成功后的第一个状态。FMU 可以在这里做一次性初始化、分配内存、读取资源。

### 6.4.1 可以做什么

规范允许在 `Instantiated` 中：

- 用 `fmi3Set{VariableType}` 设置 `initial="exact"` 或 `initial="approx"`、且 `variability != constant` 的变量。典型的是参数、输入和状态的初值猜测。
- 用 `fmi3Get{VariableType}` 读取变量的当前值；没有设置过的变量通常是 XML 里的 `start` 值。
- 调用 `fmi3SetDebugLogging` 调整日志类别。
- 调用 `fmi3EnterConfigurationMode` 设置结构参数（见 6.7）。
- 调用 `fmi3EnterInitializationMode` 进入初始化。
- 调用 `fmi3GetFMUState` / `fmi3SetFMUState` 保存或恢复内部状态（前提是 XML 里 `canGetAndSetFMUState="true"`）。
- 调用 `fmi3Reset` 回到默认值。
- 调用 `fmi3FreeInstance` 直接释放。

### 6.4.2 不可以做什么

以下调用在 `Instantiated` 中非法：

- `fmi3ExitInitializationMode`：还没进初始化，不能退出。
- `fmi3DoStep`：CS 的步进只能在 `StepMode`。
- `fmi3EnterEventMode`：ME 只能从 `ContinuousTimeMode` 进，CS 只能从 `StepMode` 进。
- `fmi3Terminate`：终止只能在初始化完成之后。
- 设置 `variability="constant"` 的变量：常量在实例化后不可改。

最后一条经常被忽略。XML 里写成 `variability="constant"` 的量，不是「运行时可调参数」，而是编译期常量；`fmi3Set*` 必须返回 `fmi3Error`。

### 6.4.3 结构参数要在这里处理

如果 FMU 有 `causality="structuralParameter"` 的变量，并且导入端需要在初始化前改变数组维度，就必须走一次 `ConfigurationMode`：

```c
/* examples/reference-fmus/examples/cs_reconfiguration.c */
CALL(FMI3EnterConfigurationMode(S));

vr[0] = vr_m; p[0] = 2; // number of inputs
vr[1] = vr_n; p[1] = 0; // number of states
vr[2] = vr_r; p[2] = 2; // number of outputs

CALL(FMI3SetUInt64(S, vr, 3, p, 3));

CALL(FMI3ExitConfigurationMode(S));
```

`fmi3ExitConfigurationMode` 回到 `Instantiated`，之后才能 `fmi3EnterInitializationMode`。不要在 `ConfigurationMode` 里直接进初始化。

### 6.4.4 `fmi3EnterInitializationMode` 固定了时间窗

`fmi3EnterInitializationMode` 不只是「切换到下一个状态」，它还把仿真时间窗固定下来：

```c
fmi3Status fmi3EnterInitializationMode(
    fmi3Instance instance,
    fmi3Boolean  toleranceDefined,
    fmi3Float64  tolerance,
    fmi3Float64  startTime,
    fmi3Boolean  stopTimeDefined,
    fmi3Float64  stopTime);
```

- `startTime` 是独立变量的初值，后续超密集时间的实数部分从这里开始。
- `stopTimeDefined = fmi3True` 时，`stopTime` 是终止时间；如果导入端试图计算到 `stopTime` 之后，FMU 必须返回 `fmi3Error`。
- `stopTimeDefined = fmi3False` 表示没有终止时间，`stopTime` 无意义，FMU 不能依赖它。

这也解释了为什么 `fmi3EnterInitializationMode` 只能从 `Instantiated` 调：时间窗和初值必须在同一时刻确定，不能在运行中反复改。

---

## 6.5 `InitializationMode`：求一致初值

`InitializationMode` 的任务是计算整个系统的一致初值。对一个 FMU 来说，它激活初始化方程 `f_init`；对多个相连的 FMU 来说，导入端可能要在它们之间反复 `Get` / `Set`，解一个跨 FMU 的代数环。

### 6.5.1 可以设置什么

在 `InitializationMode` 中，`fmi3Set{VariableType}` 只允许用于：

- `variability != constant`，且 `initial="exact"` 的变量；
- 连续和离散输入 `u_c+d(t_start)`。

注意与 `Instantiated` 的区别：`initial="approx"` 的变量只能在 `Instantiated` 里设置，到了 `InitializationMode` 就不能再改。`initial="approx"` 的语义是「给求解器一个初值猜测」，不是「初始化方程必须满足的精确条件」。

`calculatedParameter` 在这里也不能被设置，它是由 FMU 计算出来的。

### 6.5.2 读取可能触发计算

在 `InitializationMode` 中调用 `fmi3Get{VariableType}` 是合法的，但读取可能触发 `f_init` 的计算。对于没有被 `f_init` 计算的变量，返回的是它的 `start` 值。

这正是「合法调用 ≠ 结果正确」的典型场景：你读到的值可能只是 XML 里的默认值，而不是初始化后的值。要判断一个变量是否已经计算，需要看它的 `initial` 属性和 `ModelStructure` 中的依赖关系，必要时通过迭代 `Get` / `Set` 让系统收敛。

### 6.5.3 初始化参数在三种接口中的含义

`toleranceDefined` / `tolerance` 的语义取决于接口：

| 参数 | ME | CS | SE |
| --- | --- | --- | --- |
| `toleranceDefined` / `tolerance` | 导入端积分器的误差估计；FMU 内部数值算法也应使用更小的相对误差 | 通信步长的误差估计建议；FMU 可以忽略 | SE 没有连续积分和通信步长，通常不参与调度 |
| `startTime` | 独立变量初值 | 同 ME | 同 ME |
| `stopTimeDefined` / `stopTime` | 终止时间；越界必须报错 | 同 ME | 同 ME |

SE 仍然使用同一个函数，所以参数形状一致；但 SE 的推进靠 Clock 激活模型分区，不存在「通信步长」这个概念，因此不要把 CS 的 tolerance 语义硬套到 SE 上。

### 6.5.4 `fmi3ExitInitializationMode` 是唯一分岔点

这是整章最重要的一个函数。它做四件事：

1. 如果之前没有触发过 `f_init`，现在计算一次。
2. 停用初始化方程 `f_init`。
3. 更新 `buffers` 的旧值：`b := b`，并把超密集时间设为 `(t_start, 0)`。
4. 根据接口类型和 CS 的 `eventModeUsed`，进入不同的状态。

Reference 实现把第 4 步写得很清楚：

```c
/* examples/reference-fmus/src/fmi3Functions.c */
fmi3Status fmi3ExitInitializationMode(fmi3Instance instance) {
    BEGIN_FUNCTION(ExitInitializationMode);

    if (S->isDirtyValues) {
        CALL(calculateValues(S));
        S->isDirtyValues = false;
    }

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

    CALL(configurate(S));

    END_FUNCTION();
}
```

对应到规范：

- **ME**：`fmi3ExitInitializationMode` → `EventMode`，并且激活事件方程 `f_event`。
- **CS，`eventModeUsed = true`**：→ `EventMode`，激活 `f_event`。
- **CS，`eventModeUsed = false`**：→ `StepMode`，激活 `f_doStep`。
- **SE**：→ `ClockActivationMode`。

因此，导入端在调用 `fmi3ExitInitializationMode` 之后，**不能假设自己一定在 `EventMode`**。CS 的两种分支会导致完全不同的后续调用。

### 6.5.5 退出初始化不等于「离散状态已经收敛」

对 ME 和 `eventModeUsed = true` 的 CS，`fmi3ExitInitializationMode` 只是把你送进 `EventMode`。此时还欠一次**初始事件迭代**：

```c
fmi3Boolean needUpdate = fmi3True;

while (needUpdate) {
    fmi3UpdateDiscreteStates(fmu, &needUpdate, ...);
}
```

规范要求 `fmi3UpdateDiscreteStates` 在每个超密集时间点至少调用一次。初始时刻就是一个超密集时间点，所以这次循环不能省。省掉的后果是：离散状态、输出、事件时间可能还是初始化前的值，后面的积分或步进从一开始就偏了。

CS 的 `eventModeUsed = false` 分支不需要这个循环，因为 FMU 在内部处理事件，`fmi3ExitInitializationMode` 直接进入 `StepMode`。

---

## 6.6 `Initialized` 与 `EventMode`

### 6.6.1 `Initialized` 是运行期超级状态

`Initialized` 不是靠某个函数「进入」的独立状态，而是从 `fmi3ExitInitializationMode` 到 `fmi3Terminate` 之间的超级状态。它的主体是四个运行模式：

- `EventMode`
- `ContinuousTimeMode`（ME）
- `StepMode`（CS）
- `ClockActivationMode`（SE）

规范把 `fmi3Terminate` 列在这个超级状态里，含义是：**只有初始化完成之后才能终止**。在 `Instantiated` 或 `InitializationMode` 里调用 `fmi3Terminate` 都是非法调用。

状态图把 `ReconfigurationMode`、`IntermediateUpdateMode`、`ClockUpdateMode` 画在 `Initialized` 边界之外。不要假设它们自动继承 `fmi3Terminate` 的许可：`ReconfigurationMode` 的允许调用列表只列了 `fmi3ExitConfigurationMode` 和 `fmi3Set{VariableType}`，稳妥做法是先退出重配置，再终止。

### 6.6.2 `EventMode` 做什么

`EventMode` 处理所有离散变化：

- 输入事件：输入值发生非连续变化。
- 时间事件：FMU 通过 `nextEventTime` 或 Clock 区间预告的时刻。
- 状态事件：ME 通过事件指示器过零检测；CS 由 FMU 在 `fmi3DoStep` 返回时用 `eventHandlingNeeded` 告知。
- 步事件：ME 在积分步结束时由 `fmi3CompletedIntegratorStep` 的 `enterEventMode` 告知。

在 `EventMode` 中：

- 可以设置 `tunable` 参数、输入、以及 `reinit="false"` 的连续状态。
- 可以读取输出和离散状态。
- 可以调用 `fmi3SetClock` 激活/停用 Clock。
- 可以调用 `fmi3EvaluateDiscreteStates`（如果 FMU 支持）和 `fmi3UpdateDiscreteStates`。
- 不能调用 `fmi3DoStep`，也不能调用 `fmi3EnterEventMode`（已经在里面了）。

SE 没有 `EventMode`。SE 的离散行为通过 Clock 和 `fmi3ActivateModelPartition` 表达，第 9 章会讲。

### 6.6.3 事件迭代：`fmi3UpdateDiscreteStates`

`fmi3UpdateDiscreteStates` 的签名是：

```c
fmi3Status fmi3UpdateDiscreteStates(
    fmi3Instance instance,
    fmi3Boolean* discreteStatesNeedUpdate,
    fmi3Boolean* terminateSimulation,
    fmi3Boolean* nominalsOfContinuousStatesChanged,
    fmi3Boolean* valuesOfContinuousStatesChanged,
    fmi3Boolean* nextEventTimeDefined,
    fmi3Float64* nextEventTime);
```

它的调用规则很简单，但很容易写错：

> 每个超密集时间点至少调用一次；如果返回 `discreteStatesNeedUpdate = fmi3True`，导入端必须留在 `EventMode`，开始新的超密集时间点，再调用一次。

标准循环：

```c
do {
    fmi3UpdateDiscreteStates(fmu,
        &discreteStatesNeedUpdate,
        &terminateSimulation,
        &nominalsChanged,
        &statesChanged,
        &nextEventTimeDefined,
        &nextEventTime);

    if (terminateSimulation) {
        goto TERMINATE;
    }
} while (discreteStatesNeedUpdate);
```

每次调用结束一个超密集时间点，`t_I` 加一：

```text
t = (t_R, 0)  ──UDS──▶  needUpdate = true   →  t = (t_R, 1)
              ──UDS──▶  needUpdate = true   →  t = (t_R, 2)
              ──UDS──▶  needUpdate = false  →  t = (t_R, 3)，离开 EventMode
```

输出标志的含义：

| 标志 | 含义 | 导入端动作 |
| --- | --- | --- |
| `discreteStatesNeedUpdate` | 还有离散状态没收敛 | 留在 `EventMode`，再调一次 |
| `terminateSimulation` | FMU 请求停止仿真 | 退出循环，调用 `fmi3Terminate` |
| `nominalsOfContinuousStatesChanged` | 连续状态的 nominal 值变了（仅 ME） | 调 `fmi3GetNominalsOfContinuousStates` |
| `valuesOfContinuousStatesChanged` | 连续状态因 `reinit` 改变了（仅 ME） | 调 `fmi3GetContinuousStates` |
| `nextEventTimeDefined` | 下一个时间事件已知 | 读取 `nextEventTime` |
| `nextEventTime` | 下一个时间事件的绝对时间 | 积分/步进到该时刻后进 `EventMode` |

`nominalsOfContinuousStatesChanged` 和 `valuesOfContinuousStatesChanged` 只在 ME 中有意义。CS 的 FMU 自己管理连续状态，导入端看不到这两个量。

### 6.6.4 `fmi3EvaluateDiscreteStates` 是可选的拆分

如果 XML 里 `providesEvaluateDiscreteStates="true"`，FMU 支持把离散状态更新拆成两步：

1. `fmi3EvaluateDiscreteStates` 计算 `f_disc`，得到新的离散状态。
2. `fmi3UpdateDiscreteStates` 在超密集时间点结束时计算 `f_event` 的剩余部分，并更新缓冲区。

如果 FMU 不支持，`fmi3EvaluateDiscreteStates` 在 `EventMode` 中会被忽略，所有工作由 `fmi3UpdateDiscreteStates` 完成。对导入端来说，**最稳妥的写法是只依赖 `fmi3UpdateDiscreteStates` 的循环**；只有在明确知道 FMU 支持、并且需要参与代数环求解时，才插入 `fmi3EvaluateDiscreteStates`。

### 6.6.5 Clock 的激活也发生在 `EventMode`

`fmi3SetClock` 用来设置输入 Clock 的激活状态。一个超密集时间点内可以调用多次，因为代数环迭代可能让某个 Clock 的激活条件反复变化。

规则要点：

- 只有 `canBeDeactivated="true"` 的 Clock 才能被导入端设为 `fmi3ClockInactive`。
- Clock 被停用时，FMU 必须把该 Clock 的 clocked 状态恢复到上一次该 Clock 处于激活状态时、`fmi3UpdateDiscreteStates` 所计算的值，并停用由它触发的下游 Clock。
- 周期 Clock 在一次 `EventMode` 中不能跨多个 `fmi3UpdateDiscreteStates` 保持激活。

Clock 的完整语义在第 9 章展开。这里只需要记住：**Clock 的激活/停用属于 `EventMode`，不属于 `InitializationMode` 或 `StepMode`。**

---

## 6.7 `ConfigurationMode` 与 `ReconfigurationMode`

这两个状态名字很像，用的也是同一对函数：

```c
fmi3Status fmi3EnterConfigurationMode(fmi3Instance instance);
fmi3Status fmi3ExitConfigurationMode(fmi3Instance instance);
```

但它们的目标不同，进入的源状态也不同。

| | `ConfigurationMode` | `ReconfigurationMode` |
| --- | --- | --- |
| 什么时候用 | 初始化前，设置结构参数 | 仿真运行中，改变可调结构参数 |
| 从哪个状态进 | `Instantiated` | `EventMode` / `StepMode` / `ClockActivationMode` |
| 允许设置的结构参数 | `variability="fixed"` 或 `"tunable"` | 只能是 `variability="tunable"` |
| 退出后回到 | `Instantiated` | ME：`EventMode`；CS：`StepMode`；SE：`ClockActivationMode` |
| 前提 | FMU 至少有一个 `structuralParameter` | FMU 至少有一个 `tunable` 的 `structuralParameter` |

**同一个 `fmi3EnterConfigurationMode` 会进入哪个状态，取决于当前状态。** Reference 实现就是这么写的：

```c
/* examples/reference-fmus/src/fmi3Functions.c */
fmi3Status fmi3EnterConfigurationMode(fmi3Instance instance) {
    BEGIN_FUNCTION(EnterConfigurationMode);
    S->state = (S->state == Instantiated) ? ConfigurationMode : ReconfigurationMode;
    END_FUNCTION();
}

fmi3Status fmi3ExitConfigurationMode(fmi3Instance instance) {
    BEGIN_FUNCTION(ExitConfigurationMode);

    if (S->state == ConfigurationMode) {
        S->state = Instantiated;
    } else {
        switch (S->type) {
            case ModelExchange:
                S->state = EventMode;
                break;
            case CoSimulation:
                S->state = StepMode;
                break;
            case ScheduledExecution:
                S->state = ClockActivationMode;
                break;
        }
    }

#if MAX_CONTINUOUS_STATES > 0 || MAX_EVENT_INDICATORS > 0
    CALL(configurate(S));
#endif

    END_FUNCTION();
}
```

注意 CS 的分支：即使你是从 `EventMode` 进入 `ReconfigurationMode`，退出后也回到 `StepMode`，不是 `EventMode`。如果还需要继续处理事件，要再调用 `fmi3EnterEventMode`。

### 6.7.1 为什么不能在 `InitializationMode` 里改结构参数

结构参数会影响数组维度，而数组维度会影响状态向量、事件指示器、输入/输出缓冲区的长度。如果在 `InitializationMode` 中途改变维度，初始化方程已经按旧维度算了一半，状态就不一致了。

规范因此把结构参数的变化限制在两个明确的时间窗：

- 初始化前：`Instantiated` → `ConfigurationMode` → `Instantiated`。
- 运行中：`EventMode` / `StepMode` / `ClockActivationMode` → `ReconfigurationMode` → ME 的 `EventMode`、CS 的 `StepMode` 或 SE 的 `ClockActivationMode`。

### 6.7.2 退出时重分配数组

`fmi3ExitConfigurationMode` 不只是改状态，它还负责按新的结构参数重分配数组。导入端也要同步更新自己的缓冲区。

Reference 的 CS 重配置示例在仿真中途把 `m`、`r` 从 2 改成 3：

```c
/* examples/reference-fmus/examples/cs_reconfiguration.c */
if (step == 5) {
    CALL(FMI3EnterConfigurationMode(S));

    vr[0] = vr_m; vr[1] = vr_r;
    p[0] = 3; p[1] = 3;

    CALL(FMI3SetUInt64(S, vr, 2, p, 2));

    CALL(FMI3ExitConfigurationMode(S));

    vr[0] = vr_D;

    /* 3x3 identity matrix */
    D[0] = 1; D[1] = 0; D[2] = 0;
    D[3] = 0; D[4] = 1; D[5] = 0;
    D[6] = 0; D[7] = 0; D[8] = 1;

    CALL(FMI3SetFloat64(S, vr, 1, D, 9));
}
```

示例里 `D`、`u` 用的是 `R_MAX * M_MAX` 的固定上限数组，所以不需要 `realloc`。真实导入端如果用动态数组，必须在 `fmi3ExitConfigurationMode` 之后重新分配。

对 ME 还有一个额外步骤：如果结构参数影响了连续状态或事件指示器的数量，退出后要调用：

```c
fmi3GetNumberOfContinuousStates(fmu, &nContinuousStates);
fmi3GetNumberOfEventIndicators(fmu, &nEventIndicators);
```

这两个函数只在 ME 中可用。数组维度没变时不必每次调用，规范允许直接从 XML 读取初始数量。

### 6.7.3 前提条件不是建议

- FMU 没有任何 `structuralParameter` 时，**不得**调用 `fmi3EnterConfigurationMode`。
- FMU 没有 `tunable` 的 `structuralParameter` 时，**不得**进入 `ReconfigurationMode`。
- 在 `ReconfigurationMode` 里设置 `fixed` 的结构参数是非法的，只能设 `tunable`。

这些是导入端必须遵守的前置条件。违反时，FMU 应返回 `fmi3Error`，而不是「尽力而为」。

Reference 的状态掩码把 `ReconfigurationMode` 也列进了 `fmi3Terminate` 的允许状态，但规范的 `ReconfigurationMode` 允许调用列表没有列 `fmi3Terminate`。这类冲突以规范为准；实现里更宽松的掩码可能只是为了让示例程序少写几步。

---

## 6.8 `Terminated`、`fmi3Reset` 与 `fmi3FreeInstance`

### 6.8.1 `Terminated`：只读的终点

`Terminated` 状态下可以读取最终值：

- `fmi3Get{VariableType}`：读取变量最终值，可能触发计算。
- `fmi3GetContinuousStateDerivatives`：仅 ME。
- `fmi3GetContinuousStates`：仅 ME。
- `fmi3GetNominalsOfContinuousStates`：仅 ME。
- `fmi3GetEventIndicators`：仅 ME。
- `fmi3GetDirectionalDerivative` / `fmi3GetAdjointDerivative`：按各自函数的说明。
- `fmi3GetOutputDerivatives`：CS 可用，ME/SE 不可用。

规范在 `Terminated` 的允许调用列表里**没有** `fmi3Set{VariableType}`。所以不要再改参数、输入或状态。Reference 实现的状态掩码把 `Terminated` 也放进了 `SetFloat64` 等函数的允许集合，这是实现比规范宽松；以规范为准。

如果 `Terminated` 是因为某个函数返回 `fmi3Error` 而进入的，读取到的值只适合调试，不能当作可信结果。

### 6.8.2 `fmi3Terminate` 只负责进入终止态

`fmi3Terminate` 激活终止方程 `f_term`，把状态切换到 `Terminated`。它**不释放内存**，也不卸载二进制。释放是 `fmi3FreeInstance` 的职责。

什么时候调用 `fmi3Terminate`？

- 仿真正常到达 `stopTime`。
- FMU 通过 `terminateSimulation = fmi3True` 请求停止（来自 `fmi3UpdateDiscreteStates` 或 `fmi3DoStep`）。
- 导入端决定提前结束，但还没有遇到 `fmi3Fatal`。

不要在 `Instantiated` 或 `InitializationMode` 里调用它。规范把 `fmi3Terminate` 放在 `Initialized` 超级状态，前提是初始化已经完成。

### 6.8.3 `fmi3Reset`：同一实例的第二次运行

`fmi3Reset` 把 FMU 恢复到「刚刚实例化」的状态：

- 状态回到 `Instantiated`。
- 所有变量回到默认值（通常是 XML 里的 `start`）。
- 时间、步数等内部计数清零。
- 不需要重新调用 `fmi3Instantiate*`，实例指针继续有效。

Reference 实现的 `reset` 很直白：

```c
/* examples/reference-fmus/src/common.c */
Status reset(ModelInstance* comp) {
    comp->state = Instantiated;
    comp->startTime = 0.0;
    comp->time = 0.0;
    comp->nSteps = 0;
    comp->status = OK;
    setStartValues(comp);
    comp->isDirtyValues = true;

    return OK;
}
```

重置之后，**必须重新调用 `fmi3EnterInitializationMode`** 才能开始新的一轮仿真。`fmi3Reset` 不会自动进入初始化，也不会重新执行实例化回调。

典型用法：

```c
fmi3Terminate(fmu);          /* 第一次运行结束，进入 Terminated */
fmi3Reset(fmu);              /* 回到 Instantiated */
fmi3EnterInitializationMode(fmu, ...);
fmi3ExitInitializationMode(fmu);
/* 第二次运行 */
```

如果只是想换一组初值再跑一遍，`Reset + 重新初始化` 通常比 `FreeInstance + Instantiate` 便宜；但如果要换 `instantiationToken`、资源目录或接口类型，就必须重新实例化。

### 6.8.4 `fmi3FreeInstance`：最后一步

`fmi3FreeInstance` 释放实例、卸载模型、释放 FMU 分配的所有内存和资源。它的签名是 `void`，没有状态返回值；如果传入 `NULL`，调用被忽略。

它可以在任何有效实例状态下调用，不要求先 `fmi3Terminate`。但正常流程建议先 `Terminate`，让 FMU 有机会计算终止方程、写日志或保存最终状态。

Reference 的 `tearDown` 把终止和释放分开处理（下面省略了 FMI 1.0/2.0 的条件编译）：

```c
/* examples/reference-fmus/examples/util.h */
if (S) {
    if (status < FMIError) {
        FMIStatus terminateStatus = FMI3Terminate(S);
        if (terminateStatus > status) {
            status = terminateStatus;
        }
    }

    if (status < FMIFatal) {
        FMI3FreeInstance(S);
    }

    FMIFreeInstance(S);
    S = NULL;
}
```

这段代码有两个值得注意的细节：

1. **`fmi3Fatal` 时不调用 `fmi3FreeInstance`。** 规范要求 `fmi3Fatal` 后不再调用该 FMU 的任何函数，因为所有实例的状态都已不可恢复。`FMIFreeInstance(S)` 释放的是导入端自己的包装对象，不是 FMU 实例。
2. **`fmi3Error` 时仍然调用 `fmi3FreeInstance`。** 错误后状态进入 `Terminated`，可以释放；但不会再调用 `fmi3Terminate`，因为 `status < FMIError` 不成立。

### 6.8.5 状态返回值怎么处理

把 2.2 节的状态定义压缩成一张表：

| 返回 | 含义 | 状态影响 | 导入端动作 |
| --- | --- | --- | --- |
| `NULL`（仅实例化） | 实例化失败 | 没有实例 | 读日志，修正 token/资源/平台；无需释放（`fmi3FreeInstance(NULL)` 会被忽略） |
| `fmi3OK` | 成功 | 按函数定义迁移 | 继续 |
| `fmi3Warning` | 成功，但有非致命问题 | 按函数定义迁移 | 记录日志；生产环境建议按错误处理，除非确认可忽略 |
| `fmi3Discard` | 调用未成功，FMU 状态未变 | 不变 | 换参数/更小步长重试；否则按 `fmi3Error` 终止。SE 中禁止重复失败调用 |
| `fmi3Error` | 调用失败，仿真不能继续 | 进入 `Terminated` | 可用 `fmi3SetFMUState` 恢复或 `fmi3Reset` 重来；否则终止并释放 |
| `fmi3Fatal` | 所有实例不可恢复 | 未定义 | 不再调用任何 FMI 函数，只释放导入端自己的资源 |

`fmi3Discard` 和 `fmi3Error` 的区别很重要：前者是「这次没算成，但状态没坏，可以换个方式再试」，后者是「这次失败，仿真不能继续」。不要把所有非 `fmi3OK` 都当成同一种错误。

---

## 6.9 三条主路径

下面把第 7–9 章会展开的调用序列先压缩成骨架。注意每条路径的**分岔点都在 `fmi3ExitInitializationMode`**。

### 6.9.1 Model Exchange

```c
fmu = fmi3InstantiateModelExchange(...);       /* Instantiated */

fmi3EnterInitializationMode(fmu, ...);         /* InitializationMode */
/* 设置 initial="exact" 的变量和输入 */
fmi3ExitInitializationMode(fmu);               /* EventMode */

do {
    fmi3UpdateDiscreteStates(fmu, &needUpdate, ...);
} while (needUpdate);                          /* EventMode：初始事件迭代 */

fmi3EnterContinuousTimeMode(fmu);              /* ContinuousTimeMode */
/* 积分：GetContinuousStateDerivatives / SetTime / SetContinuousStates */
/* 检测事件指示器过零 */

if (eventOccurred) {
    fmi3EnterEventMode(fmu);                   /* EventMode */
    do {
        fmi3UpdateDiscreteStates(fmu, &needUpdate, ...);
    } while (needUpdate);
    fmi3EnterContinuousTimeMode(fmu);          /* ContinuousTimeMode */
}

fmi3Terminate(fmu);                            /* Terminated */
fmi3FreeInstance(fmu);                         /* freed */
```

ME 的事件检测由导入端完成：读事件指示器、比较前后符号、决定是否进 `EventMode`。第 7 章会逐行讲 `simulate_fmi3_me.c`。

### 6.9.2 Co-Simulation，开启事件模式

```c
fmu = fmi3InstantiateCoSimulation(..., fmi3True /* eventModeUsed */, ...);
                                               /* Instantiated */

fmi3EnterInitializationMode(fmu, ...);         /* InitializationMode */
fmi3ExitInitializationMode(fmu);               /* EventMode（不是 StepMode！） */

do {
    fmi3UpdateDiscreteStates(fmu, &needUpdate, ...);
} while (needUpdate);                          /* 初始事件迭代 */

fmi3EnterStepMode(fmu);                        /* StepMode */

while (/* 未到 stopTime */) {
    fmi3DoStep(fmu, time, stepSize, ..., &eventEncountered, ...);
                                               /* StepMode */
    if (eventEncountered) {
        fmi3EnterEventMode(fmu);               /* EventMode */
        do {
            fmi3UpdateDiscreteStates(fmu, &needUpdate, ...);
        } while (needUpdate);
        fmi3EnterStepMode(fmu);                /* StepMode */
    }
}

fmi3Terminate(fmu);                            /* Terminated */
fmi3FreeInstance(fmu);
```

**最常见的错误**：`fmi3ExitInitializationMode` 之后直接 `fmi3DoStep`。此时还在 `EventMode`，必须先做初始事件迭代，再 `fmi3EnterStepMode`。

### 6.9.3 Co-Simulation，关闭事件模式

```c
fmu = fmi3InstantiateCoSimulation(..., fmi3False /* eventModeUsed */, ...);
                                               /* Instantiated */

fmi3EnterInitializationMode(fmu, ...);         /* InitializationMode */
fmi3ExitInitializationMode(fmu);               /* StepMode */

while (/* 未到 stopTime */) {
    fmi3DoStep(fmu, time, stepSize, ..., &eventEncountered, ...);
                                               /* StepMode */
    /* eventEncountered 必须为 false；事件由 FMU 内部处理 */
}

fmi3Terminate(fmu);                            /* Terminated */
fmi3FreeInstance(fmu);
```

这种模式下没有 `EventMode`，也不能调用 `fmi3EnterEventMode`。规范明确规定：`eventModeUsed = fmi3False` 时，`fmi3DoStep` 不得返回 `eventHandlingNeeded = fmi3True`。

### 6.9.4 Scheduled Execution

```c
fmu = fmi3InstantiateScheduledExecution(...);  /* Instantiated */

fmi3EnterInitializationMode(fmu, ...);         /* InitializationMode */
fmi3ExitInitializationMode(fmu);               /* ClockActivationMode */

while (/* 调度未结束 */) {
    fmi3ActivateModelPartition(fmu, clockReference, activationTime);
                                               /* ClockActivationMode */
}

fmi3Terminate(fmu);                            /* Terminated */
fmi3FreeInstance(fmu);
```

SE 没有 `EventMode`，也没有 `fmi3DoStep`。推进完全由 Clock 和 `fmi3ActivateModelPartition` 驱动。第 9 章会讲 Clock 的类型、优先级和激活规则。

### 6.9.5 三条路径对照

| | ME | CS（`eventModeUsed=true`） | CS（`eventModeUsed=false`） | SE |
| --- | --- | --- | --- | --- |
| `ExitInitializationMode` 后 | `EventMode` | `EventMode` | `StepMode` | `ClockActivationMode` |
| 初始事件迭代 | 必须 | 必须 | 不需要 | 不需要 |
| 推进方式 | 积分器 + `SetTime` / `SetContinuousStates` | `fmi3DoStep` | `fmi3DoStep` | `fmi3ActivateModelPartition` |
| 事件检测 | 导入端读事件指示器 | FMU 返回 `eventHandlingNeeded` | FMU 内部处理 | Clock 调度 |
| `EventMode` | 有 | 有 | 无 | 无 |
| 终止 | `fmi3Terminate` | `fmi3Terminate` | `fmi3Terminate` | `fmi3Terminate` |
| 释放 | `fmi3FreeInstance` | `fmi3FreeInstance` | `fmi3FreeInstance` | `fmi3FreeInstance` |

---

## 6.10 审计一个导入端的调用序列

读别人的导入端代码时，可以按下面这份清单逐项检查。它也是你自己写导入端时的自检表。

1. **实例化返回值检查了吗？** `NULL` 不能传给后续函数，也不能 `FreeInstance`。
2. **每个 FMI 调用的 `fmi3Status` 都检查了吗？** 特别是 `fmi3Error` 和 `fmi3Fatal` 要分开处理。
3. **接口选对了吗？** `fmi3Instantiate*` 必须与 XML 中存在的 `<ModelExchange>` / `<CoSimulation>` / `<ScheduledExecution>` 对应。
4. **`eventModeUsed` 与 `hasEventMode` 一致吗？** 有 Clock 的 CS FMU 必须用 `fmi3True`；`hasEventMode="false"` 时不能传 `fmi3True`。
5. **`fmi3ExitInitializationMode` 后有没有按分支处理？** CS 的 `eventModeUsed=false` 直接进 `StepMode`，不能等 `EventMode`。
6. **ME 和 CS-event 做初始事件迭代了吗？** 在第一次积分/步进之前，`fmi3UpdateDiscreteStates` 至少调用一次。
7. **事件循环的进出函数配对了吗？** ME 用 `EnterContinuousTimeMode` 离开 `EventMode`；CS 用 `EnterStepMode`。不要调不存在的 `ExitEventMode`。
8. **重配置后数组更新了吗？** 退出 `ConfigurationMode` / `ReconfigurationMode` 后重新分配缓冲区；ME 还要更新状态数和事件指示器数。
9. **`fmi3Terminate` 的时机对吗？** 只在初始化完成之后；终止后只读，不再 `Set`。
10. **`fmi3FreeInstance` 只调一次吗？** 释放后句柄失效；第二次运行用 `fmi3Reset`，不是重复 `FreeInstance`。

---

## 动手实验

以下命令都在仓库根目录执行，使用 Windows PowerShell。

### 实验 6-1：从 XML 读出影响状态机的标志

先列出每个 Reference FMU 支持哪些接口，以及两个关键能力标志：

```powershell
function Get-Flag($node, $name, $default) {
    if ($null -eq $node) { return 'n/a' }
    $value = $node.GetAttribute($name)
    if ([string]::IsNullOrEmpty($value)) { $value = $default }
    $value
}

Get-ChildItem .\examples\reference-fmus -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'FMI3.xml') } |
    ForEach-Object {
        $xml = [xml](Get-Content (Join-Path $_.FullName 'FMI3.xml') -Raw -Encoding UTF8)
        $me  = $xml.fmiModelDescription.ModelExchange
        $cs  = $xml.fmiModelDescription.CoSimulation
        $se  = $xml.fmiModelDescription.ScheduledExecution
        $iface = if ($me) { $me } elseif ($cs) { $cs } else { $se }
        [pscustomobject]@{
            Model          = $_.Name
            ME             = [bool]$me
            CS             = [bool]$cs
            SE             = [bool]$se
            hasEventMode   = $(Get-Flag $cs 'hasEventMode' 'false')
            oncePerProcess = $(Get-Flag $iface 'canBeInstantiatedOnlyOncePerProcess' 'false')
        }
    } | Format-Table -AutoSize
```

输出应当类似：

```text
Model           ME    CS    SE hasEventMode oncePerProcess
-----           --    --    -- ------------ --------------
BouncingBall  True  True False true         false
Clocks       False False  True n/a          false
Dahlquist     True  True False false        false
Feedthrough   True  True False true         false
Resource      True  True False false        false
Roberts       True  True False true         false
Stair         True  True False true         false
StateSpace    True  True False true         false
VanDerPol     True  True False false        false
```

回答：

1. 哪些模型可以作为 CS 且支持 `EventMode`？
2. 哪个模型只能作为 SE 运行？
3. 哪些 CS 模型必须用 `eventModeUsed = fmi3False` 实例化？
4. 这些模型里有没有「一个进程只能实例化一次」的？

<details>
<summary>答案</summary>

1. `BouncingBall`、`Feedthrough`、`Roberts`、`Stair`、`StateSpace`：它们的 `<CoSimulation>` 有 `hasEventMode="true"`。
2. `Clocks`：只有 `<ScheduledExecution>`，没有 ME/CS 元素。
3. `Dahlquist`、`Resource`、`VanDerPol`：`hasEventMode` 缺失，默认 `false`，因此只能 `eventModeUsed = fmi3False`。
4. 没有。`canBeInstantiatedOnlyOncePerProcess` 缺失时默认 `false`，所以这些模型都允许在同一进程中创建多个实例。

</details>

### 实验 6-2：抽取三条调用序列

用同一条 PowerShell 命令，从三个导入端示例中抽取 FMI 调用顺序：

```powershell
Select-String -Path .\examples\reference-fmus\examples\simulate_fmi3_me.c `
             -Pattern 'FMI3[A-Za-z0-9_]+\(' -AllMatches |
    ForEach-Object {
        '{0,4}: {1}' -f $_.LineNumber, (($_.Matches.Value -replace '\($','') -join ', ')
    }
```

把路径换成下面三个文件，各跑一次：

- `examples/reference-fmus/examples/simulate_fmi3_me.c`
- `examples/reference-fmus/examples/simulate_fmi3_cs.c`
- `examples/reference-fmus/examples/scs_synchronous.c`

然后回答：

1. ME 的序列里，`fmi3EnterContinuousTimeMode` 出现在哪些位置？它前后的状态分别是什么？
2. CS 的无事件模式序列里，为什么没有 `fmi3UpdateDiscreteStates`？
3. SE 的序列里为什么没有 `fmi3DoStep`？
4. 三个示例的 `fmi3Terminate` / `fmi3FreeInstance` 在哪里？为什么命令输出里看不到？

<details>
<summary>答案</summary>

1. `simulate_fmi3_me.c` 中第一次出现在第 84 行：`ExitInitializationMode`（进入 `EventMode`）→ 初始 `UpdateDiscreteStates` 循环 → `EnterContinuousTimeMode`（进入 `ContinuousTimeMode`）。第二次出现在第 147 行：`EnterEventMode` → 事件迭代 → `EnterContinuousTimeMode`。
2. `simulate_fmi3_cs.c` 用 `eventModeUsed = fmi3False` 实例化，`ExitInitializationMode` 直接进入 `StepMode`，事件由 FMU 内部处理，所以没有 `UpdateDiscreteStates`。
3. `scs_synchronous.c` 是 SE，推进靠 `fmi3ActivateModelPartition`，没有通信步，也没有 `fmi3DoStep`。
4. 它们藏在 `util.h` 的 `tearDown()` 里，示例主程序通过 `return tearDown();` 统一收尾。`tearDown` 在正常状态下调用 `fmi3Terminate`，然后调用 `fmi3FreeInstance`。

</details>

### 实验 6-3：对照规范读 Reference 的状态掩码

Reference 实现把每个函数允许的状态写成了宏。先看与生命周期最相关的几行：

```powershell
Select-String -Path .\examples\reference-fmus\src\fmi3Functions.c `
             -Pattern '^#define MASK_fmi3(Enter|Exit|Terminate|Reset|Free)' |
    ForEach-Object { $_.LineNumber.ToString() + ': ' + $_.Line.Trim() }
```

关键输出：

```text
107: #define MASK_fmi3EnterInitializationMode  Instantiated
108: #define MASK_fmi3ExitInitializationMode   InitializationMode
109: #define MASK_fmi3EnterEventMode           (ContinuousTimeMode | StepMode)
110: #define MASK_fmi3Terminate                (ContinuousTimeMode | StepMode | StepDiscarded | EventMode | ClockActivationMode | ReconfigurationMode)
111: #define MASK_fmi3Reset                    MASK_AnyState
163: #define MASK_fmi3EnterConfigurationMode   (Instantiated | StepMode | EventMode | ClockActivationMode)
164: #define MASK_fmi3ExitConfigurationMode    (ConfigurationMode | ReconfigurationMode)
```

`StepDiscarded` 是 Reference 内部的辅助状态，不在规范 2.3 的公共状态列表里；看到它时不用去规范里找对应章节。

再查两个变量读写函数的掩码：

```powershell
Select-String -Path .\examples\reference-fmus\src\fmi3Functions.c `
             -Pattern '^#define MASK_fmi3(SetFloat32|GetFloat32|GetNumberOfContinuousStates|EnterStepMode)' |
    ForEach-Object { $_.LineNumber.ToString() + ': ' + $_.Line.Trim() }
```

`MASK_fmi3SetFloat64` 和 `MASK_fmi3GetFloat64` 只是分别别名到 `SetFloat32` / `GetFloat32`，所以看 32 位版本的掩码即可。

找出至少三处「Reference 比规范宽松」或「Reference 还没写完」的地方，并说明规范原文是什么。

<details>
<summary>答案</summary>

常见的三处：

1. **`SetFloat64` 包含 `Terminated`。** 规范 `Terminated` 状态的允许调用里只有 `fmi3Get{VariableType}` 和各 Get 类函数，没有 `fmi3Set{VariableType}`。Reference 把 `Terminated` 放进 Set 的掩码，属于实现更宽松。
2. **`EnterStepMode` 包含 `InitializationMode`。** 规范 2.3 对 `fmi3EnterStepMode` 的说明是「从 `EventMode` 进入 `StepMode`」，并没有说可以从 `InitializationMode` 调。Reference 多放了一个状态。
3. **`GetNumberOfContinuousStates` 是 `MASK_AnyState`。** 规范明确说这个函数只能在 Model Exchange 中调用；如果对 CS/SE 实例调用，应该报错，而不是任何状态都放行。
4. **Clock 相关掩码带 `TODO`。** 源码里 `GetInterval` / `SetInterval` 等直接写了 `MASK_AnyState`，这是实现尚未细化，不代表规范允许。

结论：Reference FMUs 是很好的教学实现和测试平台，但**不是合规性认证工具**。出现冲突时，以规范的状态表和允许调用列表为准。

</details>

### 实验 6-4：给 ME 调用序列标注状态

打开 `examples/reference-fmus/examples/simulate_fmi3_me.c`，把下面这些行号对应的调用填进「调用前状态 → 调用后状态」表：

| 行号 | 调用 | 调用前状态 | 调用后状态 |
| --- | --- | --- | --- |
| 46 | `FMI3InstantiateModelExchange` | ? | ? |
| 61 | `FMI3EnterInitializationMode` | ? | ? |
| 66 | `FMI3ExitInitializationMode` | ? | ? |
| 71 | `FMI3UpdateDiscreteStates` | ? | ? |
| 84 | `FMI3EnterContinuousTimeMode` | ? | ? |
| 114 | `FMI3EnterEventMode` | ? | ? |
| 133 | `FMI3UpdateDiscreteStates` | ? | ? |
| 147 | `FMI3EnterContinuousTimeMode` | ? | ? |
| 219 | `FMI3CompletedIntegratorStep` | ? | ? |

<details>
<summary>答案</summary>

| 行号 | 调用 | 调用前状态 | 调用后状态 |
| --- | --- | --- | --- |
| 46 | `FMI3InstantiateModelExchange` | （无） | `Instantiated` |
| 61 | `FMI3EnterInitializationMode` | `Instantiated` | `InitializationMode` |
| 66 | `FMI3ExitInitializationMode` | `InitializationMode` | `EventMode` |
| 71 | `FMI3UpdateDiscreteStates` | `EventMode` | `EventMode`（可能继续迭代） |
| 84 | `FMI3EnterContinuousTimeMode` | `EventMode` | `ContinuousTimeMode` |
| 114 | `FMI3EnterEventMode` | `ContinuousTimeMode` | `EventMode` |
| 133 | `FMI3UpdateDiscreteStates` | `EventMode` | `EventMode` |
| 147 | `FMI3EnterContinuousTimeMode` | `EventMode` | `ContinuousTimeMode` |
| 219 | `FMI3CompletedIntegratorStep` | `ContinuousTimeMode` | `ContinuousTimeMode`（可能通过 `enterEventMode` 请求进事件） |

注意第 71 行和第 133 行都在 `EventMode` 内循环；`fmi3UpdateDiscreteStates` 不改变状态名，但会推进超密集时间点。

</details>

---

## 6.11 小结

- 状态机规定「什么状态能调用什么函数」；FMU 遇到非法调用必须返回 `fmi3Error`，不是「尽力运行」。
- 公共部分有 6 个状态和 2 个超级状态：`Instantiated`、`InitializationMode`、`EventMode`、`ConfigurationMode`、`ReconfigurationMode`、`Terminated`，以及 `FMUStateSettable`、`Initialized`。
- `FMU State Settable` 覆盖从成功实例化到 `fmi3FreeInstance` 的整个生命周期；其中的 `fmi3Error` 会把 FMU 送进 `Terminated`，`fmi3Fatal` 后不能再调用任何 FMI 函数。
- `fmi3Instantiate*` 返回指针，失败返回 `NULL`；绝大多数函数返回 `fmi3Status`，`fmi3FreeInstance` 返回 `void`。
- `fmi3ExitInitializationMode` 是唯一分岔点：ME → `EventMode`；CS 看 `eventModeUsed` → `EventMode` 或 `StepMode`；SE → `ClockActivationMode`。
- ME 和 CS-event 在 `ExitInitializationMode` 之后必须做初始事件迭代：`fmi3UpdateDiscreteStates` 至少调用一次，直到 `discreteStatesNeedUpdate = fmi3False`。
- `fmi3UpdateDiscreteStates` 的每个输出标志都有明确用途；`nextEventTime` 是导入端安排下一次时间事件的依据。
- `ConfigurationMode` 用于初始化前设置 `fixed`/`tunable` 结构参数，退出回到 `Instantiated`；`ReconfigurationMode` 用于运行中设置 `tunable` 结构参数，退出回到 ME 的 `EventMode`、CS 的 `StepMode` 或 SE 的 `ClockActivationMode`。
- `Terminated` 只读；`fmi3Terminate` 不释放内存，`fmi3FreeInstance` 才释放；`fmi3Reset` 回到 `Instantiated`，第二次运行要重新初始化。
- Reference FMUs 的状态掩码是学习工具，不是规范本身；遇到冲突以规范为准。

---

## 习题

### 1. 找出第一个非法调用

下面每个序列都从成功实例化开始。指出**第一个**违反状态机或前置条件的调用，并给出修正方案。

1. `fmi3SetFloat64` → `fmi3ExitInitializationMode`
2. `fmi3EnterInitializationMode` → `fmi3Terminate`
3. ME：`fmi3EnterInitializationMode` → `fmi3ExitInitializationMode` → `fmi3GetContinuousStateDerivatives`
4. CS（`eventModeUsed = fmi3False`）：`fmi3ExitInitializationMode` → `fmi3EnterEventMode`
5. ME（或 `eventModeUsed = true` 的 CS）：`fmi3EnterInitializationMode` → `fmi3ExitInitializationMode` → `fmi3UpdateDiscreteStates` → `fmi3EnterEventMode`
6. 一个没有任何 `structuralParameter` 的 FMU：`fmi3EnterConfigurationMode`

<details>
<summary>答案</summary>

1. 第一个非法调用是 `fmi3ExitInitializationMode`：它只能从 `InitializationMode` 调用。修正：在它之前调用 `fmi3EnterInitializationMode`。
2. `fmi3Terminate` 只能从 `Initialized` 超级状态调用，不能在 `InitializationMode` 中调用。修正：先 `fmi3ExitInitializationMode`。
3. 三个调用本身都合法：`InitializationMode` → `EventMode` 后，`fmi3GetContinuousStateDerivatives` 在 `EventMode` 中允许。但这里缺少初始事件迭代：`fmi3UpdateDiscreteStates` 必须在每个超密集时间点至少调用一次。严格说不是「非法调用」，而是「漏掉了必须的调用」。
4. `fmi3EnterEventMode` 在状态上是从 `StepMode` 进入 `EventMode` 的合法迁移，但 `eventModeUsed = fmi3False` 时规范明确禁止调用它。FMU 应返回 `fmi3Error`。修正：不要调用，事件由 FMU 内部处理。
5. 最后一个 `fmi3EnterEventMode` 非法：此时已经在 `EventMode`（`ExitInitializationMode` 后进入，`UpdateDiscreteStates` 不改变状态名）。`fmi3EnterEventMode` 只能从 `ContinuousTimeMode`（ME）或 `StepMode`（CS）调用。修正：删掉它，直接做事件迭代。
6. `fmi3EnterConfigurationMode` 的前置条件是 FMU 至少有一个 `structuralParameter`；没有时不得调用。修正：跳过配置模式，直接 `fmi3EnterInitializationMode`。

</details>

### 2. 事件迭代要调几次

某 ME 模型在初始时刻的 `fmi3UpdateDiscreteStates` 依次返回：

```text
第 1 次：discreteStatesNeedUpdate = true
第 2 次：discreteStatesNeedUpdate = true
第 3 次：discreteStatesNeedUpdate = false
```

1. 导入端一共要调用几次 `fmi3UpdateDiscreteStates`？
2. 超密集时间点 `t_I` 从几开始，到几结束？
3. 第 3 次返回后，下一步应该调用什么函数才能进入积分？

<details>
<summary>答案</summary>

1. 3 次。只要返回 `true` 就必须留在 `EventMode` 再调一次，直到返回 `false`。
2. 从 `(t_start, 0)` 开始；三次调用分别发生在 `t_I = 0、1、2`，第 3 次返回 `false` 后 `t_I` 已经递增到 3。
3. 调用 `fmi3EnterContinuousTimeMode`（ME）。如果是 CS-event，则调用 `fmi3EnterStepMode`。

</details>

### 3. 配置模式还是重配置模式

填写下表，并指出哪些操作是非法的：

| 操作 | 应进入的状态 | 退出后回到 |
| --- | --- | --- |
| 初始化前把数组维度从 2 改成 3 | ? | ? |
| CS 运行中把 `tunable` 的结构参数从 2 改成 3 | ? | ? |
| ME 运行中把 `fixed` 的结构参数从 2 改成 3 | ? | ? |
| SE 运行中修改 `tunable` 结构参数 | ? | ? |
| 初始化前只修改普通 `parameter` | ? | ? |

<details>
<summary>答案</summary>

| 操作 | 应进入的状态 | 退出后回到 |
| --- | --- | --- |
| 初始化前把数组维度从 2 改成 3 | `ConfigurationMode` | `Instantiated` |
| CS 运行中把 `tunable` 的结构参数从 2 改成 3 | `ReconfigurationMode` | `StepMode` |
| ME 运行中把 `fixed` 的结构参数从 2 改成 3 | 非法，不能进入重配置 | — |
| SE 运行中修改 `tunable` 结构参数 | `ReconfigurationMode` | `ClockActivationMode` |
| 初始化前只修改普通 `parameter` | 不需要配置模式 | `Instantiated`（直接 Set 即可） |

普通 `parameter` 不是 `structuralParameter`，不会改变数组维度，直接在 `Instantiated` 或 `InitializationMode` 中设置即可。

</details>

### 4. `Reset`、`Free` 还是重新实例化

为下面的需求选择最合适的做法，并说明理由：

1. 同一个 FMU，换一组初值再跑一遍。
2. 换一个 `instantiationToken` 不同的 FMU 文件。
3. 仿真结束，程序要退出。
4. 某个函数返回 `fmi3Error`，想从上一个保存点继续。
5. 某个函数返回 `fmi3Fatal`。
6. 想同时运行同一个 FMU 的两个独立实例。

<details>
<summary>答案</summary>

1. `fmi3Reset` + 重新 `fmi3EnterInitializationMode`。实例和资源都还在，比重建便宜。
2. `fmi3FreeInstance` 后重新 `fmi3Instantiate*`。token、资源目录、二进制都可能变了，不能靠 Reset。
3. `fmi3Terminate`（如果还没终止）→ `fmi3FreeInstance`；如果已经 `fmi3Fatal`，不要再调用 FMI 函数。
4. 如果之前用 `fmi3GetFMUState` 保存过状态，调用 `fmi3SetFMUState` 恢复；否则 `fmi3Reset` 回到初始状态，再重新初始化。
5. 不再调用任何 FMI 函数，只释放导入端自己的资源；规范规定 `fmi3Fatal` 后所有实例状态不可恢复。
6. 可以，除非 XML 的 `canBeInstantiatedOnlyOncePerProcess="true"`。默认允许一个进程内多个实例，每个实例有独立的 `fmi3Instance` 和 `instanceName`。

</details>

### 5. 从能力标志推断合法调用

某 CS FMU 的 XML 是：

```xml
<CoSimulation
    modelIdentifier="Plant"
    hasEventMode="false"
    canGetAndSetFMUState="false"
    canBeInstantiatedOnlyOncePerProcess="true"/>
```

判断下列操作是否合法，并说明依据：

1. `fmi3InstantiateCoSimulation(..., eventModeUsed = fmi3True, ...)`
2. `fmi3InstantiateCoSimulation(..., eventModeUsed = fmi3False, ...)`
3. `fmi3DoStep` 返回 `eventHandlingNeeded = fmi3True` 后调用 `fmi3EnterEventMode`
4. 在同一进程中创建第二个 CS 实例
5. 调用 `fmi3GetFMUState`
6. 调用 `fmi3SetDebugLogging`

<details>
<summary>答案</summary>

1. 非法。`hasEventMode="false"` 时不能传 `eventModeUsed=fmi3True`，FMU 必须报错。
2. 合法。导入端声明不支持事件模式，事件由 FMU 内部处理。
3. 非法。`eventModeUsed=fmi3False` 时，`fmi3DoStep` 不得返回 `eventHandlingNeeded=fmi3True`；如果返回了，FMU 实现有问题。导入端也不应调用 `fmi3EnterEventMode`。
4. 非法。`canBeInstantiatedOnlyOncePerProcess="true"` 表示一个进程只能实例化一次。
5. 非法（或至少不受支持）。`canGetAndSetFMUState="false"` 表示 `fmi3GetFMUState` / `fmi3SetFMUState` / `fmi3FreeFMUState` 不受支持。
6. 合法。`fmi3SetDebugLogging` 是日志控制函数，不属于状态保存/恢复能力。

</details>

### 6. 判断题

1. `fmi3FreeInstance` 只能在 `Terminated` 状态调用。
2. `fmi3Terminate` 可以在 `InitializationMode` 中调用。
3. `fmi3Reset` 会重新执行 `fmi3Instantiate*` 的参数检查。
4. CS 的 `eventModeUsed = fmi3False` 时，FMU 在内部处理事件，导入端看不到 `EventMode`。
5. `fmi3ExitInitializationMode` 可以连续调用两次。
6. 初始化前可以通过 `ConfigurationMode` 改变数组维度。
7. 有 Clock 的 CS FMU 可以用 `eventModeUsed = fmi3False` 实例化。
8. `fmi3Get{VariableType}` 在 `Terminated` 中是允许的。
9. 在 `EventMode` 中，即使没有离散状态，也可以完全不调用 `fmi3UpdateDiscreteStates`。
10. `fmi3EnterConfigurationMode` 从 `EventMode` 进入的是 `ConfigurationMode`。

<details>
<summary>答案</summary>

1. 错。`fmi3FreeInstance` 可以在任何有效实例状态调用，`NULL` 会被忽略。
2. 错。`fmi3Terminate` 属于 `Initialized` 超级状态，必须初始化完成之后。
3. 错。`fmi3Reset` 复用现有实例，回到 `Instantiated`，不会重新执行实例化参数检查，也不会重新加载二进制。
4. 对。事件由 FMU 内部处理，导入端不进入 `EventMode`，`eventHandlingNeeded` 也不得为 `true`。
5. 错。第一次调用后状态已经离开 `InitializationMode`，第二次会因非法状态返回 `fmi3Error`。
6. 对。`ConfigurationMode` 就是为此设计的，前提是 FMU 有 `structuralParameter`。
7. 错。FMU 有 Clock 时，`eventModeUsed` 必须为 `fmi3True`。
8. 对。`Terminated` 允许读取最终值，但规范不允许 `fmi3Set{VariableType}`。
9. 错。`fmi3UpdateDiscreteStates` 在每个超密集时间点至少调用一次；即使没有离散状态，也要调用以推进时间点、更新事件时间。
10. 错。从 `EventMode` / `StepMode` / `ClockActivationMode` 进入的是 `ReconfigurationMode`；从 `Instantiated` 进入的才是 `ConfigurationMode`。

</details>

### 7. 读代码：为什么 `ExitInitializationMode` 要分三种情况

回头看 6.5.4 的 `fmi3ExitInitializationMode` 实现：

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

回答：

1. 为什么同一个函数需要知道 `S->type`？
2. 为什么 CS 还要额外看 `S->eventModeUsed`？
3. 如果 `S->eventModeUsed = fmi3False`，导入端在 `ExitInitializationMode` 之后应该立即做什么？
4. 如果 `S->eventModeUsed = fmi3True`，导入端在第一次 `fmi3DoStep` 之前还欠哪一步？

<details>
<summary>答案</summary>

1. FMI 的公共 API 被三种接口共用，但初始化完成后的「运行状态」不同：ME 进入事件模式，CS 进入事件或步进模式，SE 进入时钟激活模式。这个分岔只能由实例的接口类型决定。
2. CS 的事件模式是可选的。`eventModeUsed` 是导入端在实例化时声明的能力：`true` 表示导入端愿意处理事件，FMU 进入 `EventMode`；`false` 表示事件由 FMU 内部处理，直接进入 `StepMode`。
3. 直接进入 `StepMode`，可以立即调用 `fmi3DoStep`；不需要 `fmi3UpdateDiscreteStates`，也不能调用 `fmi3EnterEventMode`。
4. 还欠初始事件迭代：先循环调用 `fmi3UpdateDiscreteStates` 直到 `discreteStatesNeedUpdate = fmi3False`，然后调用 `fmi3EnterStepMode`，之后才能 `fmi3DoStep`。

</details>

---

## 下一章

本章建立了公共骨架。下一章进入 Model Exchange：连续时间模式、事件指示器、导数计算，以及 `simulate_fmi3_me.c` 的逐行讲解。

→ [第 7 章 Model Exchange](07-model-exchange.md)
