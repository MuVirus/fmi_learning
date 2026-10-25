# 第 2 章 解包一个 FMU

> **第一部分：入门 · 初稿**
> 对应规范：[2.5 FMU Distribution](../spec-3.0.2/html/index.html#fmu-distribution)、[2.5.1 Structure of the ZIP file](../spec-3.0.2/html/index.html#structure-of-zip)
> 预计阅读：30 分钟
> 动手时间：20 分钟

## 学习目标

读完本章，你应该能够：

1. 说明 FMU 为什么是一个 ZIP 文件，以及规范对 ZIP 有哪些限制。
2. 背出 FMU 的标准目录结构，并说清每个目录的职责。
3. 独立解包任意 FMU，快速定位描述文件、二进制、源码和资源。
4. 看懂平台元组（platform tuple）的命名规则。
5. 区分"二进制 FMU"和"源码 FMU"。
6. 描述导入端加载 FMU 的大致流程。

---

## 2.1 先动手：FMU 就是一个 ZIP

拿一个真实的 FMU 试试。以下命令都在仓库根目录执行：

```powershell
# 1. 复制成 .zip（Expand-Archive 只认 .zip 扩展名）
Copy-Item .\examples\fmus\3.0\BouncingBall.fmu $env:TEMP\BouncingBall.zip

# 2. 解压到临时目录
Expand-Archive $env:TEMP\BouncingBall.zip $env:TEMP\BouncingBall -Force

# 3. 看目录树
tree /F $env:TEMP\BouncingBall
```

也可以不解压，直接列出 ZIP 内容：

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead("$PWD\examples\fmus\3.0\BouncingBall.fmu")
$zip.Entries | Sort-Object FullName | Format-Table FullName, Length -AutoSize
$zip.Dispose()
```

你会看到 22 个文件，解压后约 **1.19 MiB（1,246,618 字节）**，而 `.fmu` 本身只有 **355 KiB（363,815 字节）**——压缩比大约 3.43:1。

### 规范对 ZIP 的要求

FMU 不是"随便打一个 ZIP"就行。规范对归档格式有明确限制（2.5 节）：

- 扩展名必须是 `.fmu`；
- 压缩方法只能是 **deflate（8）** 或 **store（0）**；
- 不能加密，不能分卷；
- 路径分隔符使用正斜杠 `/`（ZIP 规范禁止反斜杠；规范以 Note 形式强调，非 ASCII 目录名也不建议使用）；
- ZIP 内部不能使用符号链接；
- `version needed to extract` 不能高于 2.0；
- 归档里必须有 `modelDescription.xml`，并且位于**根目录**。

这些限制的目的只有一个：**保证任何平台的任何 ZIP 库都能打开 FMU**。所以不要用 7-Zip 的固实压缩、加密、分卷，也不要在 ZIP 里放快捷方式。

> 一个常见的错误：把整个文件夹压缩成 ZIP，导致解压后是 `BouncingBall/modelDescription.xml` 而不是 `modelDescription.xml`。规范要求后者，前者会让大多数导入端直接拒绝。

---

## 2.2 标准目录结构

规范给出的 FMU 目录结构如下。注意：只有根目录的 `modelDescription.xml` 是必需文件，下面列出的目录全部可选；花括号 `{txt|html}` 表示"任选其一的扩展名"。

```text
modelDescription.xml                  # 必需：FMU 的"说明书"
documentation/                        # 可选：文档
   index.html                         #   文档入口
   diagram.png / diagram.svg          #   模型示意图
   externalDependencies.{txt|html}    #   外部依赖说明
   staticLinking.{txt|html}           #   静态链接说明
   licenses/                          #   许可证
      license.{txt|html|spdx}
terminalsAndIcons/                    # 可选：Terminal 与图标（FMI 3.0 新增）
   terminalsAndIcons.xml
   icon.png / icon.svg
sources/                              # 可选：C 源码
   buildDescription.xml               #   如何编译
binaries/                             # 可选：二进制
   <platformTuple>/                   #   如 x86_64-windows
      <modelIdentifier>.dll
resources/                            # 可选：运行时资源（表、地图等）
extra/                                # 可选：分层标准等附加数据
```

几条关键规则：

1. **至少要有一种实现**：`sources/` 或某个 `binaries/<tuple>/`，不能只有 XML。
2. **二进制 FMU** 必须为它声称支持的所有平台提供二进制，且加载所需的文件要和主库放在同一目录。
3. **`sources/` 里不包含 FMI 头文件**（`fmi3PlatformTypes.h`、`fmi3FunctionTypes.h`、`fmi3Functions.h`）。这三个头文件由导入端提供，以适配具体平台和编译器。
4. **`resources/` 必须以解压形态存在**。导入端实例化时把资源目录的绝对路径传给 FMU；该目录在整个实例生命周期内必须可用，**FMU 实例不得写入或删除其中的内容**。
5. **`extra/` 允许第三方修改**。它用来放分层标准等附加数据，目录名推荐使用反向域名（如 `extra/org.fmi-standard.fmi-ls-ref/`）。

还有一条容易被忽略的要求：

> FMU 必须实现 `fmi3Functions.h` 中声明的**所有** API 函数，即使某些函数只服务于它不支持的接口类型。不支持的函数可以返回错误，但符号必须存在。

这一点会在 2.4.2 节用 `dumpbin` 亲眼验证。

---

## 2.3 解剖 BouncingBall.fmu

`examples/fmus/3.0/BouncingBall.fmu` 是官方 Reference FMUs 里的最小示例之一：一个从 1 m 高度落下、带反弹的小球。它的完整内容如下：

```text
BouncingBall/
├─ modelDescription.xml                          3,743 B
├─ binaries/
│  ├─ x86_64-windows/BouncingBall.dll          172,544 B
│  ├─ x86-windows/BouncingBall.dll             141,824 B
│  ├─ x86_64-linux/BouncingBall.so              70,872 B
│  ├─ aarch64-linux/BouncingBall.so             71,944 B
│  ├─ aarch64-darwin/BouncingBall.dylib         89,744 B
│  └─ wasm32-wasip2/BouncingBall.wasm          372,946 B
├─ sources/
│  ├─ buildDescription.xml                         454 B
│  ├─ fmi3Functions.c                           38,930 B
│  ├─ model.c / model.h                    7,261 / 10,033 B
│  ├─ common.c                                  17,684 B
│  ├─ cosimulation.c / cosimulation.h     2,092 / 110 B
│  ├─ co_simulation_fmu.c / .h       92,128 / 41,835 B
│  ├─ fmu_wasm.c                                30,525 B
│  └─ config.h                                     631 B
├─ documentation/
│  ├─ index.html                                 4,338 B
│  └─ result.svg                                51,218 B
└─ extra/
   └─ org.fmi-standard.fmi-ls-ref/
      ├─ fmi-ls-manifest.xml                        406 B
      └─ BouncingBall_out.csv                    25,356 B
```

按目录统计：

| 目录 | 文件数 | 解压后大小 | 作用 |
| --- | ---: | ---: | --- |
| 根目录 | 1 | 3.7 KiB | 模型描述 |
| `binaries/` | 6 | 898 KiB | 6 个平台的二进制 |
| `sources/` | 11 | 236 KiB | 可重新编译的 C 源码 |
| `documentation/` | 2 | 54 KiB | 文档和结果图 |
| `extra/` | 2 | 25 KiB | 分层标准附加数据 |

### 2.3.1 `modelDescription.xml`：唯一必需的**文件**

在文件层面，整个 FMU 里只有 `modelDescription.xml` 是必需的：它是唯一必须在 ZIP 根目录出现的文件。注意别把这句话理解为"只要有 XML 就够了"——FMU 还必须至少带一种实现（`binaries/` 或 `sources/`，见 2.2 节规则 1）。

它回答导入端最关心的几个问题：

- 这个 FMU 支持哪些接口类型（ME / CS / SE）？
- 每个接口的 `modelIdentifier` 是什么（决定加载哪个二进制）？
- 有哪些变量？类型、因果性、初始值、单位分别是什么？
- 支持哪些能力（可变步长、早返回、中间更新、状态序列化……）？
- 默认实验怎么设置（开始时间、停止时间、步长）？

第 3 章会逐字段讲。这里先看前 24 行，混个脸熟：

```xml
<fmiModelDescription
  fmiVersion="3.0"
  modelName="BouncingBall"
  description="This model calculates the trajectory, over time, of a ball dropped from a height of 1 m"
  generationTool="Reference FMUs (v0.0.42)"
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
```

从这几行就能读出：

- 它是 **FMI 3.0**；
- 同时支持 **Model Exchange** 和 **Co-Simulation**；
- 两个接口的 `modelIdentifier` 都是 `BouncingBall`，所以共用同一个二进制；
- 没有 `<ScheduledExecution>`，因此不支持 SE；
- CS 支持可变通信步长、中间更新、早返回、事件模式，内部固定步长 1 ms。

> `instantiationToken` 是 FMI 3.0 新增的。2.0 里对应的是 `guid`。它不是简单的改名：导出端生成这个不透明字符串，导入端必须原样传给 `fmi3Instantiate*`，FMU 用它检查 XML 和二进制是否匹配。

### 2.3.2 `binaries/`：一个 FMU，六个平台

这个 FMU 里带了 6 份二进制：

| 平台元组 | 文件 | 目标平台 |
| --- | --- | --- |
| `x86_64-windows` | `BouncingBall.dll` | 64 位 Windows |
| `x86-windows` | `BouncingBall.dll` | 32 位 Windows |
| `x86_64-linux` | `BouncingBall.so` | 64 位 x86 Linux |
| `aarch64-linux` | `BouncingBall.so` | ARM64 Linux |
| `aarch64-darwin` | `BouncingBall.dylib` | Apple Silicon macOS |
| `wasm32-wasip2` | `BouncingBall.wasm` | WebAssembly（WASI Preview 2） |

导入端会根据当前运行平台选择对应的目录。例如在 64 位 Windows 上，它会加载：

```text
binaries/x86_64-windows/BouncingBall.dll
```

`wasm32-wasip2` 不是规范表格中列出的常用元组，而是 Reference FMUs 的 WASM 构建使用的平台标识。规范允许厂商引入新的元组名（"Further names can be introduced by vendors"），使用这类元组前最好确认导入端认识它。

### 2.3.3 `sources/`：可重新编译的实现

`sources/` 里是完整的 C 源码，外加 `buildDescription.xml`：

```xml
<fmiBuildDescription fmiVersion="3.0">
  <BuildConfiguration modelIdentifier="BouncingBall">
    <SourceFileSet language="C99">
      <SourceFile name="fmi3Functions.c"/>
      <SourceFile name="model.c"/>
      <SourceFile name="common.c"/>
      <SourceFile name="cosimulation.c"/>
      <PreprocessorDefinition name="FMI_VERSION" value="3"/>
    </SourceFileSet>
  </BuildConfiguration>
</fmiBuildDescription>
```

它告诉导入端（或构建工具）：用 C99 编译这几个文件，并定义 `FMI_VERSION=3`。

注意 `sources/` 里**没有** FMI 头文件。编译时需要从规范或导入端获取 `fmi3Functions.h` 等三个头文件。

### 2.3.4 `documentation/`：可选但很有用

用浏览器打开 `documentation/index.html`，你会看到模型说明、变量表和一条用 fmusim 生成的轨迹曲线。它不影响仿真，但对理解模型很有帮助。

### 2.3.5 `extra/`：分层标准的落脚点

```text
extra/org.fmi-standard.fmi-ls-ref/
├─ fmi-ls-manifest.xml
└─ BouncingBall_out.csv
```

`org.fmi-standard.fmi-ls-ref` 是 FMI-LS-REF 分层标准的反向域名。`fmi-ls-manifest.xml` 声明了这个 CSV 的用途：

```xml
<Related type="text/csv"
         source="BouncingBall_out.csv"
         role="result"
         description="Output of the default experiment"/>
```

也就是说，CSV 是这个模型的"标准答案"，可用于回归测试。放在 `extra/` 里的数据允许被工具修改，不影响 FMU 的核心有效性。

---

## 2.4 二进制里到底有什么

### 2.4.1 平台元组命名规则

平台元组的一般格式是：

```text
<arch>-<sys>[-<abi>]
```

规范定义的架构和操作系统：

| `<arch>` | 含义 | `<sys>` | 含义 |
| --- | --- | --- | --- |
| `x86` | Intel/AMD 32 位 | `windows` | Microsoft Windows |
| `x86_64` | Intel/AMD 64 位 | `linux` | Linux |
| `aarch32` | ARM 32 位 | `darwin` | macOS / iOS / 等 |
| `aarch64` | ARM 64 位 | | |

常见组合与 FMI 2.0 的对应关系：

| FMI 3.0 | FMI 2.0 | 平台 |
| --- | --- | --- |
| `x86-windows` | `win32` | 32 位 Windows |
| `x86_64-windows` | `win64` | 64 位 Windows |
| `x86-linux` | `linux32` | 32 位 Linux |
| `x86_64-linux` | `linux64` | 64 位 Linux |
| `aarch64-linux` | — | ARM64 Linux |
| `x86_64-darwin` | `darwin64` | Intel macOS |
| `aarch64-darwin` | — | Apple Silicon macOS |

如果是静态库，还可以在末尾加 ABI 后缀，例如 `x86_64-windows-msvc140mt`，并在 `documentation/staticLinking.txt` 里说明链接要求。

### 2.4.2 导出符号：75 个 `fmi3*` 函数

用 Visual Studio 的 `dumpbin` 看看 DLL 导出了什么（在 "Developer PowerShell for VS 2022" 里执行）：

```powershell
dumpbin /exports .\BouncingBall\binaries\x86_64-windows\BouncingBall.dll |
    Select-String 'fmi3'
```

你会看到 75 个导出符号，包括：

```text
fmi3InstantiateModelExchange
fmi3InstantiateCoSimulation
fmi3EnterInitializationMode
fmi3ExitInitializationMode
fmi3GetContinuousStateDerivatives
fmi3GetEventIndicators
fmi3DoStep
fmi3ActivateModelPartition
fmi3FreeInstance
...
```

注意 `fmi3ActivateModelPartition`：它是 SE 的函数，而这个 FMU 并不支持 SE，但符号依然存在。这正是规范 2.5 节的要求——**函数必须齐全，是否支持看 XML 和实际行为**。

在 Linux/macOS 上可以换用：

```bash
nm -D BouncingBall.so | grep fmi3
# 或
objdump -T BouncingBall.so | grep fmi3
```

---

## 2.5 导入端如何使用这些文件

一个典型的导入流程如下：

```text
.fmu
  │
  ├─ 解包 ──> modelDescription.xml ──解析──> 接口类型、变量表、能力标志
  │
  └─ 按平台选 ──> binaries/<tuple>/<modelIdentifier>.dll
                        │
                        ├─ LoadLibrary / dlopen
                        ├─ GetProcAddress / dlsym 取 fmi3* 函数
                        ├─ fmi3Instantiate*
                        ├─ 按状态机调用
                        ├─ fmi3FreeInstance
                        └─ FreeLibrary / dlclose
```

用 C 写出来，核心就是这么几步（完整示例见 `examples/reference-fmus/examples/import_shared_library.c`）：

```c
HMODULE lib = LoadLibraryA("BouncingBall/binaries/x86_64-windows/BouncingBall.dll");

fmi3InstantiateModelExchangeTYPE *instantiate =
    (fmi3InstantiateModelExchangeTYPE *)GetProcAddress(lib, "fmi3InstantiateModelExchange");

fmi3Instance inst = instantiate(
    "instance1",          // 实例名
    INSTANTIATION_TOKEN,  // 必须来自 modelDescription.xml
    NULL,                 // resourcePath，没有 resources/ 时必须为 NULL
    fmi3False,            // visible
    fmi3False,            // loggingOn
    NULL,                 // instanceEnvironment
    logMessage);          // 日志回调

// ... 按状态机仿真 ...

fmi3FreeInstanceTYPE *freeInstance =
    (fmi3FreeInstanceTYPE *)GetProcAddress(lib, "fmi3FreeInstance");
freeInstance(inst);
FreeLibrary(lib);
```

几个要点：

- **`instantiationToken` 必须从 XML 读，不能自己编。**
- **`resourcePath` 指向解压后的 `resources/` 目录**（绝对路径，以路径分隔符结尾）；没有 `resources/` 时**必须为 `NULL`**。
- **函数指针的签名来自 `fmi3FunctionTypes.h`**，类型转换错误会导致很难查的崩溃。
- **卸载库之前必须先释放所有实例**，否则可能留下悬空回调。

---

## 2.6 二进制 FMU 与源码 FMU

FMI 允许两种分发方式，也可以同时提供：

| | 二进制 FMU | 源码 FMU |
| --- | --- | --- |
| 包含 | `.dll` / `.so` / `.dylib` / `.wasm` | `.c` / `.h` + `buildDescription.xml` |
| 导入端 | 直接加载 | 先编译，再加载 |
| 跨平台 | 只支持包内已有的平台 | 有编译器就能重新构建 |
| 启动速度 | 快 | 需要编译时间 |
| 知识产权 | 模型内部被隐藏 | 源码可见 |
| 调试 | 需要符号文件 | 可以直接调试 |

Reference FMUs 两者都提供，所以你既可以拿来直接跑，也可以改源码重新生成。

---

## 2.7 动手实验

### 实验 2-1：给文件分类

解包 `BouncingBall.fmu`，完成下表：

| 文件/目录 | 必需还是可选？ | 属于哪一类（描述/实现/文档/资源）？ |
| --- | --- | --- |
| `modelDescription.xml` | ? | ? |
| `binaries/x86_64-windows/BouncingBall.dll` | ? | ? |
| `sources/buildDescription.xml` | ? | ? |
| `documentation/index.html` | ? | ? |
| `extra/org.fmi-standard.fmi-ls-ref/` | ? | ? |

### 实验 2-2：数一数平台

用 2.1 节的 ZIP 列举命令，统计：

1. 一共有几个平台目录？
2. 哪些是 Windows，哪些是 Linux，哪些是 macOS？
3. 哪个平台的二进制最大？为什么？

### 实验 2-3：查看导出符号

用 `dumpbin` / `nm` 统计 `fmi3*` 符号数量，并找出：

- 初始化相关的函数；
- 步进相关的函数；
- SE 相关的函数（虽然这个 FMU 不支持 SE）。

### 实验 2-4：对比 FMI 2.0 和 3.0

解包 `examples/fmus/2.0/BouncingBall.fmu`，与 3.0 版本对比：

| 对比项 | FMI 2.0 | FMI 3.0 |
| --- | --- | --- |
| 根元素版本属性 | ? | ? |
| 实例标识 | ? | ? |
| 事件指示器数量写在哪 | ? | ? |
| 源码目录结构 | ? | ? |
| 平台目录命名 | ? | ? |

<details>
<summary>参考答案</summary>

| 对比项 | FMI 2.0 | FMI 3.0 |
| --- | --- | --- |
| 根元素版本属性 | `fmiVersion="2.0"` | `fmiVersion="3.0"` |
| 实例标识 | `guid="..."` | `instantiationToken="..."` |
| 事件指示器数量 | 根元素属性 `numberOfEventIndicators="1"` | `ModelStructure` 里的 `<EventIndicator valueReference="1"/>` |
| 源码目录结构 | `all.c` 作为单一编译单元（`#include` 其他 `.c`），无 `buildDescription.xml` | 多个 `.c` + `buildDescription.xml` |
| 平台目录命名 | `win32` / `win64` / `linux64` / `darwin64` | `x86-windows` / `x86_64-windows` / `x86_64-linux` / ... |

</details>

> 注意：2.0 的 Reference FMUs 包里还额外带了 `aarch64-darwin`、`aarch64-linux` 目录。这属于厂商扩展，不是 FMI 2.0 规范定义的元组，不能假定所有 2.0 导入端都认识。

### 实验 2-5：跑一下

如果已经编译过 Reference FMUs，可以直接用仓库里的 ME 示例程序：

```powershell
.\examples\reference-fmus\build\temp\BouncingBall_me.exe `
    .\examples\fmus\3.0\BouncingBall.fmu
```

观察它是否打印 `Running BouncingBall as Model Exchange...`，以及当前目录下是否生成了 `BouncingBall_me_out.csv`（仿真结果）和 `BouncingBall_me_log.txt`（FMI 调用日志）。这两个文件在仓库根目录，跑完可以删掉，不要提交。

### 实验 2-6：重新打包（容易出错）

把解压后的内容重新压缩成 FMU，要求：

- ZIP 根目录直接包含 `modelDescription.xml`，不能多一层文件夹；
- 使用 deflate 或 store；
- 扩展名改成 `.fmu`；
- 用 `fmusim` 或实验 2-5 的程序验证能正常加载。

<details>
<summary>PowerShell 示例</summary>

```powershell
# 进入解压目录，确保 modelDescription.xml 在当前目录
Set-Location $env:TEMP\BouncingBall
Compress-Archive -Path * -DestinationPath $env:TEMP\BouncingBall_repacked.zip -Force
Rename-Item $env:TEMP\BouncingBall_repacked.zip BouncingBall_repacked.fmu

# 检查 ZIP 根目录
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::OpenRead("$env:TEMP\BouncingBall_repacked.fmu").Entries |
    Select-Object -First 5 FullName
```

</details>

---

## 2.8 常见坑

**1. 多了一层目录**
压缩时把父文件夹打进去了，解压后 `modelDescription.xml` 不在根目录。导入端会报"找不到描述文件"。

**2. 用了不兼容的压缩方式**
7-Zip 的固实压缩、加密、分卷都不符合规范。用普通 deflate 即可。

**3. 只带了一个平台**
在 Windows 上能跑，拷到 Linux 就报"没有可用的二进制"。要么补平台，要么提供源码。

**4. 缺少运行时依赖**
DLL 依赖某个 VC Runtime 或第三方库，但没一起打包，也没在 `documentation/externalDependencies.txt` 里说明。加载时会出现"找不到模块"。

**5. 大小写不一致**
Windows 文件系统不区分大小写，Linux 区分。`modelIdentifier`、文件名、XML 里的引用必须完全一致。

**6. 改了 XML 却没更新 `instantiationToken`**
XML 和二进制不匹配时，FMU 可能拒绝实例化，或者行为异常。修改接口后应重新导出。

**7. 以为 `sources/` 是必需的**
二进制 FMU 可以完全没有源码。反之，源码 FMU 也可以没有二进制。

**8. 以为 FMU 就是一个 DLL**
DLL 只是实现的一部分。没有 XML，导入端不知道变量、接口和能力；没有正确的目录结构，DLL 也加载不起来。

**9. 在压缩包里直接改文件**
很多工具会校验 ZIP 结构或签名。正确做法是解压、修改、重新打包。

---

## 2.9 小结

- FMU 是一个有严格格式要求的 ZIP，扩展名 `.fmu`。
- `modelDescription.xml` 是唯一必需的**文件**，必须在根目录；此外还至少要有一份实现。
- 标准目录包括 `binaries/`、`sources/`、`resources/`、`documentation/`、`terminalsAndIcons/`、`extra/`。
- 至少要提供一种实现：二进制或源码。
- 平台元组格式为 `<arch>-<sys>[-<abi>]`，FMI 3.0 使用 `x86_64-windows` 这类命名。
- FMU 必须导出全部 `fmi3*` 函数，不支持的接口也要有桩函数。
- 导入端的流程是：解包 → 解析 XML → 按平台加载二进制 → 取函数指针 → 实例化 → 按状态机调用。

---

## 习题

### 1. 判断题

1. 一个 FMU 必须同时包含二进制和源码。
2. `modelDescription.xml` 可以放在 `documentation/` 目录里。
3. 平台目录名 `win64` 是 FMI 3.0 的合法写法。
4. 一个 FMU 可以同时支持 ME 和 CS。
5. FMU 里没有 `resources/` 时，`fmi3Instantiate*` 的 `resourcePath` 必须传一个空字符串。

<details>
<summary>答案</summary>

1. 错。二进制或源码至少有一种。
2. 错。必须在 ZIP 根目录。
3. 错。`win64` 是 FMI 2.0 的写法，3.0 是 `x86_64-windows`。
4. 对。
5. 错。没有 `resources/` 时规范要求传 `NULL`，不是空字符串。

</details>

### 2. 计算题

一个 FMU 解压后 1,246,618 字节，压缩后 363,815 字节。压缩比是多少？如果去掉 `sources/`（241,683 字节）再压缩，体积一定会显著变小吗？为什么？

<details>
<summary>提示</summary>

压缩比约为 3.43:1。去掉源码后体积会变小，但不一定"显著"，因为源码本身压缩率很高，而且二进制才是大头（约 898 KB）。实际体积取决于压缩算法和内容冗余度。

</details>

### 3. 排错题

某同事把一个 FMU 解压后，修改了 `modelDescription.xml` 里的变量名，然后用 7-Zip 重新压缩成 `.fmu`，结果导入端报错。请列出至少三个可能的原因。

<details>
<summary>参考答案</summary>

- 压缩时多了一层父目录，`modelDescription.xml` 不在 ZIP 根目录；
- 使用了 7-Zip 的固实压缩/加密，不符合 ZIP 限制；
- 修改了 XML 但二进制没有重新生成，`instantiationToken` 不匹配；
- 变量名改了但二进制里的 `valueReference` / 变量表没同步；
- 文件路径使用了反斜杠或大小写不一致。

</details>

### 4. 观察题

打开 `BouncingBall.fmu` 的 `documentation/index.html`，找到变量表，和 `modelDescription.xml` 里的 `<ModelVariables>` 对照：

1. 哪些变量是输出？
2. 哪些是参数？
3. `h_ft` 是什么？它为什么不在 `ModelVariables` 的顶层出现？

<details>
<summary>提示</summary>

`h`、`v` 是输出；`g`、`e` 是参数；`h_ft` 是 `h` 的别名（`<Alias>`），用于以英尺显示同一变量。

</details>

---

## 下一章

现在你已经知道 FMU 里"有什么"。下一章开始逐字段拆解 `modelDescription.xml`：变量、类型、单位、因果性、初始值、结构依赖，以及这些字段如何影响导入端的行为。

→ 第 3 章 `modelDescription.xml` 精读（待写）
