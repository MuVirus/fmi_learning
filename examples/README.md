# 示例与代码

```
examples/
├─ reference-fmus/   # 官方 Reference FMUs：C 源码 + 导入端示例（FMI 2.0 / 3.0）
└─ fmus/             # 预编译好的 FMU 文件，用于直接练习导入/仿真
```

## Reference FMUs

来源：<https://github.com/modelica/Reference-FMUs>（v0.0.42，2-Clause BSD）。

一组**手写**的 FMU，不依赖建模工具，专门用于验证、开发、测试和调试 FMI 实现。每个模型目录都同时提供 `FMI2.xml` 和 `FMI3.xml`，可以直接对比 FMI 2.0 与 3.0 的描述差异。

### 模型一览

| 模型 | 演示的 FMI 特性 | 适合用来学 |
| --- | --- | --- |
| [`BouncingBall`](reference-fmus/BouncingBall) | 状态事件、连续状态、参数 | **第一个例子**：初始化、事件模式、重初始化 |
| [`Dahlquist`](reference-fmus/Dahlquist) | 线性测试方程、解析解 | 校验积分精度、步长控制 |
| [`Feedthrough`](reference-fmus/Feedthrough) | 所有变量类型、数组、别名、单位 | `modelDescription.xml` 字段最全的参考 |
| [`Resource`](reference-fmus/Resource) | 从 FMU 资源目录读取文件 | `resources/` 目录与 `fmi3GetString` 等 API |
| [`Roberts`](reference-fmus/Roberts) | 刚性 DAE、代数环 | 隐式求解、Jacobian |
| [`Stair`](reference-fmus/Stair) | 时间事件、计数器 | 事件处理与 `nextEventTime` |
| [`StateSpace`](reference-fmus/StateSpace) | 数组变量、结构参数 | FMI 3.0 数组与 `fmi3Set*` 批量接口 |
| [`VanDerPol`](reference-fmus/VanDerPol) | 非线性 ODE | 与解析/参考轨迹对比 |

> `Clocks` 目录演示 FMI 3.0 的 Clock 与 Scheduled Execution；`Wasm` 演示 WebAssembly 平台。

### 目录结构（每个模型）

```
BouncingBall/
├─ model.c             # 模型方程与状态更新
├─ config.h            # 变量 ValueReference、类型、初始化配置
├─ FMI3.xml            # FMI 3.0 modelDescription.xml
├─ FMI2.xml            # FMI 2.0 版本，便于对照
├─ buildDescription.xml# 源码分发描述（FMI 3.0）
├─ fmi-ls-ref.xml      # 分层标准（Reference）清单
└─ BouncingBall_out.csv# 参考仿真输出
```

### 通用实现代码

| 路径 | 内容 |
| --- | --- |
| `include/fmi3Functions.h` 等 | FMI 3.0 头文件（与 `docs/spec-3.0.2/headers` 相同） |
| `src/fmi3Functions.c` | FMI 3.0 接口层：状态机、类型转换、数组处理 |
| `src/cosimulation.c` | CS 步进、事件处理、早返回等通用逻辑 |
| `src/FMI.c` | FMI 2.0 / 3.0 公共辅助函数 |

### 导入端示例（重点）

`reference-fmus/examples/` 下是**调用 FMU 的完整 C 程序**，非常适合对照规范学习调用顺序：

| 文件 | 说明 |
| --- | --- |
| `simulate_fmi3_me.c` | FMI 3.0 Model Exchange 完整仿真循环（含事件处理） |
| `simulate_fmi3_cs.c` | FMI 3.0 Co-Simulation 仿真循环 |
| `simulate_fmi2_me.c` / `simulate_fmi2_cs.c` | FMI 2.0 对应实现，便于对比 |
| `cs_event_mode.c` | 事件模式下的 CS 调用流程 |
| `cs_early_return.c` | 早返回（`fmi3EarlyReturn`）处理 |
| `cs_intermediate_update.c` | 中间更新（`fmi3IntermediateUpdate`） |
| `cs_reconfiguration.c` | 运行时重配置 |
| `scs_synchronous.c` / `scs_threaded.c` | Scheduled Execution 单线程/多线程示例 |
| `import_shared_library.c` / `import_static_library.c` | 两种二进制链接方式 |
| `Feedthrough.c` | 遍历所有变量类型读写 |

### 编译

需要 CMake 和支持 C99 的编译器（Windows 上可用 Visual Studio 或 MinGW）：

```powershell
cd examples/reference-fmus
cmake -B build .
cmake --build build --config Release
```

生成的 FMU 在 `build/fmus/` 下（同时包含 2.0 和 3.0）。也可以只编译某个模型：

```powershell
cmake --build build --target BouncingBall
```

## 预编译 FMU

`fmus/` 是 [Reference-FMUs v0.0.42 release](https://github.com/modelica/Reference-FMUs/releases/tag/v0.0.42) 的原始包，按 FMI 版本分目录：

- `fmus/3.0/`：9 个 FMI 3.0 FMU（BouncingBall、Clocks、Dahlquist、Feedthrough、Resource、Roberts、Stair、StateSpace、VanDerPol）
- `fmus/2.0/`：6 个 FMI 2.0 FMU（无 Clocks、Roberts、StateSpace）
- `fmus/LICENSE.txt`：2-Clause BSD 许可

每个 `.fmu` 内含多平台二进制，解包后可见：

```
modelDescription.xml
binaries/x86_64-windows/*.dll
binaries/x86-windows/*.dll
binaries/x86_64-linux/*.so
binaries/aarch64-linux/*.so
binaries/aarch64-darwin/*.dylib
binaries/wasm32-wasip2/*.wasm
documentation/index.html, result.svg
sources/...
extra/org.fmi-standard.fmi-ls-ref/...
```

所以同一份 FMU 可以直接拷到 Windows / Linux / macOS，或用支持 WASM 的导入端运行。适合还没装编译环境时直接做导入练习。

> 本仓库也已在 `reference-fmus/build/fmus/` 下生成了一份本机编译的 Windows 版本（`build/` 已被 `.gitignore` 忽略），可与 release 版对照。


## 下一步

- 想改模型：从 `BouncingBall/model.c` 入手，改完重新编译即可。
- 想做导入端：先读 `examples/simulate_fmi3_me.c`，再用 `fmusim` 对照调用日志。
- 想验证 XML：用 `docs/spec-3.0.2/schema/fmi3ModelDescription.xsd` 校验 `FMI3.xml`。
