# 第 4 章 变量系统

> **第二部分：看懂描述文件 · 初稿**
> 对应规范：[2.4.7 Model Variables](../spec-3.0.2/html/index.html#ModelVariables)、[变量属性表](../spec-3.0.2/html/index.html#table-variableBase-attributes)、[causality × variability 组合](../spec-3.0.2/html/index.html#table-allowed-variability-causality-combinations)、[initial 默认值](../spec-3.0.2/html/index.html#table-definition-initial)、[数组与结构参数](../spec-3.0.2/html/index.html#Dimension)、[命名约定](../spec-3.0.2/html/index.html#namingSection)
> 预计阅读：40 分钟
> 动手时间：20 分钟

## 学习目标

读完本章，你应该能够：

1. 逐属性读懂任意一个 `<Float64>` / `<Int32>` / `<Clock>` 变量条目。
2. 说清 `causality` 与 `variability` 的组合规则，并能判断一个组合是否合法。
3. 在没写 `initial` 时，推断出它的默认值，并判断 `start` 是否允许出现。
4. 解释 `derivative`、`reinit`、`Alias`、`previous` 的作用。
5. 读懂数组变量和结构参数，知道数组在内存里的排列顺序。
6. 知道 Clock 变量与普通变量的区别（细节留到第 9 章）。

---

## 4.1 从一行变量开始

把 BouncingBall 里最复杂的一行单独拿出来：

```xml
<Float64
  name="h"
  valueReference="1"
  causality="output"
  variability="continuous"
  initial="exact"
  declaredType="Position"
  start="1"
  reinit="true"
  description="Position of the ball"
  intermediateUpdate="true">
  <Alias name="h_ft" description="Position in feet" displayUnit="ft"/>
</Float64>
```

| 部分 | 值 | 含义 |
| --- | --- | --- |
| 元素名 | `Float64` | 变量类型是 64 位浮点 |
| `name` | `h` | 变量名，全 FMU 唯一 |
| `valueReference` | `1` | C API 里用的句柄，全 FMU 唯一 |
| `causality` | `output` | 由 FMU 计算，供导入端读取 |
| `variability` | `continuous` | 连续时间内可变化 |
| `initial` | `exact` | 初始值精确等于 `start` |
| `declaredType` | `Position` | 引用 `<TypeDefinitions>` 里的类型 |
| `start` | `1` | 初始高度 1 m |
| `reinit` | `true` | ME 中允许在事件时刻重置该状态 |
| `intermediateUpdate` | `true` | CS 中间更新时可读 |
| `<Alias name="h_ft" displayUnit="ft">` | — | 同一变量的英尺别名 |

把这张表记住，剩下的变量条目都是它的变体。

---

## 4.2 变量类型一览

`ModelVariables` 里可以出现的元素：

| XML 元素 | C 类型 | `start` 写法 | 说明 |
| --- | --- | --- | --- |
| `Float32` | `float` | 数值或数值列表 | IEEE 754 单精度 |
| `Float64` | `double` | 数值或数值列表 | IEEE 754 双精度 |
| `Int8` / `UInt8` | `int8_t` / `uint8_t` | 整数列表 | — |
| `Int16` / `UInt16` | `int16_t` / `uint16_t` | 整数列表 | — |
| `Int32` / `UInt32` | `int32_t` / `uint32_t` | 整数列表 | — |
| `Int64` / `UInt64` | `int64_t` / `uint64_t` | 整数列表 | `UInt64` 也用于结构参数 |
| `Boolean` | `bool` | `true` / `false` / `1` / `0` | — |
| `String` | `fmi3String` | `<Start value="..."/>` 序列 | UTF-8 |
| `Binary` | `fmi3Binary` | `<Start value="hex"/>` 序列 | 十六进制编码 |
| `Enumeration` | 通过 `fmi3Int64` 读写 | 整数 | 必须有 `declaredType` |
| `Clock` | `fmi3Clock` | 不适用 | 时钟变量，见 4.11 |

两个容易记错的点：

- **Enumeration 没有独立的 getter/setter**。规范要求用 `fmi3GetInt64` / `fmi3SetInt64` 读写，因为 C 的 `enum` 位宽由编译器决定，只有 64 位整数才跨平台一致。
- **Boolean 在 XML 里可以写 `1` / `0`**，但 C API 里用 `fmi3True` / `fmi3False`。

---

## 4.3 `valueReference`：变量的身份证

```xml
<Float64 name="v" valueReference="3" .../>
```

规则只有三条，但每条都很关键：

1. **全 FMU 唯一**，包括所有类型、所有接口。
2. **数组只占一个** `valueReference`，整个数组共用这个句柄。
3. **别名没有自己的** `valueReference`，它和主变量共享。

`valueReference` 的类型是 `uint32`（`fmi3ValueReference`），所以上限是 4294967295。BouncingBall 用了 0–7 的连续编号；`time` 习惯上写 0，但规范**没有**规定 0 必须给时间。不要写依赖这个约定的代码。

> 为什么不用变量名？因为 C API 每次调用都传字符串会非常慢，而且名称可能很长、包含 Unicode。整数句柄更适合高频调用。

---

## 4.4 `causality`：谁负责给值

`causality` 默认是 `local`。七个取值：

| 值 | 谁设值 | 典型用途 | 能否跨 FMU 连接 |
| --- | --- | --- | --- |
| `parameter` | 导入端/用户，初始化时 | 质量、增益、初始条件 | 不用于连接（终端参数传播除外） |
| `calculatedParameter` | FMU，初始化时或 tunable 参数变化后 | 由参数推导出的常量 | 不用于连接 |
| `input` | 导入端 | 来自其他 FMU 的信号 | 可以 |
| `output` | FMU | 提供给外部的信号 | 可以 |
| `local` | FMU | 状态、导数、内部中间量 | 不可以 |
| `independent` | 导入端（通过时间推进函数） | 通常是 `time` | 不可以 |
| `structuralParameter` | 导入端，仅在配置/重配置模式 | 数组维度 | 不用于连接 |

几条硬规则：

- **有且只有一个** `independent` 变量，必须是浮点类型，且**不能有 `start`**。
- 连续状态和事件指示器只能是 `local` 或 `output`。
- Clock 变量的 `causality` 只能是 `input`、`output` 或 `local`。
- `local` 变量的值不能作为其他 FMU 的输入；它只供调试读取。
- `parameter` 与 `calculatedParameter` 的区别：前者由外部给，后者由 FMU 算。`calculatedParameter` 不能单独改变，它跟着依赖的参数走。

BouncingBall 里：

```xml
<Float64 name="g" causality="parameter" variability="fixed" start="-9.81"/>
<Float64 name="e" causality="parameter" variability="tunable" start="0.7"/>
```

`g` 是固定参数（仿真中不能改），`e` 是可调参数（事件时刻可以改）。两者的区别就体现在 `variability` 上。

---

## 4.5 `variability`：什么时候可以变

| 值 | 含义 |
| --- | --- |
| `constant` | 永不改变 |
| `fixed` | 退出初始化后不再改变 |
| `tunable` | 事件之间/通信点之间不变，但可在事件或通信点改变 |
| `discrete` | 只在事件时刻（ME）或通信点（CS/SE）改变 |
| `continuous` | 连续变化；**只允许 Float32/Float64** |

默认值不是一句话能说完的，规范按「类型 + causality」分别规定：

| 情况 | 默认 `variability` |
| --- | --- |
| `parameter` / `structuralParameter` / `calculatedParameter` | `fixed` |
| `input` / `output` / `local`，且类型不是 Float32/Float64 | `discrete` |
| Float32/Float64，且 causality 不是上面三类 | `continuous` |

所以 BouncingBall 的 `v_min` 只写了 `variability="constant"`，`causality` 省略后默认 `local`；而 `g`、`e` 省略 `variability` 也不行——它们是 `parameter`，默认会是 `fixed`，其中 `e` 想要可调就必须显式写 `tunable`。

> 记忆法：**causality 决定「谁给值」，variability 决定「什么时候能变」**。两者独立但必须组合合法。

---

## 4.6 组合矩阵与 `initial`

### 4.6.1 哪些组合合法

规范给出了完整的 `variability × causality` 矩阵。下面用 ✓ 表示允许，— 表示不允许：

| variability ↓ \ causality → | structuralParameter | parameter | calculatedParameter | input | output | local | independent |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `constant` | — | — | — | — | ✓ | ✓ | — |
| `fixed` | ✓ | ✓ | ✓ | — | — | ✓ | — |
| `tunable` | ✓ | ✓ | ✓ | — | — | ✓ | — |
| `discrete` | — | — | — | ✓ | ✓ | ✓ | — |
| `continuous` | — | — | — | ✓ | ✓ | ✓ | ✓ |

几个「为什么不允许」值得理解，而不是死记：

- `constant` 配 `parameter` / `input` 没有意义：后两者由外部设值，前者永不变。
- `fixed` / `tunable` 配 `input` 等同于参数，规范为了简化只保留 `parameter`。
- `fixed` / `tunable` 配 `output` 等同于 `calculatedParameter`，同理。
- `discrete` / `continuous` 配参数类 causality 矛盾：参数不随时间变。

### 4.6.2 `initial` 的三个值

| 值 | 含义 | `start` 是否必需 |
| --- | --- | --- |
| `exact` | 初始值就是 `start`；导入端可以改 | 必需 |
| `approx` | `start` 是代数环迭代的初值猜测 | 必需 |
| `calculated` | 由 FMU 在初始化时算出 | **禁止** |

### 4.6.3 不写 `initial` 时的默认值

| variability | structuralParameter | parameter | calculatedParameter | input | output | local |
| --- | --- | --- | --- | --- | --- | --- |
| `constant` | — | — | — | — | `exact` | `exact` |
| `fixed` | `exact` | `exact` | `calculated` | — | — | `calculated` |
| `tunable` | `exact` | `exact` | `calculated` | — | — | `calculated` |
| `discrete` | — | — | — | `exact` | `calculated` | `calculated` |
| `continuous` | — | — | — | `exact` | `calculated` | `calculated` |

`independent` 不允许有 `initial`。

用这张表检查 BouncingBall：

| 变量 | causality | variability | 未写 initial 时的默认值 | 实际写法 | 结论 |
| --- | --- | --- | --- | --- | --- |
| `time` | independent | continuous | 不允许 | 未写 | ✓ |
| `h` | output | continuous | calculated | `exact` | 显式覆盖，合法 |
| `der(h)` | local | continuous | calculated | `calculated` | 与默认一致 |
| `g` | parameter | fixed | exact | `exact` | 与默认一致 |
| `v_min` | local（默认） | constant | exact | 未写 | 默认即 exact，所以 `start` 合法 |

注意 `v_min` 这一行：它省略了 `causality` 和 `initial`，只写了 `variability="constant"` 和 `start="0.1"`。如果误以为「没写 initial 就不能有 start」，就会把合法文件判成非法。

### 4.6.4 `start` 的硬规则

- `initial="exact"` 或 `"approx"` → 必须有 `start`；
- `initial="calculated"` → 不能有 `start`；
- `causality="independent"` → 不能有 `start`；
- `causality="parameter"` / `"input"` 或 `variability="constant"` → 必须有 `start`；
- 参数和常量的 `start` 就是默认值/常量值；输入的 `start` 是「导入端没设值时」的兜底值。

数组的 `start` 如果只给一个值，会广播到所有元素。

---

## 4.7 `derivative` 与 `reinit`

### 4.7.1 `derivative`：把导数和状态配对

BouncingBall：

```xml
<Float64 name="der(h)" valueReference="2" derivative="1" .../>
<Float64 name="der(v)" valueReference="4" derivative="3" .../>
```

`derivative="1"` 表示「本变量是 vr=1 的变量的导数」。于是：

- `h`（vr=1）是连续状态；
- `der(h)`（vr=2）是它的导数；
- `v`（vr=3）也是连续状态；
- `der(v)`（vr=4）是 `v` 的导数。

状态向量和导数向量的顺序由 `ModelStructure` 决定，不由变量表顺序决定：

```xml
<ContinuousStateDerivative valueReference="2"/>
<ContinuousStateDerivative valueReference="4"/>
```

这条规则在写导入端时极其重要：`fmi3GetContinuousStates` 返回的数组就是 `[h, v]`，因为这里先列 2 再列 4。

### 4.7.2 `reinit`：ME 的事件重置

`reinit="true"` 只对**连续状态**有意义，且只在 Model Exchange 中使用，其他接口忽略。

它告诉导入端：这个状态可以在事件时刻被 FMU 重置。BouncingBall 的 `h` 和 `v` 都是 `reinit="true"`，因为落地反弹时速度会突变；但 `h` 的位置本身在碰撞瞬间不变——`reinit` 是「允许重置」，不是「一定重置」。

---

## 4.8 `Alias`：同一变量的另一个名字

```xml
<Float64 name="h" valueReference="1" ...>
  <Alias name="h_ft" description="Position in feet" displayUnit="ft"/>
</Float64>
```

规则：

- 别名**没有** `valueReference`，读写它等同读写主变量；
- 别名 `name` 必须在「所有变量名 + 所有别名」中唯一；
- 只有浮点变量的别名可以带 `displayUnit`；
- 别名可以有自己的 `description`。

`h_ft` 不是一个独立的英尺变量，它只是 `h` 的另一个显示入口。导入端如果支持单位换算，可以按 `displayUnit` 把值从 `m` 显示成 `ft`；但通过 C API 读到的仍然是米。

> 别名的典型用途：兼容旧变量名、提供单位别名、给长路径名一个短名字。不要用它表达「不同的物理量」。

---

## 4.9 数组变量与结构参数

### 4.9.1 `<Dimension>` 的两种写法

数组变量在变量元素里放一个或多个 `<Dimension>`：

```xml
<!-- 固定长度：3 个元素 -->
<Float64 name="gain" valueReference="10" start="1 1 1">
  <Dimension start="3"/>
</Float64>

<!-- 可变长度：长度由结构参数 len 决定 -->
<UInt64 name="len" valueReference="100" causality="structuralParameter"
        variability="fixed" start="7"/>
<Float32 name="V" valueReference="1" causality="parameter" variability="tunable"
         start="0.1 -0.2 0.3 -0.4 0.5 -0.6 0.7">
  <Dimension valueReference="100"/>
</Float32>
```

规则：

- `start` 和 `valueReference` 二选一，不能同时出现；
- `valueReference` 必须指向 `UInt64` 类型的变量，且该变量必须是 `constant` 或 `structuralParameter`；
- 结构参数如果被 `<Dimension>` 引用，它的 `start` 必须大于 0；
- 初始维度必须为正（不能是 0），避免「一开始就消失的数组」；
- 修改维度会使该变量的当前值（包括 `start`）失效。

### 4.9.2 结构参数：运行时可变的维度

`causality="structuralParameter"` 是 FMI 3.0 新增的。它和普通参数的区别：

| | 普通 parameter | structuralParameter |
| --- | --- | --- |
| 改变时机 | 初始化、事件（tunable） | 只能在 ConfigurationMode / ReconfigurationMode |
| 是否影响数组维度 | 否 | 可以 |
| 类型限制 | 任意 | 被 Dimension 引用时必须是 `UInt64` |
| `start` | 参数必需 | 必需 |
| `min` / `max` | 可选 | 可选；被引用时 `min` 可以为 0 |

`variability` 决定能改几次：

- `fixed`：只能在 ConfigurationMode 改（实例化后、初始化前）；
- `tunable`：还能在 ReconfigurationMode 改（仿真过程中）。

### 4.9.3 StateSpace：一个真实的二维数组

`examples/reference-fmus/StateSpace/FMI3.xml`：

```xml
<UInt64 name="m" valueReference="1" causality="structuralParameter" variability="tunable" start="3" min="0" max="5"/>
<UInt64 name="n" valueReference="2" causality="structuralParameter" variability="tunable" start="3" min="0" max="5"/>
<UInt64 name="r" valueReference="3" causality="structuralParameter" variability="tunable" start="3" min="0" max="5"/>

<Float64 name="A" valueReference="4" causality="parameter" variability="tunable"
         start="1 0 0 0 1 0 0 0 1">
  <Dimension valueReference="2"/>
  <Dimension valueReference="2"/>
</Float64>
```

`A` 的两个维度都指向 `n`（vr=2），默认 `n=3`，所以是 3×3 矩阵，`start` 给出 9 个数。

### 4.9.4 数组在内存里的顺序

规范规定：**行优先（row major）**，维度顺序由 `<Dimension>` 元素的顺序决定。

一个 3×2 矩阵

```text
A = [ a11 a12
      a21 a22
      a31 a32 ]
```

序列化为：

```text
a11 a12 a21 a22 a31 a32
```

也就是 C 里的 `A[0][0] A[0][1] A[1][0] ...`。`start="1 0 0 0 1 0 0 0 1"` 对应的就是单位矩阵。

> 这条规则在导入端做「按名字取数组元素」时经常用错。记住：XML 里的顺序 = C 数组的内存顺序 = 行优先。

---

## 4.10 `String` 与 `Binary` 的 `start`

字符串和二进制不能用空格分隔的列表，而要用 `<Start>` 元素：

```xml
<String name="String_input" valueReference="29" causality="input">
  <Start value="Set me!"/>
</String>

<Binary name="Binary_input" valueReference="31" causality="input">
  <Start value="666f6f"/>
</Binary>
```

- `String` 的 `value` 是 UTF-8 文本；
- `Binary` 的 `value` 是十六进制字符串（`666f6f` = ASCII `foo`）；
- 数组字符串/二进制按元素顺序写多个 `<Start>`；
- `Binary` 还可以用 `maxSize` 声明最大字节数（`BinaryType` 或变量上均可）。

Spec 里的数组例子：

```xml
<String name="strings" valueReference="1" causality="parameter" variability="tunable">
  <Dimension start="3"/>
  <Start value="First string"/>
  <Start value="Second string"/>
  <Start value="Third string"/>
</String>
```

---

## 4.11 Clock 变量速览

Clock 是 FMI 3.0 的重点，完整内容在第 9 章。这里先认识它的 XML 形态，避免在第 3、4 章读到 Clock 时卡住。

`Clocks` 模型（`examples/reference-fmus/Clocks/FMI3.xml`）：

```xml
<Clock name="inClock1" valueReference="1001" causality="input"
       intervalVariability="constant" intervalDecimal="1.0" priority="0"/>
<Clock name="inClock2" valueReference="1002" causality="input"
       intervalVariability="triggered" priority="1"/>
<Clock name="inClock3" valueReference="1003" causality="input"
       intervalVariability="countdown" priority="2" clocks="1001"/>
<Clock name="outClock" valueReference="1005" causality="output"
       intervalVariability="triggered" clocks="1001 1002 1003"/>
<Int32 name="inClock1Ticks" valueReference="2001" causality="output" clocks="1001"/>
```

要点：

- `<Clock>` 是独立变量类型，`intervalVariability` **必填**（`constant` / `fixed` / `tunable` / `changing` / `countdown` / `triggered`）；
- `priority` 只对 SE 的输入 Clock 强制，数值越小优先级越高；输出 Clock 不允许写 `priority`；
- 普通变量用 `clocks="1001 1002"` 声明自己属于哪些 Clock；
- `<Clock>` 的 `variability` 如果显式写出，必须是 `discrete`；通常直接省略（Clock 不是 Float32/Float64，默认就是 `discrete`）；
- Clock 变量不能有 `start`、`intermediateUpdate`、`previous`；
- `previous` 用于 ClockedState：指向保存「上一拍值」的变量。

Clocks 这个 FMU 只声明了 `<ScheduledExecution>`，所以它是学习 SE 的最佳样本。

---

## 4.12 命名约定

根元素的 `variableNamingConvention` 有两个取值：

| 值 | 规则 | 例子 |
| --- | --- | --- |
| `flat`（默认） | 任意 Unicode 字符串，不能含换行/制表符 | `der(h)`、`h_ft`、`速度` |
| `structured` | 用 `.` 分层；支持数组下标和 `der(name)` | `vehicle.engine.speed`、`der(pipe[3,4].T[14],2)` |

`structured` 的语法和 Modelica 标识符基本一致：

```text
vehicle.engine.speed
resistor12.u
robot.axis.'motor #234'
der(pipe[3,4].T[14],2)   // 二阶导数
```

注意：

- `structured` 不规定数组下标从 0 还是 1 开始；
- `flat` 只是「不分层」，不代表名字必须短；
- BouncingBall 用的是默认 `flat`，所以 `der(h)` 只是一个普通名字，不是语法结构。

导入端可以根据 `structured` 把变量名显示成树形，但**不能**假设所有 FMU 都是结构化的。

---

## 4.13 动手实验

### 实验 4-1：把变量表打印成表格

用 PowerShell 直接读 XML（不需要解包 FMU）：

```powershell
[xml]$xml = Get-Content .\examples\reference-fmus\BouncingBall\FMI3.xml

$xml.fmiModelDescription.ModelVariables.ChildNodes |
    Select-Object @{n='Type';e={$_.LocalName}},
                  @{n='Name';e={$_.name}},
                  @{n='VR';e={$_.valueReference}},
                  @{n='Causality';e={$_.causality}},
                  @{n='Variability';e={$_.variability}},
                  @{n='Initial';e={$_.initial}},
                  @{n='Start';e={$_.start}} |
    Format-Table -AutoSize
```

你会看到默认值显示为空——PowerShell 只读 XML，不会替你补默认值。把 4.6 节的默认值表填进空白列，就是实验的答案。

### 实验 4-2：给 Feedthrough 分类

打开 `examples/reference-fmus/Feedthrough/FMI3.xml`，回答：

1. 有多少个 `Float64` 变量？其中哪些是 `parameter`？
2. `Float32_discrete_input` 的 `variability` 是什么？如果删掉这个属性，默认会变成什么？
3. `Boolean_output` 的 `initial` 是什么？它需要 `start` 吗？
4. `Enumeration_input` 的 `declaredType` 指向哪个类型？它允许取哪些值？

<details>
<summary>参考答案</summary>

1. 7 个 `Float64`；`Float64_fixed_parameter` 和 `Float64_tunable_parameter` 是参数。
2. `discrete`；删掉后按「Float32 + input」默认是 `continuous`。
3. `calculated`；不需要 `start`，而且禁止提供。
4. `Option`；允许 `1`（Option 1）和 `2`（Option 2），类型定义里没有 `min`/`max` 限制。

</details>

### 实验 4-3：找出「默认值陷阱」

下面三行都来自真实 FMU，判断它们是否合法，并说明理由：

```xml
<Float64 name="a" causality="output" start="1"/>
<Float64 name="b" causality="output" variability="discrete" start="1"/>
<Float64 name="c" causality="parameter" initial="calculated" start="1"/>
```

<details>
<summary>答案</summary>

1. `a`：output + Float64 → 默认 variability=continuous，默认 initial=calculated，而 `calculated` 禁止 `start` → **非法**。
2. `b`：discrete output 默认 initial=calculated，同样禁止 `start` → **非法**；若要 `start` 必须写 `initial="exact"` 或 `"approx"`。
3. `c`：`initial="calculated"` 与 `start` 互斥 → **非法**。

</details>

### 实验 4-4：读数组

打开 `StateSpace/FMI3.xml`：

1. `A`、`B`、`C`、`D` 各是几行几列（默认结构参数下）？
2. `x0` 的 `start` 有几个值？
3. 如果把 `n` 的 `start` 从 3 改成 2，哪些数组会变？`start` 列表会怎样？

<details>
<summary>答案</summary>

1. `A`: 3×3；`B`: 3×3（n×m）；`C`: 3×3（r×n）；`D`: 3×3（r×m）。
2. 3 个（`0 0 0`）。
3. 受 `n` 影响的维度会变成 2：`A` 变成 2×2，`B` 变成 2×3，`C` 变成 3×2，`x0` / `x` / `der(x)` 变成长度 2。这些变量的原 `start` 列表长度与新维度不匹配，重配置后必须重新设置值。

</details>

---

## 4.14 小结

- 变量类型有 15 种元素；Enumeration 用 `fmi3GetInt64`/`fmi3SetInt64` 读写。
- `valueReference` 全 FMU 唯一；数组共用一个；别名没有自己的。
- `causality` 决定谁设值，`variability` 决定何时能变；组合必须落在合法矩阵内。
- `initial` 有 `exact` / `approx` / `calculated`；默认值取决于 causality 和 variability。
- `start` 与 `initial` 的搭配有硬规则；`independent` 和 `calculated` 禁止 `start`。
- `derivative` 配对状态与导数；状态顺序由 `ModelStructure` 决定。
- `reinit` 只用于 ME 的连续状态。
- 别名共享值，浮点别名可带 `displayUnit`。
- 数组用 `<Dimension>` 声明；行优先序列化；结构参数控制运行时维度。
- Clock 是独立类型，`intervalVariability` 必填；细节见第 9 章。

---

## 习题

### 1. 判断合法性

对下列组合判断是否允许（不考虑 `start`）：

1. `constant` + `parameter`
2. `fixed` + `calculatedParameter`
3. `tunable` + `input`
4. `discrete` + `local`
5. `continuous` + `independent`

<details>
<summary>答案</summary>

1. 不允许；2. 允许；3. 不允许；4. 允许；5. 允许（且 independent 必须是 continuous）。

</details>

### 2. 推断默认值

```xml
<Int32 name="mode" valueReference="9" causality="input"/>
```

1. `variability` 默认是什么？
2. `initial` 默认是什么？
3. 是否必须有 `start`？

<details>
<summary>答案</summary>

1. `discrete`（非浮点 + input）。
2. `exact`（discrete input）。
3. 是（`initial="exact"` 且 causality=input 都要求 `start`）。

</details>

### 3. 数组序列化

一个变量声明为：

```xml
<Float64 name="M" valueReference="20" start="1 2 3 4 5 6">
  <Dimension start="3"/>
  <Dimension start="2"/>
</Float64>
```

1. 这是几行几列？
2. `M[1][0]`（C 下标，行优先）的值是多少？
3. 如果交换两个 `<Dimension>` 的顺序，含义会变吗？

<details>
<summary>答案</summary>

1. 3 行 2 列。
2. 第 2 行第 1 列 = 第 4 个数 = 4。
3. 会。维度顺序参与行优先展开，交换后变成 2 行 3 列，元素对应关系改变。

</details>

### 4. 找出多余属性

下面哪一行违反规范？为什么？

```xml
<Float64 name="x" valueReference="1" causality="calculatedParameter" variability="fixed" start="0"/>
<Float64 name="y" valueReference="2" causality="independent" variability="continuous" start="0"/>
<Float64 name="z" valueReference="3" causality="output" variability="continuous" initial="exact" start="0"/>
```

<details>
<summary>答案</summary>

第一行与第二行都非法。第一行 `calculatedParameter` + `fixed` 默认 `initial="calculated"`，因此不允许带 `start`；要带 `start` 必须显式写 `initial="exact"`（或 `approx`，如果某处确实把它当未知量初值）。第二行 `independent` 不允许有 `start`。第三行合法。

</details>

### 5. 设计一个变量表

为一个「电池模型」设计最小变量表，要求：

- 一个独立时间变量；
- 两个参数：容量（可调）、初始 SOC（固定）；
- 一个输入：电流；
- 两个输出：电压、SOC；
- 一个常量：最大电压。

写出每个变量的类型、causality、variability、initial 和 start（如需要）。

<details>
<summary>参考设计</summary>

```xml
<Float64 name="time" valueReference="0" causality="independent" variability="continuous"/>
<Float64 name="capacity" valueReference="1" causality="parameter" variability="tunable" initial="exact" start="50"/>
<Float64 name="soc0" valueReference="2" causality="parameter" variability="fixed" initial="exact" start="1"/>
<Float64 name="current" valueReference="3" causality="input" variability="continuous" initial="exact" start="0"/>
<Float64 name="voltage" valueReference="4" causality="output" variability="continuous" initial="calculated"/>
<Float64 name="soc" valueReference="5" causality="output" variability="continuous" initial="exact" start="1"/>
<Float64 name="v_max" valueReference="6" variability="constant" start="4.2"/>
```

`soc` 是状态，初始值由 `soc0` 决定；如果不想暴露 `soc0`，也可以把 `soc` 的 `start` 直接写成 1。`v_max` 省略 causality，默认 local，是合法的 constant/local 组合。

</details>

---

## 下一章

变量条目里的 `declaredType`、`unit`、`displayUnit` 都指向第 3 章见过的「字典」。下一章把 `UnitDefinitions`、`TypeDefinitions`、注解和终端讲清楚，并给出一份可执行的 XML 一致性检查清单。

→ [第 5 章 单位、类型与注解](05-units-types-annotations.md)
