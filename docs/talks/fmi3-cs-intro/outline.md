# FMI 3.0 分享会大纲：Co-Simulation 实战

> **状态**：大纲已定，待做 PPT
> **受众**：软件开发工程师（默认熟悉 C/C++，不熟悉数值方法与仿真）
> **时长**：60 分钟（含 5 分钟 Q&A）
> **基调**：以 **Co-Simulation** 为主线；ME / SE 只做对照，不展开
> **规范版本**：FMI 3.0.2

---

## 一、设计意图

### 1.1 为什么面向软件工程师

听众是软件开发工程师，不是仿真工程师。这意味着：

| 他们熟悉的 | 他们不熟悉的 |
| --- | --- |
| 状态机、生命周期、错误处理 | 事件定位、超密集时间、符号域 |
| 动态库加载、函数指针、ABI | 连续状态、导数、Jacobian |
| ABI 兼容性、版本协商 | 通信步长、内部步长 |
| 「谁调用谁」的边界划分 | 导入端 / 导出端（exporter / importer）职责 |

所以讲义的组织原则是：**用软件工程的词汇讲仿真接口**。状态机不是新概念，是另一种状态机；`fmi3DoStep` 不是「积分」，是「推进一个时间窗口」；能力标志不是「特性开关」，是「编译期能力协商」。

### 1.2 三条主线

大纲对应用户选定的三个重点：

1. **标准解读：接口与状态机** —— ME/CS/SE 的分工，CS 的调用序列与状态机，能力标志怎么读
2. **动手实现：自己写一个 FMU** —— 从零写、编译、打包、跑通
3. **导入端集成：怎么调用别人的 FMU** —— 动态加载、调用序列、常见坑

### 1.3 一句话主线

> **FMI 3.0 是一套「二进制插件的 ABI 约定」。**
> 约定三件事：FMU 里放什么文件（ZIP 布局）、怎么描述自己（modelDescription.xml）、怎么被调用（状态机 + 函数签名）。
> 剩下的就是普通的软件工程。

### 1.4 时间预算

| 段落 | 时长 | 累计 | 形式 |
| --- | --- | --- | --- |
| 0. 开场：为什么需要 FMI | 4 min | 4 min | 讲 |
| 1. FMU 是什么：解剖一个 .fmu | 6 min | 10 min | 讲 + 演示 |
| 2. 三种接口怎么选 | 5 min | 15 min | 讲 |
| 3. Co-Simulation 调用序列（核心） | 12 min | 27 min | 讲 + 代码 |
| 4. 动手：写一个最小 CS FMU | 14 min | 41 min | **动手** |
| 5. 导入端集成：调用别人的 FMU | 10 min | 51 min | 讲 + 代码 |
| 6. 收尾：速查卡 + Q&A | 9 min | 60 min | 讲 + Q&A |

**留有 5 分钟机动**：第 4 段动手最容易超时，现场可按 3.6 节的降级方案砍。

---

## 二、逐页大纲

> 标注约定：`[讲]` 纯讲解 · `[演]` 现场演示 · `[码]` 读代码 · `[问]` 抛问题给听众 · `⏱` 建议时长

### 第 0 段 · 开场（4 min）

**P01 封面** ⏱ 0.5
- 标题：FMI 3.0 实战 —— 从协议到可运行 FMU
- 副标题：以 Co-Simulation 为主线
- 底部：规范版本 3.0.2 · 本仓库所有示例可现场运行

**P02 今天要带走的四件事** ⏱ 1
- 看懂一个 FMU 目录里有什么、为什么这么排
- 说清 ME / CS / SE 三个接口分别在什么场景用
- 照着模板写出一个能被加载的 Co-Simulation FMU
- 写出一个调用别人 FMU 的导入端，知道有哪些坑
- 落点：**「讲完你就能独立做一个 FMU 的作者或用户」**

**P03 痛点：模型不能复用** ⏱ 2 `[问]`
- 场景：我们有一个 Simulink 模型，一个 Amesim 模型，一个自研的 C 内核。它们能互相通信吗？
- 现状：各家的接口是私有的，耦合代码写死在工程里
- FMI 的答案：**把模型封装成一个 ZIP，换掉里面的实现，接口不变**
- 一张图（现场画）：`模型A [私有接口] 模型B` → `模型A [FMU] ←ZIP→ 导入端 → 模型B`
- 落到一句话：**FMI 把「模型」变成了「二进制插件」，和 DLL 是同一个思路**

**P04 本次路线图** ⏱ 0.5
- 五段式路线图，标出每段时长
- 说明「每段都能独立带走」，中途离场也有收获

---

### 第 1 段 · FMU 是什么（6 min）

**P05 FMU = 一个 ZIP** ⏱ 1
- 强调这个反直觉但极其重要的事实：**没有特殊格式，就是 ZIP**
- 规范 2.5 节：扩展名必须是 `.fmu`；压缩方法只能是 deflate(8) 或 store(0)；不能分卷、不能加密
- 可以用任何解压工具打开

**P06 目录布局全景** ⏱ 2
```text
MyModel.fmu
├─ modelDescription.xml      ← 必须。模型的「头文件 + 配置文件」
├─ binaries/
│  └─ x86_64-windows/
│     └─ MyModel.dll         ← 平台元组目录
├─ sources/                  ← 可选。源码 + buildDescription.xml
├─ resources/                ← 可选。运行时要读的数据文件
├─ documentation/            ← 可选。index.html 等
└─ extra/                    ← 可选。分层标准
```
- `binaries/` 下的目录名叫**平台元组**（platform tuple），格式 `<arch>-<sys>`，如 `x86_64-windows`、`aarch64-linux`、`x86_64-darwin`
- 源码分发用 `sources/`，二进制分发用 `binaries/`，**两者可以并存**

**P07 现场演示：解剖 BouncingBall.fmu** ⏱ 2 `[演]`
> 命令（仓库根目录执行，已验证可跑）：
> ```powershell
> Add-Type -AssemblyName System.IO.Compression.FileSystem
> $z = [System.IO.Compression.ZipFile]::OpenRead('.\examples\fmus\3.0\BouncingBall.fmu')
> $z.Entries | Select-Object FullName, Length | Format-Table -AutoSize
> $z.Dispose()
> ```
- 现场展示 33 个条目、5 个平台、3 种格式（dll/so/dylib/wasm）
- 指出 `sources/` 里居然有完整源码 —— Reference FMUs 是源码分发的
- **不解释每个目录的细节**，只建立「这是个 ZIP + 有平台元组」的认知

**P08 modelDescription.xml 的三个部分** ⏱ 1
- 读 `examples/reference-fmus/BouncingBall/FMI3.xml`，只讲三块：
  1. **接口声明**：`<ModelExchange>` / `<CoSimulation>` / `<ScheduledExecution>` —— 我支持哪种玩法
  2. **变量清单**：`<ModelVariables>` —— 我有哪些输入输出
  3. **依赖结构**：`<ModelStructure>` —— 谁依赖谁
- 强调：`valueReference` 是**导入端和 FMU 之间唯一的对接方式**（不是变量名！）
- 落到一句话：**XML 是契约，变量名只是给人看的，`valueReference` 才是给机器看的**

---

### 第 2 段 · 三种接口怎么选（5 min）

**P09 三种接口的一句话定义** ⏱ 2
| 接口 | 谁积分 | 谁推进时间 | 一句话 |
| --- | --- | --- | --- |
| **ME** Model Exchange | 导入端 | 导入端 | FMU 只提供导数，像一个 ODE 求解器插件 |
| **CS** Co-Simulation | **FMU** | 双方协商 | FMU 自己是一个完整仿真器，导入端按步调用 |
| **SE** Scheduled Execution | 不涉及 | 导入端调度 | FMU 暴露可被外部调度器调用的模型分区 |

- 规范 2.2 节「Advancing Time」原文对比

**P10 选型决策树** ⏱ 2
```text
需要和别的模型紧耦合（通信点之间要传值）？
├─ 是 → 需要中间更新吗？
│       ├─ 是 → CS + providesIntermediateUpdate
│       └─ 否 → CS
└─ 否 → 需要和导入端的求解器耦合吗？
        ├─ 是 → ME
        └─ 否 → 只是把模型跑起来 → CS（首选）
```
- **本次主讲 CS**：它是默认选择、是使用面最广的、也是唯一「导入端最简单」的接口

**P11 ME 和 SE 各用一句话带过** ⏱ 1
- ME：导入端要写积分器和事件定位，代价高但耦合最好 → **留给需要共积分的人**
- SE：导入端是调度器，FMU 暴露模型分区，实时/HIL 场景 → **留给有硬实时调度器的团队**
- 给出参考页码：`docs/notes/07-model-exchange.md`、`docs/notes/09-scheduled-execution.md`
- 一句话收尾：**「今天只讲 CS，但你要知道另外两个存在，这样选型时不会把 ME 的活儿派给 CS」**

---

### 第 3 段 · Co-Simulation 调用序列（12 min，核心段）

**P12 CS 状态机全景** ⏱ 2
```text
       fmi3InstantiateCoSimulation
                  │
                  ▼
            Instantiated
                  │ fmi3EnterInitializationMode
                  ▼
         InitializationMode          ← 设参数、初值
                  │ fmi3ExitInitializationMode
                  ▼
            StepMode  ⇄  IntermediateUpdateMode
                  │                        （可选）
                  │ fmi3DoStep 循环
                  ▼
             Terminated
                  │ fmi3FreeInstance
                  ▼
```
- 若 XML 里 `hasEventMode="true"`，还会有 `EventMode` 分支
- **对照软件工程师熟悉的说法**：这就是「构造 → 初始化 → 跑 → 析构」，中间多一个「可重入配置」

**P13 实例化：12 个参数，逐个说** ⏱ 3 `[码]`
```c
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
```
- 重点讲 4 个，其余一扫而过：
  - `instantiationToken`：**导入端从 XML 里读出来传进来**，FMU 校验「这个 XML 是不是给我写的」。不匹配 → 实例化失败。类比：**ABI 版本握手**
  - `eventModeUsed`：**导入端告诉 FMU「我要不要管事件」**。`false` = FMU 自己全包了，导入端最省心
  - `earlyReturnAllowed`：允许 FMU 提前返回吗
  - `requiredIntermediateVariables`：导入端承诺会提供中间值的变量清单
- ⚠️ **坑点预告**：`visible` / `loggingOn` 只是给 GUI 用的，**不影响功能**

**P14 核心函数：fmi3DoStep 的 8 个参数** ⏱ 3 `[码]`
```c
fmi3Status fmi3DoStep(
    fmi3Instance  instance,
    fmi3Float64   currentCommunicationPoint,   // 从哪个时刻开始
    fmi3Float64   communicationStepSize,       // 走多远（必须 > 0）
    fmi3Boolean   noSetFMUStatePriorToCurrentPoint,
    fmi3Boolean*  eventHandlingNeeded,         // ← 出参
    fmi3Boolean*  terminateSimulation,         // ← 出参
    fmi3Boolean*  earlyReturn,                 // ← 出参
    fmi3Float64*  lastSuccessfulTime);        // ← 出参
```
- 前 4 个进，后 4 个出。**一个进一个出混排在签名里，是 FMI 3.0 的历史包袱**（FMI 2.0 分成了 `fmi2SetRealInputDerivatives` 等一堆函数）
- 4 个出参的语义**必须分清**（下一页专门讲）

**P15 四个出参的语义（最容易搞混的一页）** ⏱ 3
| 出参 | 含义 | 导入端该做什么 |
| --- | --- | --- |
| `eventHandlingNeeded` | FMU 在 `lastSuccessfulTime` 遇到事件 | 进 `EventMode` 迭代 |
| `terminateSimulation` | FMU 要求结束仿真 | 跳出主循环 |
| `earlyReturn` | FMU 没能走完整个步长 | 从 `lastSuccessfulTime` 继续 |
| `lastSuccessfulTime` | FMU 实际到达的时刻 | 记录/续算的基准点 |

- ⚠️ **`eventHandlingNeeded` ≠ `earlyReturn`**。规范 4.2 节原文明确区分：
  > "This is different from `earlyReturn` which only indicates that the `fmi3DoStep` did not complete the intended step up until `currentCommunicationPoint` + `communicationStepSize` and does not require event handling."
- ⚠️ **`lastSuccessfulTime` 只在 `earlyReturn` 时才有意义**
- 记忆法：**`earlyReturn` 是「没走完」，`eventHandlingNeeded` 是「走完了但撞上事件」**

**P16 完整调用序列（可直接抄走）** ⏱ 1 `[码]`
> 出自 `examples/reference-fmus/examples/simulate_fmi3_cs.c`，规范 4.3 节的官方示例
```c
// 1. 实例化
fmi3Instance m = fmi3InstantiateCoSimulation(...);

// 2. 进入初始化模式，设置参数
fmi3EnterInitializationMode(m, fmi3False, 0.0, startTime, fmi3True, stopTime);

// 3. 退出初始化模式
fmi3ExitInitializationMode(m);

// 4. 主循环
for (uint64_t step = 0;; step++) {
    fmi3Float64 time = step * h;
    fmi3SetFloat64(m, vrInput, 1, &inputValue, 1);   // 设置输入
    fmi3GetFloat64(m, vrOutput, 1, &outputValue, 1);  // 读输出
    fmi3DoStep(m, time, h, fmi3True,
               &eventHandlingNeeded, &terminateSimulation,
               &earlyReturn, &lastSuccessfulTime);
    if (terminateSimulation) break;
}

// 5. 收尾
fmi3Terminate(m);
fmi3FreeInstance(m);
```
- 强调顺序：**Set 输入 → DoStep → Get 输出**。和线程编程里的「提交命令 → 等结果」一样

**P17 能力标志：怎么读 modelDescription.xml** ⏱ 1
- 读 `BouncingBall/FMI3.xml` 的 `<CoSimulation>` 元素，逐个解释：
  - `canHandleVariableCommunicationStepSize="true"` —— 步长可以每次不同
  - `fixedInternalStepSize="1e-3"` —— 内部固定步长 1 ms，**导入端应该用它的整数倍做通信步长**
  - `providesIntermediateUpdate="true"` —— 支持中间更新
  - `mightReturnEarlyFromDoStep="true"` —— 可能提前返回
  - `hasEventMode="true"` —— 支持事件模式
- 类比：**这是「能力协商」，和 HTTP 的 `Accept` 头一个意思**。导入端读 XML → 决定怎么调
- 给出完整清单表（9 个 CS 专属标志），指出 `docs/notes/08-co-simulation.md` 有逐条说明

---

### 第 4 段 · 动手：写一个最小 CS FMU（14 min）

> **设计原则**：不从零写。用 `Dahlquist`（最简单的 ODE：`x' = -k·x`，解析解已知）作为模板，改成自己的模型，现场编译、打包、跑通。听众带走的是一个可复制的骨架。

**P18 动手目标与路线** ⏱ 0.5
- 目标：在 `Dahlquist`（最简单的 ODE：`x' = -k·x`）基础上加一个自己的变量，改一个方程，跑通
- 路线：改 `config.h` → 改 `model.c` → 改 `FMI3.xml` → 编译 → 看结果
- **不做「从零建项目」**：那要花掉 20 分钟且大部分是 CMake 配置，对理解 FMI 没帮助

**P19 FMU 的源码骨架** ⏱ 2 `[码]`
```text
Dahlquist/
├─ config.h           # 变量表：valueReference 枚举 + 数据结构 + 编译宏
├─ model.c            # 模型方程：getFloat64 / setFloat64 / getDerivatives
├─ FMI3.xml           # 描述文件（打包时改名 modelDescription.xml）
├─ FMI2.xml           # 同一模型的 FMI 2.0 版本（便于对照）
└─ Dahlquist_out.csv  # 参考仿真输出，供回归比对
```
> ⚠️ **模型目录里没有 `CMakeLists.txt`** —— 构建规则统一放在仓库根的 `examples/reference-fmus/CMakeLists.txt` 里，
> 所有模型共用一份。新增模型时要在根 `CMakeLists.txt` 的 `set(MODEL_NAMES ...)` 里登记。
>
> 打包规则也在同一份 CMakeLists 里（`POST_BUILD` 步骤）：把 `FMI3.xml` 复制成 `modelDescription.xml`、
> 把 `config.h` / `model.c` 复制进 `sources/`、把 DLL 放进 `binaries/<平台元组>/`，最后压成 `.fmu`。
> 见 `examples/reference-fmus/CMakeLists.txt` 的 200–240 行。

- 强调 **`config.h` 里的 `valueReference` 枚举和 `FMI3.xml` 里的 `valueReference` 必须一一对应**——这是 90% 调试时间的来源
- `config.h` 里还有一组编译宏决定「这个模型实现哪些功能」，例如 `CO_SIMULATION` / `MODEL_EXCHANGE` 决定接口类型，`MAX_CONTINUOUS_STATES` 决定状态个数，`SET_FLOAT64` / `GET_FLOAT64` 决定支持哪些变量类型


**P20 model.c 的最小实现** ⏱ 3 `[码]`
> 真实代码：`examples/reference-fmus/Dahlquist/model.c`。这是最短的连续状态模型
> ```c
> // 模型方程只有一个:  der(x) = -k * x
> // x' 是状态 x 的导数，k 是参数
>
> Status calculateValues(ModelInstance* comp) {
>     comp->isDirtyValues = false;
>     M(der_x) = -M(k) * M(x);      // ← 整个模型就是这一行
>     return OK;
> }
>
> Status getFloat64(ModelInstance* comp, ValueReference vr,
>                   double values[], size_t nValues, size_t* index) {
>     calculateValues(comp);        // ← 先算，再读。这就是「读变量触发计算」
>
>     switch (vr) {
>         case vr_time:  values[(*index)++] = comp->time; return OK;
>         case vr_x:     values[(*index)++] = M(x);       return OK;
>         case vr_der_x: values[(*index)++] = M(der_x);   return OK;
>         case vr_k:     values[(*index)++] = M(k);       return OK;
>         default:
>             logError(comp, "Get Float64 is not allowed for value reference %u.", vr);
>             return Error;
>     }
> }
>
> Status setFloat64(ModelInstance* comp, ValueReference vr,
>                   const double values[], size_t nValues, size_t* index) {
>     switch (vr) {
>         case vr_x: M(x) = values[(*index)++]; break;
>         case vr_k: M(k) = values[(*index)++]; break;
>         default:
>             logError(comp, "Set Float64 is not allowed for value reference %u.", vr);
>             return Error;
>     }
>     comp->isDirtyValues = true;
>     return OK;
> }
> ```
>
> **关键认知（CS 模式的核心）**：上面只给了**方程**，没给**积分器**。
> 积分在 `examples/reference-fmus/src/cosimulation.c` 的 `doFixedStep()` 里，用的是**前向欧拉**：
> ```c
> // forward Euler step
> for (size_t i = 0; i < comp->nx; i++) {
>     comp->x[i] += FIXED_SOLVER_STEP * comp->dx[i];
> }
> ```
> 步长 `FIXED_SOLVER_STEP` 在 `config.h` 里定义（Dahlquist 是 0.1）。
>
> 也就是说：**在 CS 模式下，FMU 内部自带一个求解器**。用什么积分器、什么步长，是 FMU 作者的自由，规范完全不管。
> 这正是 CS 和 ME 的分水岭 —— ME 下积分器在导入端，CS 下积分器在 FMU 里。


**P21 FMI3.xml 的最小写法** ⏱ 2 `[码]`
> 直接改 `examples/reference-fmus/Dahlquist/FMI3.xml`
```xml
<fmiModelDescription fmiVersion="3.0" modelName="MinimalCS"
                     instantiationToken="{...}">
  <CoSimulation modelIdentifier="MinimalCS"
                canHandleVariableCommunicationStepSize="true"/>
  <ModelVariables>
    <Float64 name="x" valueReference="1" causality="output"
             variability="continuous" initial="exact" start="1"/>
    <Float64 name="k" valueReference="2" causality="parameter"
             variability="fixed" initial="exact" start="1"/>
  </ModelVariables>
  <ModelStructure>
    <Output valueReference="1" dependencies=""/>
  </ModelStructure>
</fmiModelDescription>
```
- 三处必须改：`modelName`、`instantiationToken`、`modelIdentifier`
  - `modelIdentifier` 是**必填**（XSD 里 `use="required"`），它同时是 DLL / 静态库的文件名，必须和 `config.h` 里的 `MODEL_IDENTIFIER` 宏一致
- **`instantiationToken` 怎么生成**：任意唯一字符串，工具链通常自动生成；FMI 3.0 里它取代了 FMI 2.0 的 `guid`
  - 规范 2.4 节原文：「The `instantiationToken` is a string that may be used by the FMU to check that the XML file is compatible with the implementation of the FMU.」
  - 也就是说：**XML 和二进制必须成对**，换 XML 不换二进制（或反过来）会导致实例化失败

**P22 编译与打包** ⏱ 2 `[演]`
```powershell
cd examples\reference-fmus
cmake -B build .
cmake --build build --config Release
```
> ⚠️ 本机已验证：CMake（`E:\Environment\CMake\bin\cmake.exe`）+ Visual Studio 2022 Community
> （`D:\Soft\VisualStudio\2022\Community`）可用；生成器是 `Visual Studio 17 2022`。
> 构建产物：
> - `build/temp/<Model>/` —— 中间产物（`modelDescription.xml`、`binaries/`、`sources/`）
> - `build/temp/<Model>_cs.exe` / `_me.exe` —— 导入端示例程序
> - `build/fmus/<Model>.fmu` —— 打好的 FMU
>
> ⚠️ `build/` 已被 `.gitignore` 忽略，**不进版本库**。分享前必须在本机重新构建一次。
>
> 打包 FMU 的两种方式：
> 1. 用建模工具导出（Simulink / Dymola / OpenModelica 等）—— 工业界主流
> 2. 手工：把 `modelDescription.xml` + `binaries/<平台元组>/*.dll` + `sources/` 打成 ZIP，改名 `.fmu`
>    - Reference FMUs 的 `CMakeLists.txt` 用 `POST_BUILD` 命令自动完成第 2 步
>    - 手工打包时注意：ZIP 里**不能有顶层目录**，`modelDescription.xml` 必须在压缩包根

**P23 验证：跑起来看结果** ⏱ 2 `[演]`
> 命令（仓库根目录执行，已实测通过）：
> ```powershell
> $exe = (Resolve-Path '.\examples\reference-fmus\build\temp\Dahlquist_cs.exe').Path
> $dir = Join-Path $env:TEMP 'fmi-talk-dahlquist'
> New-Item -ItemType Directory -Force $dir | Out-Null
> Push-Location $dir
> try { & $exe } finally { Pop-Location }
> Get-Content (Join-Path $dir 'Dahlquist_cs_out.csv') -TotalCount 5
> ```
> 实际输出（已实测）：
> ```text
> time,x
> 0,1
> 0.1,0.9
> 0.2,0.81
> 0.3,0.729
> ```
>
> **教学点**：这个模型的解析解是 `x(t) = exp(-t)`，`x(1) = 0.3679`。
> 但 CSV 里 `t=1` 时 `x = 0.3487` —— **对不上，差了 5%**。
>
> 为什么？因为 Reference FMUs 内部用的是**一阶前向欧拉**（见 P20），不是精确解。
> 这不是 bug，是「CS 模式把积分器塞在 FMU 里」的必然结果：
>
> | | 谁决定积分精度 |
> | --- | --- |
> | ME | 导入端的求解器（可以用高阶 RK、隐式方法） |
> | CS | FMU 内部的求解器（`fixedInternalStepSize="0.1"`） |
>
> 由此引出 CS 的**核心使用建议**：
>
> > 导入端应该把通信步长 `h` 取成 `fixedInternalStepSize` 的**整数倍**，
> > 这样每个通信点都落在 FMU 内部步的整数倍上，误差不会在通信点累积错位。
>
> 这个结论直接来自规范 4.4 节对 `fixedInternalStepSize` 的说明：
> > "The importer should use an integer multiple of this value as communication step size."
>
> **强调验证的重要性**：FMU 的价值在于结果可信，不是「能跑」。跑通之后一定要拿解析解对一遍。


**P24 动手环节的常见翻车点** ⏱ 1.5
- `valueReference` 对不上 → 读出乱七八糟的值
- `instantiationToken` 没改 → 实例化直接失败
- `modelIdentifier` 和 DLL 文件名不一致 → 加载失败
- 忘了改 `MODEL_IDENTIFIER` 宏 → DLL 名字错
- 用 `initial="calculated"` 但没实现 `fmi3EvaluateDiscreteStates` → 初始化卡住
- **每个都对应一条日志/报错特征**，见 `docs/notes/14`（待写）

---

### 第 5 段 · 导入端集成：调用别人的 FMU（10 min）

**P25 导入端的四步** ⏱ 1
```text
1. 解压 FMU，找到 binaries/<平台元组>/*.dll
2. LoadLibrary / dlopen
3. GetProcAddress 取函数指针
4. 按状态机调用
```
- 「和加载一个普通 DLL 完全一样」——**这是本段要传达的核心**

**P26 动态加载的代码** ⏱ 3 `[码]`
> 出自 `examples/reference-fmus/examples/import_shared_library.c`
```c
#ifdef _WIN32
  HMODULE h = LoadLibraryA("VanDerPol\\binaries\\x86_64-windows\\VanDerPol.dll");
  fmi3InstantiateModelExchangeTYPE *inst =
      (fmi3InstantiateModelExchangeTYPE *)
      GetProcAddress(h, "fmi3InstantiateModelExchange");
#else
  void *h = dlopen("VanDerPol/binaries/x86_64-linux/VanDerPol.so", RTLD_LAZY);
  fmi3InstantiateModelExchangeTYPE *inst =
      (fmi3InstantiateModelExchangeTYPE *)
      dlsym(h, "fmi3InstantiateModelExchange");
#endif
```
- **平台元组路径是拼出来的**，不同平台目录名不同 → 导入端必须做映射
- ⚠️ **FMU 要先解压再加载**，不能直接加载 `.fmu`（那是 ZIP）

**P27 导入端的调用序列（和 FMU 作者同一套）** ⏱ 2 `[码]`
- 和 P16 是同一套调用序列，只是换成「通过函数指针调用」
- 强调：**FMU 作者和导入端是同一份契约的两端**。你今天学的调用序列，两边都要遵守
- 补充：导入端还要负责
  - 解析 `modelDescription.xml`，建立 `valueReference` → 变量名的映射
  - 单位换算（`<UnitDefinitions>`）
  - 按 `fixedInternalStepSize` 选通信步长
  - 处理 `fmi3Discard`（可重试）vs `fmi3Error`（致命）

**P28 三个必踩的坑** ⏱ 3
1. **状态机违规**：在 `StepMode` 里调 `fmi3EnterEventMode` → FMU 返回 `fmi3Error`。规范要求「调用方必须自己保证状态合法」，FMU 只负责拒绝
2. **`fmi3Discard` 当成了错误**：CS 里 `fmi3Discard` 表示「这一步没做成，可以重试」，不是致命错误
3. **忘了检查 `fmi3Status` 返回值**：所有 FMI 函数都返回状态，忽略它等于关掉了所有错误处理
   - 参考 `docs/notes/08-co-simulation.md` 的「常见错误清单」（14 条）

**P29 工具链现状** ⏱ 1
- `fmusim`：官方命令行仿真器，可以 `--show-model-description` 直接看接口信息
- `FMPy`：Python 生态，3 行就能跑一个 FMU，适合做快速验证和 CI
- Reference FMUs：官方提供的验证套件，仓库里已有 9 个 FMI 3.0 的
- ⚠️ 本机环境说明：`fmusim` / `FMPy` **未安装**，现场演示用仓库自带的 `build/temp/*.exe`；如果分享前需要，可先装好

---

### 第 6 段 · 收尾（9 min）

**P30 速查卡（可拍照）** ⏱ 1
> 一页纸，包含：
> - CS 调用序列（8 步）
> - `fmi3DoStep` 8 个参数
> - 4 个出参的决策表
> - 9 个 CS 能力标志
> - 最小 FMU 的 4 个文件
> - XML 三处必改

**P31 从这里往哪走** ⏱ 2
- **做 FMU 作者** → `docs/notes/10-14`（待写）+ `docs/guides/implementers-guide/`
- **做导入端** → `docs/notes/13` + `examples/reference-fmus/examples/`
- **深挖 ME / SE** → `docs/notes/07`、`docs/notes/09`
- **查规范** → `docs/spec-3.0.2/html/index.html`（离线单页，`Ctrl+F` 可搜）
- 强调本仓库：**所有示例都能现场跑**，不是纸上谈兵

**P32 Q&A 预设问题** ⏱ 5
> 提前准备这 6 个高频问题的答案
1. 「我们已经有 DLL 了，为什么还要 FMI？」→ 因为 DLL 只有 ABI，没有**模型语义**（变量、单位、依赖、事件）
2. 「FMI 3.0 和 2.0 差别大吗？」→ XML 大改（变量系统、`valueReference`、单位类型），C API 小改（主要是 CS 的早返回和中间更新）
3. 「性能损失大吗？」→ 通信点之间的开销主要是序列化和步长限制；ME 模式可以把开销降到很低
4. 「能不能多个 FMU 共享一个 DLL？」→ 可以，但 `instantiationToken` 要用 `fmi3Instantiate` 的 `instanceName` 区分
5. 「我们该选 CS 还是 ME？」→ 默认 CS；只有需要和导入端共积分（紧耦合）才选 ME
6. 「怎么保证别人的 FMU 是对的？」→ 用 Reference FMUs 做交叉验证，仓库里已有现成的

---

## 三、素材与依赖清单

### 3.1 需要准备的素材

| 素材 | 来源 | 状态 |
| --- | --- | --- |
| BouncingBall.fmu 解包演示 | `examples/fmus/3.0/BouncingBall.fmu` | ✅ 已有，已验证命令 |
| Dahlquist 的 3 个源码文件 | `examples/reference-fmus/Dahlquist/` | ✅ 已有 |
| CS 调用序列代码 | `examples/reference-fmus/examples/simulate_fmi3_cs.c` | ✅ 已有 |
| 动态加载代码 | `examples/reference-fmus/examples/import_shared_library.c` | ✅ 已有 |
| CS 能力标志清单 | `docs/spec-3.0.2/schema/fmi3InterfaceType.xsd` | ✅ 已有 |
| 现场编译产物 | `examples/reference-fmus/build/` | ⚠️ 需分享前重新构建（`build/` 不进版本库） |
| 状态机图 | `docs/spec-3.0.2/adoc/images/` | ✅ 规范原图可引用 |
| 速查卡 | 新做 | ❌ 待制作 |

### 3.2 环境依赖（分享前必须确认）

| 依赖 | 本机状态 | 用途 |
| --- | --- | --- |
| CMake | ✅ `E:\Environment\CMake\bin\cmake.exe` | 编译 FMU |
| Visual Studio 2022 Community | ✅ `D:\Soft\VisualStudio\2022\Community` | 编译器（vswhere 可找到） |
| Node.js | ✅ `D:\Soft\nodejs\node.exe` | Marp 导出 PPT |
| `fmusim` | ❌ 未安装 | 可选，替代方案用仓库 exe |
| FMPy / Python | ❌ 未安装 | 可选 |
| 已构建的 `build/temp/*.exe` | ✅ 存在 | 现场演示 |

### 3.3 演示脚本（全部已验证可跑）

```powershell
# D1 解包 FMU
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::OpenRead('.\examples\fmus\3.0\BouncingBall.fmu')
$z.Entries | Select-Object FullName, Length | Format-Table -AutoSize
$z.Dispose()

# D2 跑 CS 仿真
$exe = (Resolve-Path '.\examples\reference-fmus\build\temp\Dahlquist_cs.exe').Path
$dir = Join-Path $env:TEMP 'fmi-talk'; New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try { & $exe } finally { Pop-Location }
Get-Content (Join-Path $dir 'Dahlquist_cs_out.csv') -TotalCount 5

# D3 看 CS 能力标志
$xml = [xml](Get-Content '.\examples\reference-fmus\BouncingBall\FMI3.xml' -Raw -Encoding UTF8)
$xml.fmiModelDescription.CoSimulation | Format-List

# D4 校验 XML
.\examples\scripts\validate-model-description.ps1 .\examples\reference-fmus\BouncingBall\FMI3.xml
```

---

## 四、风险与降级方案

| 风险 | 概率 | 降级方案 |
| --- | --- | --- |
| 现场编译失败（缺依赖 / 路径问题） | 中 | 提前把 `build/` 编译好并**拷贝到非 git 目录**；或直接播放预录的 CSV 输出 |
| 动手环节超时 | **高** | 见 4.1 节的分级降级 |
| 听众在 ME / SE 上追问 | 中 | 「今天主讲 CS，ME/SE 的细节在 `docs/notes/07` 和 `09`，会后可以单独聊」 |
| Q&A 冷场 | 低 | 用 P32 的预设问题起头 |
| 投影分辨率导致代码看不清 | 中 | 代码页最多 15 行 / 页；长代码用截图放大 |

### 4.1 动手环节的分级降级

按剩余时间选一个：

- **完整版（14 min）**：改 `config.h` → 改 `model.c` → 改 XML → 编译 → 打包 → 跑 → 看结果
- **半程版（7 min）**：只改 `config.h`（加一个参数）和 `FMI3.xml`（加一个变量），编译并跑，看新变量出现在 CSV 里
- **演示版（2 min）**：**不编译**，直接打开预先改好的 `MinimalCS` 源码，逐段讲「这个文件负责什么」，然后播放预录的运行输出

> 建议：**代码提前改好并编译通过**，现场只演示「改一个数字 → 重编译 → 输出变化」这一个动作。把「写代码」的时间留给听众课后动手。

### 4.2 PPT 生成路径

- 推荐 [Marp](https://marp.app/)：写 Markdown → 导出 PDF / PPTX
  ```powershell
  npx @marp-team/marp-cli slides.md --pdf -o slides.pdf
  npx @marp-team/marp-cli slides.md --pptx -o slides.pptx
  ```
- 本机 Node.js 可用，无需额外安装
- 幻灯片源文件放 `slides/`，讲义放 `handouts/`，素材放 `assets/`

---

## 五、与仓库既有内容的关系

| 本场次内容 | 仓库对应章节 | 用法 |
| --- | --- | --- |
| FMU 目录布局 | `docs/notes/02-unpack-fmu.md` | 精简取用 |
| modelDescription.xml | `docs/notes/03-model-description.md` | 精简取用 |
| CS 调用序列 | `docs/notes/08-co-simulation.md` | 核心来源 |
| 状态机全图 | `docs/notes/06-state-machine.md` | 参考 |
| ME / SE 对照 | `docs/notes/07`、`09` | 一句话带过 |
| 常见错误清单 | `docs/notes/08` 13 节 / `docs/notes/14`（待写） | P28 的来源 |

> **注意**：本大纲是**教学取舍**，不是规范的替代品。PPT 里凡涉及规范条款的地方都要标注章节号，方便听众回去查。

---

## 六、待确认事项

1. **听众是否需要自己动手？** 如果是「坐着听」，第 4 段改为「我演示 + 大家跟着看」，节奏更从容。
2. **是否需要讲 ME 的具体调用？** 如果听众里有做共积分的，可能要加 5 分钟。
3. **讲义是否需要打印版？** 「速查卡」（P30）建议做 A4 双面打印，参会者带走。
4. **分享后的跟进材料** —— 建议发仓库链接 + `docs/notes/README.md`，让人按需自学。
