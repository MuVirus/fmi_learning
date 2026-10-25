# 第 3 章 `modelDescription.xml` 精读：骨架

> **第二部分：看懂描述文件 · 初稿**
> 对应规范：[2.4 FMI Description Schema](../spec-3.0.2/html/index.html#modelDescription.xml)、[2.4.1 Model Description](../spec-3.0.2/html/index.html#fmiModelDescription)、[2.4.2 Capability Flags](../spec-3.0.2/html/index.html#common-capability-flags)、[2.4.8 Model Structure](../spec-3.0.2/html/index.html#ModelStructure)
> 预计阅读：35 分钟
> 动手时间：15 分钟

## 学习目标

读完本章，你应该能够：

1. 说清 `modelDescription.xml` 的**元素顺序**为什么不能随便调。
2. 区分根元素上「必需 / 可选」的属性，并解释 `instantiationToken` 的作用。
3. 根据 `<ModelExchange>` / `<CoSimulation>` / `<ScheduledExecution>` 的能力标志，判断一个 FMU 能做什么。
4. 读懂 `DefaultExperiment`、`LogCategories` 和 `ModelStructure`。
5. 用仓库里的脚本对任意 `modelDescription.xml` 做 XSD 校验，并解释「校验通过」不等于「语义正确」。

第 2 章解决的是「FMU 里有什么」，本章开始解决「这些文件在说什么」。第 4、5 章再进入变量、单位、类型的细节。

---

## 3.1 先看一份完整的真实文件

`examples/fmus/3.0/BouncingBall.fmu` 解包后的 `modelDescription.xml` 只有 75 行，却覆盖了本章要讲的每一块。先通读一遍，不求全部记住：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription
  fmiVersion="3.0"
  modelName="BouncingBall"
  description="This model calculates the trajectory, over time, of a ball dropped from a height of 1 m"
  generationTool="Reference FMUs (v0.0.42)"
  generationDateAndTime="2026-10-23T14:03:20.849113+00:00"
  instantiationToken="{1AE5E10D-9521-4DE3-80B9-D0EAAA7D5AF1}">

  <ModelExchange
    modelIdentifier="BouncingBall"
    canGetAndSetFMUState="true"
    canSerializeFMUState="true"/>

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

  <UnitDefinitions>
    <Unit name="m">
      <BaseUnit m="1"/>
      <DisplayUnit name="ft" factor="3.280839895"/>
    </Unit>
    <Unit name="m/s">
      <BaseUnit m="1" s="-1"/>
    </Unit>
    <Unit name="m/s2">
      <BaseUnit m="1" s="-2"/>
    </Unit>
  </UnitDefinitions>

  <TypeDefinitions>
    <Float64Type name="Position" quantity="Position" unit="m"/>
    <Float64Type name="Velocity" quantity="Velocity" unit="m/s"/>
    <Float64Type name="Acceleration" quantity="Acceleration" unit="m/s2"/>
  </TypeDefinitions>

  <LogCategories>
    <Category name="logEvents" description="Log events"/>
    <Category name="logStatusError" description="Log error messages"/>
  </LogCategories>

  <DefaultExperiment startTime="0" stopTime="3" stepSize="1e-2"/>

  <ModelVariables>
    <Float64 name="time" valueReference="0" causality="independent" variability="continuous" description="Simulation time"/>
    <Float64 name="h" valueReference="1" causality="output" variability="continuous" initial="exact" declaredType="Position" start="1" reinit="true" description="Position of the ball" intermediateUpdate="true">
      <Alias name="h_ft" description="Position in feet" displayUnit="ft"/>
    </Float64>
    <Float64 name="der(h)" valueReference="2" causality="local" variability="continuous" initial="calculated" declaredType="Velocity" derivative="1" description="Derivative of h"/>
    <Float64 name="v" valueReference="3" causality="output" variability="continuous" initial="exact" declaredType="Velocity" start="0" reinit="true" description="Velocity of the ball" intermediateUpdate="true"/>
    <Float64 name="der(v)" valueReference="4" causality="local" variability="continuous" initial="calculated" declaredType="Acceleration" derivative="3" description="Derivative of v"/>
    <Float64 name="g" valueReference="5" causality="parameter" variability="fixed" initial="exact" declaredType="Acceleration" start="-9.81" description="Gravity acting on the ball"/>
    <Float64 name="e" valueReference="6" causality="parameter" variability="tunable" initial="exact" start="0.7" min="0.5" max="1" description="Coefficient of restitution"/>
    <Float64 name="v_min" valueReference="7" variability="constant" declaredType="Velocity" start="0.1" description="Velocity below which the ball stops bouncing"/>
  </ModelVariables>

  <ModelStructure>
    <Output valueReference="1" dependencies=""/>
    <Output valueReference="3" dependencies=""/>
    <ContinuousStateDerivative valueReference="2" dependencies="3" dependenciesKind="constant"/>
    <ContinuousStateDerivative valueReference="4" dependencies="5" dependenciesKind="constant"/>
    <InitialUnknown valueReference="2" dependencies="3" dependenciesKind="constant"/>
    <InitialUnknown valueReference="4" dependencies="5" dependenciesKind="constant"/>
    <EventIndicator valueReference="1"/>
  </ModelStructure>

</fmiModelDescription>
```

按块拆开，就是本章的目录：

| 块 | 作用 | 本章小节 |
| --- | --- | --- |
| 根元素属性 | 版本、模型名、实例令牌 | 3.3 |
| `ModelExchange` / `CoSimulation` | 声明接口与能力 | 3.4 |
| `UnitDefinitions` / `TypeDefinitions` | 单位与类型字典 | 第 5 章 |
| `LogCategories` | 日志分类 | 3.6 |
| `DefaultExperiment` | 默认实验设置 | 3.5 |
| `ModelVariables` | 所有变量 | 第 4 章 |
| `ModelStructure` | 输出顺序、状态导数、事件指示器、依赖 | 3.7 |

> 这份文件与仓库源码目录里的 `examples/reference-fmus/BouncingBall/FMI3.xml` 内容基本一致，只多了打包时写入的 `generationDateAndTime`。讲授时以 FMU 内的实际文件为准。

---

## 3.2 元素顺序不是自由的

`fmiModelDescription.xsd` 把子元素定义成 `xs:sequence`，顺序固定：

```text
ModelExchange?  →  CoSimulation?  →  ScheduledExecution?
→  UnitDefinitions?  →  TypeDefinitions?  →  LogCategories?
→  DefaultExperiment?  →  ModelVariables  →  ModelStructure  →  Annotations?
```

（`?` 表示可选；`ModelVariables` 和 `ModelStructure` 是必需的。）

这意味着下面这种写法虽然「看起来合理」，但一定过不了 XSD：

```xml
<!-- 错误：DefaultExperiment 跑到了 LogCategories 前面 -->
<DefaultExperiment startTime="0" stopTime="3"/>
<LogCategories>...</LogCategories>
```

很多手写 XML 的 bug 就出在这里。生成器一般会保证顺序，手写或脚本拼接时容易踩坑。

`ModelVariables` 内部的变量顺序则**没有**语义：变量靠 `valueReference` 识别，不靠位置。真正有顺序语义的是 `ModelStructure` 里的列表（见 3.7）。

---

## 3.3 根元素属性

### 3.3.1 必需属性

| 属性 | 类型 | 说明 |
| --- | --- | --- |
| `fmiVersion` | 字符串 | 必须是 `3.x`。FMI 3.0 系列写 `3.0`；补丁版本 3.0.1 / 3.0.2 **不改变**这个值 |
| `modelName` | 字符串 | 建模环境里的完整模型名，例如 `Modelica.Mechanics.Rotational.Examples.CoupledClutches` |
| `instantiationToken` | 字符串 | 导出端生成的不透明令牌，导入端必须原样传给 `fmi3Instantiate*` |

关于 `fmiVersion`：XSD 允许 `3.0`、`3.1`、`3.0.2` 甚至 `3.0-alpha.2` 这类开发版本标记；但正式发布的 3.0.x FMU 一律写 `3.0`。所以**不要**用 `fmiVersion` 判断补丁版本——它区分不了 3.0.2 和 3.0.0。

关于 `instantiationToken`：它不是 GUID 的强制格式，而是一个「XML 与二进制是否配套」的校验串。规范只要求它是不透明字符串，由导出端生成、导入端原样传递。实践上常用 GUID：

```xml
instantiationToken="{1AE5E10D-9521-4DE3-80B9-D0EAAA7D5AF1}"
```

FMI 2.0 里对应的是 `guid`。两者的区别不只是改名：2.0 时代很多工具把 `guid` 当普通元数据；3.0 明确它是实例化参数的一部分。

> 一个常见误解：以为 `instantiationToken` 可以由导入端自由生成。不可以——它必须来自 XML，否则 FMU 无法判断 XML 与实现是否匹配。

### 3.3.2 可选属性

| 属性 | 用途 | 备注 |
| --- | --- | --- |
| `description` | 模型简述 | 会显示在工具界面里，建议写 |
| `author` | 作者 | 自由文本 |
| `version` | 模型版本 | 例如 `1.2.0`，与 FMI 版本无关 |
| `copyright` | 版权声明 | 自由文本 |
| `license` | 许可证 | 长文本请放 `documentation/licenses/` |
| `generationTool` | 生成工具及版本 | 排查问题时非常有用 |
| `generationDateAndTime` | 生成时间 | `xs:dateTime`，推荐 `YYYY-MM-DDThh:mm:ssZ` |
| `variableNamingConvention` | 命名约定 | `flat`（默认）或 `structured`，见 4.12 |

`generationTool` 和 `generationDateAndTime` 值得养成习惯：拿到一个陌生 FMU，先看这两项，能快速判断是谁、用什么版本导出的。Reference FMUs 的打包文件写的是 `Reference FMUs (v0.0.42)`，而源码目录里的 `FMI3.xml` 写的是 `development build`——这就是为什么同一个模型的两份 XML 不完全一样。

---

## 3.4 接口元素与能力标志

### 3.4.1 `modelIdentifier`

三个接口元素都必须有 `modelIdentifier`，它同时承担两个职责：

1. **定位实现文件**：`binaries/<platformTuple>/<modelIdentifier>.dll`（或 `.so` / `.dylib`）。
2. **给源码/静态库加函数前缀**：源码 FMU 编译时通常定义
   ```c
   #define FMI3_FUNCTION_PREFIX BouncingBall_
   #include "fmi3Functions.h"
   ```
   实际符号就变成 `BouncingBall_fmi3InstantiateModelExchange` 等。动态库则使用不带前缀的 `fmi3*` 名字。

`modelIdentifier` 必须是符合 C 语法的短类名（字母、数字、下划线），不能带路径、空格或扩展名。BouncingBall 的两个接口都写 `BouncingBall`，所以共用同一个二进制；如果两个接口指向不同的实现，就会写成两个名字，对应两个库文件：

```text
binaries/x86_64-windows/
  MyModel_ModelExchange.dll
  MyModel_CoSimulation.dll
```

注意规范还有一条硬约束：**一个 FMU 只有在各接口的变量完全一致时，才能同时声明多个接口类型**。所以「ME 和 CS 变量表不同」的 FMU 是不合规的。

### 3.4.2 三种接口共有的能力标志

所有布尔标志默认都是 `false`。也就是说，**不写就是不支持**，不要指望导入端「猜」。

| 标志 | 含义 | 约束 |
| --- | --- | --- |
| `needsExecutionTool` | 运行 FMU 需要外部工具 | 依赖要在 `documentation/externalDependencies.{txt\|html}` 里说明 |
| `canBeInstantiatedOnlyOncePerProcess` | 每个进程只能实例化一次 | 常见于带全局状态的商业工具 |
| `canGetAndSetFMUState` | 支持 `fmi3GetFMUState` / `fmi3SetFMUState` / `fmi3FreeFMUState` | — |
| `canSerializeFMUState` | 支持状态序列化/反序列化 | 为 `true` 时 `canGetAndSetFMUState` 必须也为 `true` |
| `providesDirectionalDerivatives` | 支持 `fmi3GetDirectionalDerivative` | 优化、灵敏度分析会用到 |
| `providesAdjointDerivatives` | 支持 `fmi3GetAdjointDerivative` | 反传梯度场景 |
| `providesPerElementDependencies` | 运行时可查询逐元素依赖 | 对应 `fmi3GetVariableDependencies` |
| `providesEvaluateDiscreteStates` | 支持 `fmi3EvaluateDiscreteStates` | SE 中忽略该标志 |

`canSerializeFMUState` 的约束很容易被忽略：序列化建立在「能取到状态」之上，所以两者不能出现 `true/false` 的矛盾组合。

### 3.4.3 Model Exchange 专属

| 标志 | 默认 | 含义 |
| --- | --- | --- |
| `needsCompletedIntegratorStep` | `false` | 为 `true` 时，导入端每完成一个积分步都必须调用 `fmi3CompletedIntegratorStep` |

BouncingBall 的 ME 元素只有两个状态标志，没写 `needsCompletedIntegratorStep`，因此是 `false`——导入端可以在积分步结束后直接继续，不必回调。

### 3.4.4 Co-Simulation 专属

| 标志 / 属性 | 默认 | 含义 |
| --- | --- | --- |
| `canHandleVariableCommunicationStepSize` | `false` | 每次 `fmi3DoStep` 的通信步长可以不同 |
| `fixedInternalStepSize` | 无 | 内部固定步长；导入端宜取它的整数倍作为通信步长 |
| `maxOutputDerivativeOrder` | `0` | 最多能提供几阶输出导数 |
| `recommendedIntermediateInputSmoothness` | `0` | 中间输入建议的连续性阶数（`k=0` 表示连续） |
| `providesIntermediateUpdate` | `false` | 支持中间更新回调 |
| `mightReturnEarlyFromDoStep` | `false` | 可能提前从 `fmi3DoStep` 返回 |
| `canReturnEarlyAfterIntermediateUpdate` | `false` | 响应导入端的早返回请求 | 
| `hasEventMode` | `false` | 支持事件模式；**有 Clock 时必须为 `true`** |

两条依赖关系：

- `canReturnEarlyAfterIntermediateUpdate = true` 要求 `providesIntermediateUpdate = true`；
- 只要 FMU 里有 Clock，`hasEventMode` 就必须是 `true`。

回到 BouncingBall 的 CS 元素，现在应该能逐行翻译：

```xml
<CoSimulation
  modelIdentifier="BouncingBall"
  canGetAndSetFMUState="true"          <!-- 可保存/恢复状态 -->
  canSerializeFMUState="true"          <!-- 状态可序列化 -->
  canHandleVariableCommunicationStepSize="true"  <!-- 通信步长可变 -->
  providesIntermediateUpdate="true"    <!-- 支持中间更新 -->
  mightReturnEarlyFromDoStep="true"    <!-- 可能早返回 -->
  canReturnEarlyAfterIntermediateUpdate="true"   <!-- 响应早返回请求 -->
  fixedInternalStepSize="1e-3"         <!-- 内部 1 ms 固定步长 -->
  hasEventMode="true"/>                <!-- 支持事件模式 -->
```

### 3.4.5 Scheduled Execution 专属

`<ScheduledExecution>` 没有额外属性，只有公共能力标志：

```xml
<ScheduledExecution modelIdentifier="Clocks"/>
```

它是否「真能调度」取决于变量表里的 Clock 定义（见第 9 章）。Reference FMUs 的 `Clocks` 模型就是最小的 SE 例子。

### 3.4.6 一个 FMU，多个接口

BouncingBall 同时声明 ME 和 CS，且共用 `modelIdentifier`。导入端实例化时只能选一种：

```c
fmi3Instance me = fmi3InstantiateModelExchange(...);
/* 或者 */
fmi3Instance cs = fmi3InstantiateCoSimulation(...);
```

不能「一个实例同时当 ME 和 CS 用」。这一点在第 1 章已经强调过，这里补上 XML 侧的证据。

---

## 3.5 `DefaultExperiment`：只是建议

```xml
<DefaultExperiment startTime="0" stopTime="3" stepSize="1e-2"/>
```

| 属性 | 含义 |
| --- | --- |
| `startTime` | 独立变量的默认起始值（通常是 0 s） |
| `stopTime` | 默认停止时间 |
| `tolerance` | 默认相对容差 |
| `stepSize` | 默认步长；对 CS 是**建议的通信步长**，对 ME/SE 没有规范定义的含义 |

规范明确说这些值「may be ignored」——导入端可以完全无视。但一个好 FMU 应该给出合理的默认值，否则用户每次都要手填。

注意 BouncingBall 的两个「步长」不是一回事：

- `DefaultExperiment stepSize="1e-2"`：建议导入端每 10 ms 交换一次数据；
- `CoSimulation fixedInternalStepSize="1e-3"`：FMU 内部每 1 ms 积分一步。

10 是 1 的整数倍，正好符合「通信步长宜取内部步长整数倍」的建议。

---

## 3.6 `LogCategories`：日志开关的词汇表

`LogCategories` 声明这个 FMU 支持哪些日志分类，导入端用 `fmi3SetDebugLogging` 打开/关闭。BouncingBall 只声明了两个：

```xml
<LogCategories>
  <Category name="logEvents" description="Log events"/>
  <Category name="logStatusError" description="Log error messages"/>
</LogCategories>
```

规范预定义了 8 个标准分类：

| 分类 | 什么时候用 |
| --- | --- |
| `logEvents` | 初始化与仿真过程中的事件 |
| `logSingularLinearSystems` | 线性方程组奇异 |
| `logNonlinearSystems` | 非线性方程组求解 |
| `logDynamicStateSelection` | 动态状态选择 |
| `logStatusWarning` | 函数返回 `fmi3Warning` |
| `logStatusDiscard` | 函数返回 `fmi3Discard` |
| `logStatusError` | 函数返回 `fmi3Error` |
| `logStatusFatal` | 函数返回 `fmi3Fatal` |

工具商的分类名可以自定义，但上面 8 个名字不能改。写导入端时，按名字匹配即可，不要依赖顺序（`LogCategories` 是无序集合）。

> 调试技巧：FMU 不打印日志时，先确认它**有没有声明**对应分类，再确认导入端有没有打开。很多「日志丢失」其实是分类没声明。

---

## 3.7 `ModelStructure`：谁依赖谁

`ModelVariables` 描述「有哪些变量」，`ModelStructure` 描述「它们怎么连起来」。五个列表：

| 元素 | 内容 | 顺序是否有意义 |
| --- | --- | --- |
| `Output` | 所有 `causality="output"` 的变量 | 有：定义输出向量顺序 |
| `ContinuousStateDerivative` | 所有连续状态导数 | 有：定义状态向量顺序 |
| `ClockedState` | 时钟离散状态 | 有 |
| `InitialUnknown` | 初始化阶段的未知量 | 有 |
| `EventIndicator` | 事件指示器 | 有：对应 `fmi3GetEventIndicators` 的数组顺序 |

### 3.7.1 `Output` 必须「一个不少」

规范要求：`Output` 列表包含**所有**输出，且只包含输出。也就是说：

- 变量表里有 `causality="output"`，`ModelStructure` 里没列 → 不合规；
- `ModelStructure` 里列了非输出变量 → 不合规。

BouncingBall 的两个输出 `h`（vr=1）和 `v`（vr=3）都在：

```xml
<Output valueReference="1" dependencies=""/>
<Output valueReference="3" dependencies=""/>
```

### 3.7.2 `dependencies`：三种状态，含义完全不同

这是最容易读错的地方：

| 写法 | 含义 |
| --- | --- |
| 属性**缺失** | 未知量依赖**所有**已知量（最保守的假设） |
| `dependencies=""` | 依赖**空集**——不依赖任何已知量 |
| `dependencies="3 5"` | 只依赖 vr=3 和 vr=5 |

BouncingBall 写的是 `dependencies=""`，意思很明确：输出 `h` 不依赖任何输入、参数或时间（它本身就是状态）。如果把属性删掉，语义会变成「依赖所有已知量」，虽然对仿真结果未必有影响，但会丢失信息。

`dependenciesKind` 进一步描述依赖形式：

| 值 | 含义 | 适用范围 |
| --- | --- | --- |
| `dependent` | 一般函数关系（默认） | 全部 |
| `constant` | 常数系数 `c·v`，`c` 在初始化前确定 | 浮点未知量 |
| `fixed` | 固定系数 `p·v`，`p` 在退出初始化前确定 | 浮点；不能用于 `InitialUnknown` |
| `tunable` | 可调系数，随 tunable 参数变化 | 浮点；不能用于 `InitialUnknown` |
| `discrete` | 离散系数，在事件/通信点更新 | 浮点；不能用于 `InitialUnknown` |

BouncingBall 的导数关系都标了 `constant`：

```xml
<ContinuousStateDerivative valueReference="2" dependencies="3" dependenciesKind="constant"/>
```

翻译：`der(h)` 依赖 `v`（vr=3），系数是常数 1。对应的物理方程就是 `dh/dt = v`。

### 3.7.3 `InitialUnknown`：初始化时解什么

`InitialUnknown` 列出初始化阶段需要 FMU 计算的未知量。规范给出的纳入规则：

- 输出中 `initial="approx"` 或 `"calculated"` 的（clocked 变量除外）；
- `causality="calculatedParameter"` 的；
- 连续状态/状态导数中 `initial="approx"` 或 `"calculated"` 的；
- FMU 希望初始化的时钟变量。

BouncingBall 的两个导数都是 `initial="calculated"`，所以出现在列表里：

```xml
<InitialUnknown valueReference="2" dependencies="3" dependenciesKind="constant"/>
<InitialUnknown valueReference="4" dependencies="5" dependenciesKind="constant"/>
```

而 `h`、`v` 是 `initial="exact"`，由 `start` 给出，不需要作为未知量求解。

> 注意：`EventIndicator` 不能出现在 `InitialUnknown` 里。事件指示器在初始化期间可以读，但它的依赖信息只用于调试。

### 3.7.4 `EventIndicator`

```xml
<EventIndicator valueReference="1"/>
```

它指向 `h`（连续 Float64 变量）。导入端调用 `fmi3GetEventIndicators` 得到的就是这些变量（数组变量会展开）按列表顺序拼接的数组。BouncingBall 用它检测「小球是否落地」——`h` 过零就是事件。

三条规则：

- 只能引用 `Float32` / `Float64` 的 `continuous` 变量；
- 顺序决定数组顺序；
- CS 和 SE 会**忽略** `EventIndicator`（事件由 FMU 内部处理）。

---

## 3.8 用 XSD 校验

### 3.8.1 仓库脚本

仓库提供了一个 PowerShell 校验脚本，封装了 `XmlSchemaSet`：

```powershell
.\examples\scripts\validate-model-description.ps1 `
    .\examples\reference-fmus\BouncingBall\FMI3.xml
```

输出：

```text
OK: D:\...\examples\reference-fmus\BouncingBall\FMI3.xml is valid against fmi3ModelDescription.xsd
```

也可以校验解包后的真实文件：

```powershell
.\examples\scripts\validate-model-description.ps1 `
    "$env:TEMP\BouncingBall\modelDescription.xml"
```

脚本会自动加载 `docs/spec-3.0.2/schema/fmi3ModelDescription.xsd` 及其 `include` 的变量、类型、单位、注解 schema。

### 3.8.2 故意制造一个错误

把 XML 复制到临时文件，删掉 `instantiationToken` 属性，再跑一次：

```powershell
$tmp = "$env:TEMP\broken.xml"
(Get-Content "$env:TEMP\BouncingBall\modelDescription.xml" -Raw) `
    -replace 'instantiationToken="[^"]*"', '' | Set-Content $tmp -Encoding UTF8

.\examples\scripts\validate-model-description.ps1 $tmp
```

会看到类似（提示文字随系统语言变化）：

```text
broken.xml:2:2: Error: 缺少必需属性“instantiationToken”。
INVALID: 1 schema error(s)
```

行号 `2:2` 指向根元素开始处——因为缺失的是根元素属性，而不是某个子元素。

### 3.8.3 XSD 能查什么，不能查什么

| XSD 能查 | XSD 查不出 |
| --- | --- |
| 元素顺序、必需元素/属性 | `valueReference` 是否唯一 |
| 枚举取值（如 `causality`、`variability`） | `unit` 引用的 `<Unit>` 是否存在 |
| 数据类型（`xs:double`、`xs:boolean`） | `declaredType` 引用的类型是否存在 |
| 属性之间的基本约束（如 `Clock` 的必填项） | `<Dimension valueReference>` 是否指向 `UInt64` 结构参数 |
| 拼写错误导致的未知元素/属性 | `initial` 与 `start` 的搭配是否语义正确 |
| — | `modelIdentifier` 对应的二进制是否存在 |

所以「XSD 通过」只是**入场券**。第 4、5 章会讲那些 XSD 表达不了的语义规则；第 10 章以后会用真实的导入端做运行时验证。

### 3.8.4 Linux / macOS 上的等价命令

如果装了 `libxml2`：

```bash
xmllint --noout --schema docs/spec-3.0.2/schema/fmi3ModelDescription.xsd \
    examples/reference-fmus/BouncingBall/FMI3.xml
```

XSD 的 `include` 会按相对路径解析，所以要在仓库根目录执行，或保留 `schema/` 目录结构。

---

## 3.9 小结

- `modelDescription.xml` 的子元素顺序由 XSD 的 `xs:sequence` 固定，不能随意调换。
- 根元素三个必需属性：`fmiVersion`、`modelName`、`instantiationToken`；其余为元数据。
- `fmiVersion` 只写 `3.0`，无法区分补丁版本。
- 接口元素用 `modelIdentifier` 定位实现；同一 FMU 多接口时变量必须完全一致。
- 能力标志默认 `false`；存在依赖关系（序列化→状态存取、早返回→中间更新、Clock→事件模式）。
- `DefaultExperiment` 只是建议；CS 的 `stepSize` 是通信步长，ME/SE 无定义。
- `LogCategories` 是无序集合，标准分类名不可改。
- `ModelStructure` 的列表有顺序语义；`dependencies` 缺失 ≠ 空字符串；`EventIndicator` 只对 ME 有意义。
- XSD 校验能挡住结构错误，但挡不住语义错误。

---

## 习题

### 1. 顺序改错

下面这段 XML 为什么过不了 XSD？请指出至少两处顺序问题。

```xml
<fmiModelDescription fmiVersion="3.0" modelName="X" instantiationToken="t">
  <ModelVariables>...</ModelVariables>
  <CoSimulation modelIdentifier="X"/>
  <DefaultExperiment stopTime="1"/>
  <ModelStructure>...</ModelStructure>
</fmiModelDescription>
```

<details>
<summary>答案</summary>

- `CoSimulation` 必须在 `ModelVariables` 之前（接口元素排在最前）；
- `DefaultExperiment` 必须在 `ModelVariables` 之前、`LogCategories` 之后；
- `ModelStructure` 在 `ModelVariables` 之后是对的，但整体顺序仍错。

</details>

### 2. 读能力标志

根据 BouncingBall 的 `<CoSimulation>`，回答：

1. 导入端能否使用可变通信步长？
2. FMU 是否可能提前返回？如果能，导入端能否请求它提前返回？
3. 内部积分步长是多少？导入端把通信步长设为 0.005 s 合不合适？
4. 状态能否保存、恢复、序列化？

<details>
<summary>答案</summary>

1. 能，`canHandleVariableCommunicationStepSize="true"`。
2. 可能，`mightReturnEarlyFromDoStep="true"`；导入端也能通过中间更新回调请求早返回（`canReturnEarlyAfterIntermediateUpdate="true"`）。
3. 1 ms（`fixedInternalStepSize="1e-3"`）；0.005 s 是 1 ms 的 5 倍，合适。
4. 三者都支持（`canGetAndSetFMUState` 与 `canSerializeFMUState` 均为 `true`）。

</details>

### 3. 解释 `dependencies`

BouncingBall 的 `Output valueReference="1"` 写的是 `dependencies=""`。

1. 这和「不写 `dependencies` 属性」有什么区别？
2. 如果把 `der(h)` 的依赖改成 `dependencies=""`，语义上意味着什么？物理上合理吗？

<details>
<summary>答案</summary>

1. 空字符串表示依赖空集；不写表示依赖所有已知量（输入、状态、参数、时间）。
2. 意味着 `der(h)` 不依赖任何已知量，即导数恒为某个不依赖输入的表达式；但物理上 `dh/dt = v`，必须依赖状态 `v`，所以不合理。

</details>

### 4. 校验 2.0 文件

用 3.0 的 XSD 校验第 2 章解包的 FMI 2.0 `modelDescription.xml`，会发生什么？为什么？

<details>
<summary>答案</summary>

会报错。最直接的原因是根元素 `fmiVersion="2.0"` 不满足 3.0 schema 的 `3.x` 模式；此外 2.0 的 `guid`、`numberOfEventIndicators` 等属性在 3.0 schema 中也不存在。版本升级不是「改个数字」，XML 结构本身变了。

</details>

### 5. 手工检查 ModelStructure

打开 `examples/reference-fmus/Feedthrough/FMI3.xml`：

1. 数一数有多少个 `causality="output"` 的变量，多少个 `<Output>` 元素，两者是否一致？
2. `Float64_discrete_output` 的 `initial` 是什么？它为什么出现在 `InitialUnknown` 里？
3. 这个 FMU 有没有 `EventIndicator`？为什么？

<details>
<summary>答案</summary>

1. 16 个输出、16 个 `<Output>`，一一对应。
2. `initial="calculated"`；按规则，输出中 `initial` 为 `calculated` 的必须列入 `InitialUnknown`。
3. 没有。它是纯代数直通模型，没有连续状态，也没有需要检测的连续事件。

</details>

---

## 下一章

骨架已经清楚了。下一章进入 FMU 最核心的部分：`<ModelVariables>`。我们会把 `causality`、`variability`、`initial` 这三个属性彻底讲透，并解释数组、结构参数、别名和 Clock 变量。

→ [第 4 章 变量系统](04-variables.md)
