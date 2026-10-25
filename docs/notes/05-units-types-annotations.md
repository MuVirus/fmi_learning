# 第 5 章 单位、类型与注解

> **第二部分：看懂描述文件 · 初稿**
> 对应规范：[2.4 FMI Description Schema](../spec-3.0.2/html/index.html#modelDescription.xml)、[2.4.3 Physical Units](../spec-3.0.2/html/index.html#table-unit-examples)、[2.4.4 Variable Types](../spec-3.0.2/html/index.html#definition-of-types)、[Annotations](../spec-3.0.2/html/index.html#Annotations)、[2.4.9 Terminals and Icons](../spec-3.0.2/html/index.html#fmiTerminalsAndIcons)
> 预计阅读：45 分钟
> 动手时间：25 分钟

## 学习目标

读完本章，你应该能够：

1. 用 `<UnitDefinitions>` 描述一个物理单位，并手算 `BaseUnit` 的换算。
2. 用 `<DisplayUnit>` 处理 °F、mpg 这类带 offset 或倒数的显示单位。
3. 判断两个 FMU 的变量能不能直接连接，什么时候必须做单位换算。
4. 定义 `<TypeDefinitions>`，并解释 `declaredType` 的「类型提供默认值、变量可以覆盖」规则。
5. 正确使用 `<EnumerationType>`，知道枚举在 C API 里怎么读写。
6. 用 `<Annotations>` 做供应商扩展，同时理解「可安全忽略」的边界。
7. 读懂可选的 `terminalsAndIcons/terminalsAndIcons.xml`。
8. 用仓库里的两个脚本做**结构校验**和**语义检查**，并知道它们各自查不出什么。

第 3 章讲了文件的骨架，第 4 章讲了变量。本章补上变量条目里那些「指向别处」的属性：`unit`、`displayUnit`、`declaredType`，以及不属于变量表的扩展信息。

---

## 5.1 为什么单位要写成指数

先看一个真实场景：两个 FMU 要连接，一个输出「压力」，单位写 `bar`；另一个输入「压力」，单位写 `Pa`。导入端怎么知道它们能连？

如果单位只是一个字符串，答案只能是「比较字符串」——`bar` ≠ `Pa`，于是拒绝连接，哪怕物理量完全兼容。更糟的是 FMI 1.0 时代同一个单位可能写成 `N.m`、`N*m`、`N m` 三种形式，字符串比较直接失效。

FMI 3.0 的解法是：**每个单位都映射到一组 SI 基本单位的指数**。`bar` 和 `Pa` 的指数完全一样（`kg·m⁻¹·s⁻²`），只是 `factor` 不同；导入端一比指数就知道「这是同一种量纲」，再决定要不要乘系数。

```
量纲（指数）  →  判断能不能连
factor/offset →  判断要不要换算
quantity      →  区分同量纲的不同物理量（可选）
```

这三个层次分别由 `BaseUnit`、`factor`/`offset`、`quantity` 承担。理解这个分层，后面的规则就都是自然的。

---

## 5.2 `UnitDefinitions` 的骨架

`UnitDefinitions` 是根元素下的可选块，里面是一个或多个 `<Unit>`：

```xml
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
```

这是 BouncingBall 的完整定义（`examples/reference-fmus/BouncingBall/FMI3.xml`）。

XSD 里 `<Unit>` 的子元素顺序同样固定（`fmi3Unit.xsd`）：

```text
BaseUnit?  →  DisplayUnit*  →  Annotations?
```

注意两个容易写错的地方：

- `BaseUnit` 是**可选**的。像 `Euro/PersonYear` 这种无法映射到 SI 的单位，可以只写 `<Unit name="Euro/PersonYear"/>`，不写 `BaseUnit`。
- `Annotations` 在 `<Unit>` 里只能出现在最后（所有 `DisplayUnit` 之后）。写成 `<Unit><Annotations/>…<BaseUnit/>…</Unit>` 会被 XSD 拒绝。

### 5.2.1 `BaseUnit` 的八个指数

| 属性 | 对应基本单位 | 典型指数 |
| --- | --- | --- |
| `kg` | 千克（质量） | 力 `kg·m·s⁻²` 中为 1 |
| `m` | 米（长度） | 速度 `m·s⁻¹` 中为 1 |
| `s` | 秒（时间） | 速度中为 -1 |
| `A` | 安培（电流） | 电荷 `A·s` 中为 1 |
| `K` | 开尔文（温度） | 温度中为 1 |
| `mol` | 摩尔（物质的量） | — |
| `cd` | 坎德拉（光强） | — |
| `rad` | 弧度（角度） | 角速度 `rad·s⁻¹` 中为 1 |

规范在七个 SI 基本单位之外**额外**定义了 `rad`。原因很实际：工程里大量量（转速、角加速度、角频率）都带角度，如果强制把 `rad` 当作无量纲，`Hz` 和 `rad/s` 就会混为一谈。加上 `rad` 之后：

- `rad/s` 的指数是 `s=-1, rad=1`；
- `Hz` 的指数是 `s=-1, rad=1`，`factor=2π`；
- 做量纲分析时，规范要求把 `rad` 当作 `1`，所以两者又能互相校验。

### 5.2.2 换算公式

`Unit` 里的值 `v_unit` 换算到 `BaseUnit` 的值 `v_base`：

```text
v_base = factor * v_unit + offset        （relativeQuantity = false）
v_base = factor * v_unit                 （relativeQuantity = true，忽略 offset）
```

`factor` 和 `offset` 都是 `<BaseUnit>` 的属性，默认分别是 `1` 和 `0`。

`relativeQuantity` 是 `<Float32Type>` / `<Float64Type>` 以及浮点变量上的属性，默认 `false`。它表达的是「这是差值，不是绝对量」：

- 绝对温度 10 °C = 283.15 K；
- 温差 10 °C = 10 K。

如果 `relativeQuantity="true"`，计算时就必须忽略 offset，否则温差会被错误地加上 273.15。规范还要求 `displayUnit` 的 offset 也一并忽略。

> 变量上的 `relativeQuantity` 会覆盖类型定义里的值。同一个 `Temperature` 类型，既可以派生出绝对温度变量，也可以派生出温差变量。

---

## 5.3 常见单位换算表

规范在 [`table-unit-examples`](../spec-3.0.2/html/index.html#table-unit-examples) 里给了一组标准例子。下面按「1 个该单位等于多少基准单位」重写，方便手算：

| 物理量 | `Unit.name` | `BaseUnit` 指数 | `factor` | `offset` | 含义 |
| --- | --- | --- | --- | --- | --- |
| 力矩 | `N.m` | `kg=1, m=2, s=-2` | `1` | `0` | 1 N·m = 1 kg·m²/s² |
| 能量 | `J` | `kg=1, m=2, s=-2` | `1` | `0` | 与 N·m 同量纲 |
| 压力 | `bar` | `kg=1, m=-1, s=-2` | `1e5` | `0` | 1 bar = 100000 Pa |
| 角度 | `deg` | `rad=1` | `0.01745329251994330` | `0` | 1° = π/180 rad |
| 角速度 | `rad/s` | `rad=1, s=-1` | `1` | `0` | 基准 |
| 角速度 | `rpm` | `rad=1, s=-1` | `0.1047197551196598` | `0` | 1 rpm = 2π/60 rad/s |
| 频率 | `Hz` | `rad=1, s=-1` | `6.283185307179586` | `0` | 1 Hz = 2π rad/s |
| 温度 | `°F` | `K=1` | `0.5555555555555556` | `255.3722222222222` | 5/9 与 273.15−32·5/9 |
| 百分比/长度 | `%/m` | `m=-1` | `0.01` | `0` | 1 %/m = 0.01 /m |
| 百万分率 | `ppm` | 全零（无量纲） | `1e-6` | `0` | 1 ppm = 1e-6 |
| 长度 | `km` | `m=1` | `1000` | `0` | 1 km = 1000 m |
| 长度 | `yd` | `m=1` | `0.9144` | `0` | 1 yd = 0.9144 m |

三个手算例子：

**bar → Pa**

```text
p_Pa = 1e5 * p_bar + 0
p_bar = 2  →  p_Pa = 200000 Pa
```

**rpm → rad/s**

```text
ω_rad/s = 0.1047197551196598 * ω_rpm
ω_rpm = 3000  →  ω_rad/s ≈ 314.159 rad/s
```

这正好是 `3000 * 2π / 60`，也就是 50 转/秒对应的角速度。

**°F → K**

```text
T_K = (5/9) * T_F + 255.3722222222222
T_F = 32   →  T_K = 17.7778 + 255.3722 = 273.15 K
T_F = 212  →  T_K = 117.7778 + 255.3722 = 373.15 K
```

注意 `255.3722...` 不是 273.15。它来自把冰点 32 °F 对齐到 273.15 K：`273.15 - 32 * 5/9`。

---

## 5.4 `DisplayUnit`：给人看的单位

`<DisplayUnit>` 定义「同一个量在界面上用什么单位显示」，它属于某个 `<Unit>`：

```xml
<Unit name="rad/s">
  <BaseUnit s="-1" rad="1"/>
  <DisplayUnit name="deg/s" factor="57.29577951308232"/>
  <DisplayUnit name="rev/min" factor="9.549296585513721"/>
</Unit>
```

换算公式：

```text
v_display = factor * v_unit + offset        （inverse = false）
v_display = factor / v_unit                 （inverse = true）
```

`inverse="true"` 用于「越大越小」的量，比如油耗 `L/100km` 与 `mpg`：

```xml
<Unit name="L/100km">
  <BaseUnit m="2" factor="1e-8"/>
  <DisplayUnit name="mpg" inverse="true" factor="235.214583"/>
</Unit>
```

换算：

```text
mpg = 235.214583 / (L/100km)
5 L/100km  →  47.04 mpg
```

为什么 `L/100km` 的 `BaseUnit` 是 `m=2`？因为 `1 L / 100 km = 1e-3 m³ / 1e5 m = 1e-8 m²`。这就是「面积」量纲，和 `mpg`（英里/加仑）一致。

约束：

- `inverse="true"` 只允许在 `offset="0"` 时使用。倒数和偏移组合没有明确语义，规范直接禁止。
- `DisplayUnit.name` 在同一个 `<Unit>` 内必须唯一；不同 `<Unit>` 之间可以重名。
- `name` 只是显示用的标签，导入端不应尝试解析它。

### 5.4.1 温度显示：°F 是 DisplayUnit

绝对温度用 K 作为 `Unit`，°F 既可以作为 `Unit`（见 5.3），也可以作为 `DisplayUnit`：

```xml
<Unit name="K">
  <BaseUnit K="1"/>
  <DisplayUnit name="degC" factor="1" offset="-273.15"/>
  <DisplayUnit name="degF" factor="1.8" offset="-459.67"/>
</Unit>
```

换算：

```text
T_degC = 1 * T_K - 273.15
T_degF = 1.8 * T_K - 459.67
```

验证：`T_K = 273.15` → `T_degF = 491.67 - 459.67 = 32`，正是冰点。

> 注意 `Unit.name="K"`、`DisplayUnit.name="degC"` 是两套命名空间。变量写 `unit="K" displayUnit="degC"`，不是 `unit="degC"`。变量实际存取的值永远是 `unit` 的单位，`displayUnit` 只影响显示。

### 5.4.2 BouncingBall 的长度别名

```xml
<Unit name="m">
  <BaseUnit m="1"/>
  <DisplayUnit name="ft" factor="3.280839895"/>
</Unit>
```

```xml
<Float64 name="h" ... declaredType="Position" start="1">
  <Alias name="h_ft" description="Position in feet" displayUnit="ft"/>
</Float64>
```

`h` 的 `unit` 继承自 `Position`（`unit="m"`），别名 `h_ft` 只是换了一个显示单位。通过 C API 读 `h` 或 `h_ft`，拿到的都是米；工具可以用 `ft` 显示成 `3.28`。

---

## 5.5 两个 FMU 连接时，单位怎么检查

规范给出的规则可以整理成一张决策表。假设要把 `output v1` 连到 `input v2`：

| v1 的 `BaseUnit` | v2 的 `BaseUnit` | 导入端应做什么 |
| --- | --- | --- |
| 有 | 无 | 用 get/set 传值，不能假设 `v2 = v1` |
| 无 | 有 | 同上 |
| 有 | 有，指数相同，`factor`/`offset` 也相同 | 可以直接用 `v2 = v1` |
| 有 | 有，指数相同，`factor`/`offset` 不同 | 报错，或按公式换算 |
| 有 | 有，指数不同 | 报错（量纲不兼容） |

换算公式就是两边都先化到基准单位：

```text
factor(v1) * v1 + offset(v1) = factor(v2) * v2 + offset(v2)
```

（`relativeQuantity=true` 的一侧不加 offset。）

并且规范要求 `relativeQuantity(v1) = relativeQuantity(v2)`，否则「绝对值」和「差值」会被混在一起。

三个实践要点：

1. **单位名不参与兼容性判断。** `bar` 和 `Pa` 可以连，`N.m` 和 `J` 也可以连——它们量纲相同。只比较字符串的工具是不合格的。
2. **量纲相同不等于物理量相同。** 力矩和能量都是 `kg·m²·s⁻²`，角速度和频率都是 `rad·s⁻¹`。要区分它们只能靠 `quantity`。但 `quantity` 的名字**没有标准化**，所以规范只说「工具可以考虑」，不强制。
3. **只有一边有 `BaseUnit` 时不能直接赋值。** 这时缺少换算依据，必须走 get/set。这一点在写导入端时经常被忽略。

规范还提到两个可选的高级用法：

- **量纲分析**：用 `BaseUnit` 检查方程两边量纲是否一致（把 `rad` 当 1）。
- **单位传播**：某些变量没定义单位时，可以从方程里推导。比如 `a = b + c` 且只有 `c` 有单位，那么 `a`、`b` 可以继承 `c` 的单位；但乘法里有 `rad` 时无法唯一推导。

这两条是工具的事，不影响 XML 的写法。

---

## 5.6 `TypeDefinitions`：可复用的变量类型

`TypeDefinitions` 是一张类型字典。BouncingBall 定义了三个：

```xml
<TypeDefinitions>
  <Float64Type name="Position" quantity="Position" unit="m"/>
  <Float64Type name="Velocity" quantity="Velocity" unit="m/s"/>
  <Float64Type name="Acceleration" quantity="Acceleration" unit="m/s2"/>
</TypeDefinitions>
```

变量通过 `declaredType` 引用：

```xml
<Float64 name="h" valueReference="1" declaredType="Position" start="1" .../>
<Float64 name="v" valueReference="3" declaredType="Velocity" start="0" .../>
<Float64 name="g" valueReference="5" declaredType="Acceleration" start="-9.81" .../>
```

好处很直接：单位、量纲、范围只写一次。如果 20 个变量都是 `Position`，改单位时只改类型定义。

### 5.6.1 可以定义哪些类型

`<TypeDefinitions>` 的子元素与变量元素一一对应，只是名字多了 `Type` 后缀：

| 类型元素 | 对应变量元素 | 特有属性 |
| --- | --- | --- |
| `Float32Type` / `Float64Type` | `Float32` / `Float64` | `min`、`max`、`nominal`、`unbounded` |
| `Int8Type` … `UInt64Type` | `Int8` … `UInt64` | `min`、`max` |
| `BooleanType` | `Boolean` | — |
| `StringType` | `String` | — |
| `BinaryType` | `Binary` | `mimeType`、`maxSize` |
| `EnumerationType` | `Enumeration` | `Item` 列表 |
| `ClockType` | `Clock` | `canBeDeactivated`、`priority`、`intervalVariability` 等 |

所有类型都有 `name`、`description`；浮点、整数和枚举类型有 `quantity`；浮点类型有 `unit`、`displayUnit`、`relativeQuantity`、`nominal`、`unbounded`；浮点和整数类型有 `min`、`max`。`StringType`、`BooleanType`、`BinaryType` 没有物理量相关属性。

### 5.6.2 `declaredType` 的覆盖规则

这是本章最重要的一条规则：

> **类型定义里的属性是默认值；变量上写了同名属性，就以变量为准。**

规范原文是 "The attributes defined in the corresponding `<TypeDefinition>` are used as defaults"，并举例：如果 `min` 在类型和变量上都出现，实际生效的是变量上的 `min`。

```xml
<Float64Type name="Temperature" unit="K" displayUnit="degC" min="0" max="2000"/>

<!-- 继承 unit=K、displayUnit=degC，但把上限收紧到 400 -->
<Float64 name="T_water" valueReference="1" declaredType="Temperature" max="400" .../>
```

这条规则适用于 `unit`、`displayUnit`、`quantity`、`min`、`max`、`nominal`、`unbounded`、`relativeQuantity` 等所有可继承属性。

三个容易踩的坑：

1. **`unit` 必须指向真实存在的 `<Unit>`。** 类型定义和变量上都是如此。XSD 不检查引用，写错只会在导入时报错。
2. **`displayUnit` 必须能在 `unit` 所属的 `<Unit>` 下找到。** 而且「定义了 `displayUnit` 就必须定义 `unit`」——不能只写显示单位。
3. **类型名不能和变量名重名。** 规范明确要求类型 `name` 与所有变量 `name` 不同，否则在 Modelica 这类环境里「类型名当实例名」会出问题。

> BouncingBall 的 `Position` 类型没有写 `min`/`max`，所以 `h` 的取值范围就是 Float64 的默认范围。`e` 则在变量上直接写了 `min="0.5" max="1"`，因为它没有 `declaredType`。

### 5.6.3 `min` / `max` / `nominal` / `unbounded`

| 属性 | 含义 | 默认 |
| --- | --- | --- |
| `min` | 变量允许的最小值（`value >= min`） | 该类型能表示的最小负数 |
| `max` | 变量允许的最大值（`value <= max`） | 该类型能表示的最大正数 |
| `nominal` | 标称值，用于估算绝对容差 | `1` |
| `unbounded` | 积分过程中值可能远大于 `nominal` | `false` |

`nominal` 的典型用法：

```text
absoluteTolerance = nominal * tolerance * 0.01
```

如果某个状态的值在 `1e6` 量级，而相对容差是 `1e-4`，那绝对容差应该是 `1e6 * 1e-4 * 0.01 = 1`，而不是 `1e-6`。不给 `nominal`，求解器可能把精度浪费在无意义的小数位上。

`unbounded="true"` 用于「单调增长、没有物理上界」的量，比如曲轴累计转角、车辆沿轨道的累计位置。它提示求解器不要把相对误差压到 0。

`min`/`max` 还有一层语义：它们定义的是 **FMU 设计工作区**，不是硬性保证。规范明确说 FMU 不应依赖导入端一定遵守范围：求解器迭代期间变量可能短暂越界，迭代结束后也只保证在数值精度内回到范围。对越界的输入，FMU 可以优雅处理，也可以返回 `fmi3Discard` / `fmi3Error`。所以不要把 `min`/`max` 当成断言来写，更不要用它替代 FMU 内部的输入检查。

### 5.6.4 一个完整的类型示例

`examples/xml/units-and-types.xml`（本章实验用）：

```xml
<UnitDefinitions>
  <Unit name="K">
    <BaseUnit K="1"/>
    <DisplayUnit name="degC" factor="1" offset="-273.15"/>
  </Unit>
  <Unit name="m/s">
    <BaseUnit m="1" s="-1"/>
    <DisplayUnit name="km/h" factor="3.6"/>
  </Unit>
</UnitDefinitions>

<TypeDefinitions>
  <Float64Type name="Temperature"
               quantity="ThermodynamicTemperature"
               unit="K"
               displayUnit="degC"
               min="0"
               max="2000"/>
  <Float64Type name="Velocity"
               quantity="Velocity"
               unit="m/s"
               displayUnit="km/h"/>
  <EnumerationType name="Mode">
    <Item name="Heating" value="0"/>
    <Item name="Cooling" value="1"/>
    <Item name="Idle" value="2"/>
  </EnumerationType>
</TypeDefinitions>

<ModelVariables>
  <Float64 name="time" valueReference="0" causality="independent" variability="continuous"/>
  <Float64 name="T" valueReference="1" causality="output" declaredType="Temperature" initial="exact" start="293.15"/>
  <Float64 name="v" valueReference="2" causality="input" declaredType="Velocity" initial="exact" start="0"/>
  <Enumeration name="mode" valueReference="3" causality="output" declaredType="Mode"/>
</ModelVariables>

<ModelStructure>
  <Output valueReference="1"/>
  <Output valueReference="3"/>
</ModelStructure>
```

这份文件可以通过 XSD 校验和本章的语义检查（见 5.11）。

---

## 5.7 `EnumerationType`：带名字的整数

枚举在 XML 里是「名字 → 整数」的映射：

```xml
<EnumerationType name="Option">
  <Item name="Option 1" value="1" description="First option"/>
  <Item name="Option 2" value="2" description="Second option"/>
</EnumerationType>
```

```xml
<Enumeration name="Enumeration_input" declaredType="Option" valueReference="33" causality="input" start="1"/>
```

来自 `examples/reference-fmus/Feedthrough/FMI3.xml`。

规则：

1. **`<Enumeration>` 变量的 `declaredType` 是必需的。** 枚举项只存在于类型定义里，变量自己无法声明。
2. **`<EnumerationType>` 至少有一个 `<Item>`。** 空枚举没有意义。
3. **`Item` 的 `name` 和 `value` 在同一个类型内各自唯一。** 但不同枚举类型的 `value` 可以重复。
4. **运行时用 `fmi3GetInt64` / `fmi3SetInt64` 读写。** 规范特别说明这一点，因为 C 的 `enum` 位宽由编译器决定，不能跨平台保证；FMI 统一用 64 位有符号整数传输。
5. **`value` 可以是负数。** C 允许，FMI 也允许。`min`/`max` 会进一步过滤可用项，例如 `name1=-4, name2=1, name3=5, name4=11` 配 `min=-2, max=5` 时只有 `name2` 和 `name3` 合法。
6. **整数不保证连续，也不保证从 0 开始。** 不要用 `for i in 0..n-1` 遍历枚举值。

`Item name` 可以包含空格（`"Option 1"`），因为它是给人看的标签，不是 C 标识符。

> 为什么 FMI 3.0 不引入独立的 `fmi3GetEnumeration`？因为枚举在所有平台上都能用 64 位整数表示，再加一组 getter/setter 只会增加 API 面积。用 `Int64` 是「够用且不歧义」的选择。

---

## 5.8 `StringType` 与 `BinaryType`

字符串没有单位，但可以有类型定义：

```xml
<StringType name="FileName" description="A relative path inside the resources directory"/>
```

二进制类型多两个属性：

```xml
<BinaryType name="Image"
            mimeType="image/png"
            maxSize="1048576"/>
```

| 属性 | 作用 | 默认 |
| --- | --- | --- |
| `mimeType` | 说明二进制内容的媒体类型 | `application/octet-stream` |
| `maxSize` | 最大字节数 | 无 |

`mimeType` 和 `maxSize` 不是强校验，而是给导入端做连接提示：把 `image/png` 的输出连到只接受 `application/json` 的输入时，工具可以提前警告。

字符串和二进制变量的初始值不用 `start` 属性，而用 `<Start value="..."/>` 子元素：

```xml
<String name="String_input" valueReference="29" causality="input">
  <Start value="Set me!"/>
</String>

<Binary name="Binary_input" valueReference="31" causality="input">
  <Start value="666f6f"/>
</Binary>
```

`666f6f` 是 ASCII `foo` 的十六进制编码。Binary 的 `Start` 是字节序列，不是文本。

---

## 5.9 `Annotations`：可安全忽略的扩展

所有 FMI XML 文件都允许在特定位置插入 `<Annotations>`：

```xml
<Annotations>
  <Annotation type="com.example.simulation">
    <meta:Parameter xmlns:meta="https://example.com/fmi/meta"
                    tolerance="1e-6"
                    solver="CVODE"/>
  </Annotation>
</Annotations>
```

规则：

- 每个 `<Annotation>` 必须有 `type` 属性，值是**反向域名**（reverse DNS），例如 `com.example.simulation`。
- `Annotation` 的内容可以是任意 XML：元素、属性、文本、命名空间都行。
- 同一个 `<Annotations>` 里可以有多个 `Annotation`，`type` 不同即可。
- **不实现该扩展的工具可以安全忽略它。** 这是整个机制的设计目标：让供应商扩展不冲突、不产生歧义。

`type` 用反向域名，是为了避免两个厂商都定义 `solver` 注解时打架。规范把这类扩展的组织方式留给分层标准（layered standard）。

### 5.9.1 注解能放在哪里

`Annotations` 可以出现在很多元素里，包括：

- 根元素 `<fmiModelDescription>`
- `<ModelVariables>` 里的每个变量
- `<TypeDefinitions>` 的每个类型
- `<UnitDefinitions>` 的 `<Unit>` / `<DisplayUnit>`
- `<ModelStructure>` 的条目
- `terminalsAndIcons.xml` 里的终端

具体位置由各个 XSD 的 `xs:sequence` 决定，顺序不能随意插。例如变量里的 `Annotations` 必须排在 `<Dimension>` 和 `<Alias>` 之前。

### 5.9.2 验证注解时的现象

用第 3 章的脚本校验带注解的文件，会看到类似（提示文字随系统语言变化）：

```text
Warning: 未找到元素“https://example.com/fmi/meta:Meta”的架构信息。
Warning: 未找到属性“author”的架构信息。
OK: ... is valid against fmi3ModelDescription.xsd
```

这是因为 `fmi3Annotation.xsd` 对注解内容使用 `processContents="lax"`：

- 如果导入端认识这个命名空间的 schema，就顺便校验；
- 如果不认识，就跳过，只给警告。

所以「有警告但还是 valid」是正常现象，不是脚本的 bug。

### 5.9.3 什么不该放进注解

注解适合放**工具特定的元数据**：

- 求解器偏好（容差、积分器类型）
- GUI 布局、颜色、分组
- 供应商私有的参数界面信息

不适合放**语义关键信息**：

- 变量的物理含义（应该用 `quantity` / `unit`）
- 连接规则（应该用 Terminals 或分层标准）
- 单位换算（应该用 `BaseUnit` / `DisplayUnit`）

原因很简单：别的工具会忽略注解。如果把「这个输入必须接电流」写进私有注解，换一个导入端就丢失了。

---

## 5.10 Terminals and Icons：可选的第二份描述

端子（Terminals）把变量分组成「物理连接器」或「总线」，放在**单独的文件**里：

```text
terminalsAndIcons/terminalsAndIcons.xml
```

对应的 schema 是 `docs/spec-3.0.2/schema/fmi3TerminalsAndIcons.xsd`。顶层元素：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<fmiTerminalsAndIcons fmiVersion="3.0">
  <GraphicalRepresentation>
    <CoordinateSystem x1="-100" y1="-100" x2="100" y2="100"
                      suggestedScalingFactorTo_mm="0.1"/>
    <Icon x1="-100" y1="-100" x2="100" y2="100"/>
  </GraphicalRepresentation>
  <Terminals>
    <Terminal name="portA" matchingRule="plug" terminalKind="com.example.HydraulicPort">
      <TerminalMemberVariable variableName="p" memberName="p" variableKind="signal"/>
      <TerminalMemberVariable variableName="q" memberName="q" variableKind="inflow"/>
    </Terminal>
  </Terminals>
</fmiTerminalsAndIcons>
```

### 5.10.1 它不改变 `causality`

规范开宗明义：Terminals 只增加一层语义分组，**不会改变变量的 causality**。输入仍然是输入，输出仍然是输出，参数仍然是参数。

它解决的是「系统级连接」的问题：哪些变量应该一起连、按什么规则匹配、哪些是流变量（满足基尔霍夫定律）。

### 5.10.2 `matchingRule`

| 值 | 匹配依据 | 典型场景 |
| --- | --- | --- |
| `plug` | `memberName`；所有成员都必须存在且匹配 | 严格的物理接口 |
| `bus` | `memberName`；允许部分成员缺失，甚至一个成员都没有 | 总线、可选信号 |
| `sequence` | 成员顺序；数量必须一致 | 位置相关的数组式接口 |
| `none` | 创建者不打算让工具自动匹配；工具仍可基于其他信息连接 | 仅提供分组信息 |

`matchingRule` 是必填属性。`terminalKind` 可选，但推荐用反向域名；规范给的例子包括 `Modelica.Mechanics.Translational.Interfaces.Flange_a`。

### 5.10.3 `variableKind`

预定义两类：

- `signal`：连接的变量值应当相等，用于信号流、参数传播、相等性检查。只允许 `input` / `output` / `parameter` / `calculatedParameter`。
- `inflow` / `outflow`：满足基尔霍夫电流定律的变量，例如电流、流量。同样只允许上述四种 causality。

领域特定的 `variableKind` 也应使用反向域名，或以下划线开头的厂商前缀（`_vendorName`）。

### 5.10.4 图标与坐标系

- 图标文件固定放在 `terminalsAndIcons/icon.png`；可选再放 `icon.svg`（必须同时有 PNG）。
- `<CoordinateSystem>` 默认 `x1=-100, y1=-100, x2=100, y2=100`，默认 `suggestedScalingFactorTo_mm=0.1`，也就是默认显示为 20 mm × 20 mm。
- 图形项可以超出坐标系；导入端要自己算外接矩形。
- XML 里的元素顺序就是绘制顺序：先出现的先画，位于下层；后出现的后画，盖在上面。

Terminals 和 Icons 都是**完全可选**的，任何导入端都可以忽略。这一点和注解一样，是 FMI 的兼容性设计：核心信息在 `modelDescription.xml`，扩展信息放在可以被忽略的地方。

---

## 5.11 一致性检查清单

到这里，`modelDescription.xml` 的四大块——接口、变量、单位/类型、结构——都讲完了。XSD 只能保证「结构合法」，剩下的是语义。仓库提供两个脚本：

| 脚本 | 检查内容 | 查不出 |
| --- | --- | --- |
| `examples/scripts/validate-model-description.ps1` | XSD：元素顺序、必需属性、枚举取值、数据类型 | 引用是否存在、语义是否自洽 |
| `examples/scripts/check-model-description.ps1` | 名称/VR 唯一、unit/displayUnit/declaredType 引用、Dimension 目标、initial/start 搭配、Output 完整性 | dependencies 语义、Clock 组合、二进制是否存在 |

### 5.11.1 结构校验

```powershell
.\examples\scripts\validate-model-description.ps1 `
    .\examples\xml\units-and-types.xml
```

```text
OK: ...\examples\xml\units-and-types.xml is valid against fmi3ModelDescription.xsd
```

### 5.11.2 语义检查

```powershell
.\examples\scripts\check-model-description.ps1 `
    .\examples\xml\units-and-types.xml
```

```text
OK: no errors, 0 warning(s) in ...\examples\xml\units-and-types.xml
```

对全部 Reference FMUs 跑一遍：

```powershell
Get-ChildItem .\examples\reference-fmus -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'FMI3.xml') } |
    ForEach-Object {
        Write-Host "== $($_.Name) =="
        .\examples\scripts\check-model-description.ps1 (Join-Path $_.FullName 'FMI3.xml')
    }
```

### 5.11.3 人工检查项

脚本覆盖不了的，至少人工过一遍：

- [ ] 有且只有一个 `causality="independent"` 变量，且没有 `start`
- [ ] 所有 `output` 都在 `<ModelStructure><Output>` 里，顺序符合预期
- [ ] 所有连续状态导数都在 `<ContinuousStateDerivative>` 里
- [ ] `dependencies` 的「缺失 / 空串 / 列表」三种写法是有意选择的
- [ ] Clock 变量所在的接口设置了 `hasEventMode="true"`
- [ ] `modelIdentifier` 对应的二进制在 `binaries/<platformTuple>/` 下真实存在
- [ ] 注解里的命名空间 URL 是团队控制的域名
- [ ] `terminalsAndIcons.xml` 的 `fmiVersion` 与主文件一致

最后一条尤其容易漏：两份 XML 的版本必须相同，否则导入端可能拒绝加载。

---

## 5.12 动手实验

### 实验 5-1：读一份单位定义

规范自带的例子 `docs/spec-3.0.2/adoc/examples/unit_definition.xml` 包含四种典型写法：

```powershell
Get-Content .\docs\spec-3.0.2\adoc\examples\unit_definition.xml
.\examples\scripts\validate-model-description.ps1 `
    .\docs\spec-3.0.2\adoc\examples\unit_definition.xml
```

回答：

1. `rad/s` 的两个 `DisplayUnit` 分别是什么？换算系数为什么是 57.3 和 9.55？
2. `L/100km` 的 `inverse="true"` 起什么作用？
3. `Re` 的 `<BaseUnit/>` 全零，表示什么？
4. `Euro/PersonYear` 为什么没有 `BaseUnit`？

> 提示：这是一个描述文件片段，只有变量 `u`，没有完整模型。它仍然能通过 XSD。

### 实验 5-2：加一个注解

把 BouncingBall 复制到临时文件，在变量 `h` 里插入注解：

```powershell
$src = ".\examples\reference-fmus\BouncingBall\FMI3.xml"
$dst = "$env:TEMP\BouncingBall-annotated.xml"

(Get-Content $src -Raw) -replace '(<Float64 name="h"[^>]*>)', @'
$1
      <Annotations>
        <Annotation type="com.example.plot">
          <plot:Style xmlns:plot="https://example.com/fmi/plot" color="#ff0000"/>
        </Annotation>
      </Annotations>
'@ | Set-Content $dst -Encoding UTF8

.\examples\scripts\validate-model-description.ps1 $dst
```

观察输出中的 `Warning`，并解释为什么最终仍然是 `OK`。

### 实验 5-3：制造语义错误

```powershell
$bad = "$env:TEMP\broken-semantics.xml"
(Get-Content .\examples\reference-fmus\BouncingBall\FMI3.xml -Raw) `
    -replace 'declaredType="Position"', 'declaredType="Pos"' `
    -replace 'valueReference="3" causality="output"', 'valueReference="1" causality="output"' |
    Set-Content $bad -Encoding UTF8

.\examples\scripts\validate-model-description.ps1 $bad
.\examples\scripts\check-model-description.ps1 $bad
```

预期：XSD 仍然通过，语义检查报三个错：

```text
ERROR   variable 'h' references unknown declaredType 'Pos'
ERROR   duplicate valueReference '1' ('v' and 'h')
ERROR   <Output> references '3', which is not an output variable
```

思考：为什么 XSD 查不出 `declaredType="Pos"`？

### 实验 5-4：手算单位换算

```powershell
# bar -> Pa
1e5 * 2

# rpm -> rad/s
0.1047197551196598 * 3000

# degF -> K
(5/9) * 32 + 255.3722222222222

# L/100km -> mpg
235.214583 / 5

# K -> degF（displayUnit）
1.8 * 373.15 - 459.67
```

把结果和 5.3 / 5.4 节的表格对照。最后一个应得到 `212`。

### 实验 5-5：自己写一个类型

基于 `examples/xml/units-and-types.xml` 做三个改动：

1. 增加一个 `Pressure` 类型，单位 `bar`，并给 `UnitDefinitions` 加上 `bar` 的定义。
2. 增加一个输出变量 `p`，使用 `Pressure`，`start="1.013"`，并加入 `<ModelStructure><Output>`。
3. 把 `T` 的 `max` 从类型继承值改成 `350`，验证变量级覆盖。

改完跑两个脚本，确认都通过。

<details>
<summary>参考改动</summary>

```xml
<UnitDefinitions>
  <!-- 原有内容 -->
  <Unit name="bar">
    <BaseUnit kg="1" m="-1" s="-2" factor="1e5"/>
    <DisplayUnit name="mbar" factor="1000"/>
  </Unit>
</UnitDefinitions>

<TypeDefinitions>
  <!-- 原有内容 -->
  <Float64Type name="Pressure" quantity="Pressure" unit="bar" displayUnit="mbar"/>
</TypeDefinitions>

<ModelVariables>
  <!-- 原有内容 -->
  <Float64 name="p" valueReference="4" causality="output" declaredType="Pressure" initial="exact" start="1.013"/>
</ModelVariables>

<ModelStructure>
  <Output valueReference="1"/>
  <Output valueReference="3"/>
  <Output valueReference="4"/>
</ModelStructure>
```

`T` 的变量级覆盖：

```xml
<Float64 name="T" valueReference="1" causality="output" declaredType="Temperature"
         initial="exact" start="293.15" max="350"/>
```

注意 `p` 必须加进 `ModelStructure`，否则语义检查会报「output 缺失」。

</details>

---

## 5.13 小结

- 单位由 8 个指数（7 个 SI + `rad`）描述量纲，`factor`/`offset` 描述换算；`rad` 在量纲分析时按 1 处理。
- `relativeQuantity="true"` 表示差值，换算时忽略 offset（`BaseUnit` 和 `displayUnit` 都忽略）。
- `DisplayUnit` 用 `v_display = factor * v_unit + offset`；`inverse="true"` 时用 `factor / v_unit`，且只允许 `offset=0`。
- 两个 FMU 连接时，指数相同才能换算；只有一边有 `BaseUnit` 时必须走 get/set；`quantity` 用于区分同量纲的不同物理量，但名字不标准化。
- `TypeDefinitions` 提供可复用类型；`declaredType` 的属性是默认值，变量上的同名属性优先。
- 类型名不能与变量名重名；`unit` 必须存在；`displayUnit` 必须挂在对应 `unit` 下。
- `min`/`max` 是设计工作区，`nominal` 影响容差估算，`unbounded` 用于单调增长量。
- 枚举必须有非空 `Item` 列表；变量必须写 `declaredType`；运行时用 `fmi3GetInt64` / `fmi3SetInt64`。
- 注解用反向域名做命名空间，内容任意，核心实现可以安全忽略；`processContents="lax"` 导致「有警告但 valid」。
- Terminals 是可选的分组层，不改变 `causality`；`matchingRule` 决定连接时如何匹配成员。
- 结构校验（XSD）和语义检查（自写脚本）缺一不可，最后还要做人工清单和真实加载测试。

---

## 习题

### 1. 单位换算

某 FMU 定义：

```xml
<Unit name="psi">
  <BaseUnit kg="1" m="-1" s="-2" factor="6894.757293168"/>
</Unit>
```

1. `psi` 与 `bar` 的 `BaseUnit` 指数是否相同？
2. 10 psi 等于多少 Pa？
3. 导入端能否把 `psi` 输出直接连到 `bar` 输入？需要做什么？

<details>
<summary>答案</summary>

1. 相同：都是 `kg=1, m=-1, s=-2`。
2. `6894.757293168 * 10 = 68947.57293168 Pa`。
3. 可以连接，但 `factor` 不同，必须换算：`p_bar = 6894.757293168 * p_psi / 1e5`，或者统一化到 Pa 再赋值。

</details>

### 2. `relativeQuantity` 的坑

一个 `Temperature` 类型定义为：

```xml
<Float64Type name="Temperature" unit="K" relativeQuantity="true"/>
```

1. 变量 `dT = 10` 表示多少 K？
2. 如果误把它当成绝对温度，会差多少？
3. `displayUnit="degC"` 时，显示值是多少？

<details>
<summary>答案</summary>

1. 10 K（offset 被忽略）。
2. 会被当成 10 K 而不是 283.15 K，差 273.15 K。
3. 10 °C（`v_display = 1 * 10 - 273.15` 中的 offset 同样要忽略，所以是 10）。

</details>

### 3. `declaredType` 覆盖

```xml
<Float64Type name="Gain" unit="1" min="0" max="10" nominal="1"/>
<Float64 name="k" valueReference="5" causality="parameter" declaredType="Gain" max="5" start="2"/>
```

（假设 `UnitDefinitions` 里已经定义了名为 `1` 的无量纲单位。）

1. `k` 的有效 `min`、`max`、`nominal`、`unit` 分别是什么？
2. `k` 的 `variability` 和 `initial` 默认是什么？
3. 这个变量合法吗？

<details>
<summary>答案</summary>

1. `min=0`（继承）、`max=5`（覆盖）、`nominal=1`（继承）、`unit="1"`（继承）。
2. `variability=fixed`，`initial=exact`（parameter 的默认值）。
3. 合法：parameter 默认 `initial=exact`，允许且要求 `start`；`max=5` 覆盖了类型的 `max=10`。

</details>

### 4. 枚举的边界

```xml
<EnumerationType name="State" min="1" max="5">
  <Item name="Off" value="0"/>
  <Item name="Idle" value="1"/>
  <Item name="Run" value="5"/>
  <Item name="Fault" value="9"/>
</EnumerationType>
```

1. 哪些枚举项在允许范围内？
2. 如果导入端写入 `9`，会发生什么？
3. 能否用 `fmi3GetInt32` 读这个变量？

<details>
<summary>答案</summary>

1. `Idle`（1）和 `Run`（5）。
2. 超出 `max=5`，落在设计工作区之外；FMU 可以拒绝（`fmi3Error` / `fmi3Discard`），也可以自行处理，规范不保证结果。
3. 不能。规范要求用 `fmi3GetInt64`。

</details>

### 5. 什么时候需要 Terminals

判断下列需求应该用 `causality`、`unit`、`Annotation` 还是 Terminals：

1. 一个输出是电流，连接时要满足基尔霍夫电流定律。
2. 一个变量是温度，界面上默认显示摄氏度。
3. 某个求解器希望优先用 CVODE。
4. 一个输入必须来自另一个 FMU 的 `output`。
5. 两个变量属于同一个液压端口，需要按名字成组匹配。

<details>
<summary>答案</summary>

1. Terminals（`variableKind="inflow"` / `"outflow"`）。
2. `unit` + `displayUnit`（如果只是显示偏好）；不需要 Terminals。
3. `Annotation`（工具特定元数据）。
4. `causality="input"`。
5. Terminals（`matchingRule="plug"` 或 `"bus"`，配合 `terminalKind`）。

</details>

### 6. 判断题

1. 一个 `<Unit>` 必须有 `<BaseUnit>`。
2. `DisplayUnit` 的 `factor` 表示「1 个显示单位等于多少个 `Unit`」。
3. `declaredType` 引用的类型名可以和变量名相同。
4. 注解里的 XML 可以不声明命名空间前缀。
5. `terminalsAndIcons.xml` 可以把一个 `input` 变成 `output`。

<details>
<summary>答案</summary>

1. 错。`BaseUnit` 可选，无法映射到 SI 的单位可以省略。
2. 错。公式是 `v_display = factor * v_unit + offset`，`factor` 是「1 个 `Unit` 等于多少个显示单位」。例如 `m → ft` 的 `factor=3.2808`。
3. 错。规范要求类型名与所有变量名不同。
4. 错。XML 要求前缀先声明；未声明前缀是格式错误。注解内容可以任意，但必须是合法 XML。
5. 错。Terminals 不改变 `causality`。

</details>

---

## 下一章

描述文件部分到此结束。从第 6 章开始进入第三部分：**接口与状态机**。我们会把 `fmi3Instantiate*`、`fmi3EnterInitializationMode`、`fmi3ExitInitializationMode` 这些函数的调用顺序，和规范里的状态迁移图逐条对应起来。

→ [第 6 章 公共状态机](06-state-machine.md)
