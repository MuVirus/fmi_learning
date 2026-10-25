# 中文教学讲义

本目录是配套 FMI 3.0 规范的中文课程。每章统一结构：

**学习目标 → 对应规范章节 → 概念讲解 → 代码/XML 实例 → 动手实验 → 小结与习题**

## 阅读方式

- **第一次学**：按章顺序读，先完成第一部分，再进入 XML 和状态机。
- **查漏补缺**：每章开头的"对应规范"链接可直接跳到本地 HTML 的对应锚点。
- **动手**：所有示例都来自本仓库，命令默认在仓库根目录执行。
- **版本**：基于 FMI 3.0.2（2024-11）；与 3.0 / 3.0.1 兼容。

## 进度

| 部分 | 章节 | 状态 |
| --- | --- | --- |
| 第一部分 入门 | 第 1–2 章 | ✅ 初稿 |
| 第二部分 看懂描述文件 | 第 3–5 章 | ✅ 初稿 |
| 第三部分 接口与状态机 | 第 6–9 章 | 🚧 第 6 章初稿 |
| 第四部分 动手实现 | 第 10–14 章 | 待写 |

---

## 第一部分：入门（初稿）

- [x] **第 1 章 为什么需要 FMI** → [01-why-fmi.md](01-why-fmi.md)
  - 模型交换与联合仿真的痛点
  - FMI、FMU、导出端与导入端
  - ME / CS / SE 三种接口该选哪个
  - FMI 3.0 的新能力与能力边界
  - 规范：[1.2 Overview](../spec-3.0.2/html/index.html#_overview)
- [x] **第 2 章 解包一个 FMU** → [02-unpack-fmu.md](02-unpack-fmu.md)
  - FMU 就是一个 ZIP：`modelDescription.xml` + 二进制 + 资源
  - 目录布局、`binaries/` 平台元组、`sources/`、`resources/`、`documentation/`
  - 动手：解剖 `BouncingBall.fmu`，用 `dumpbin` 看导出符号
  - 导入端加载 FMU 的完整流程
  - 规范：[2.5 FMU Distribution](../spec-3.0.2/html/index.html#fmu-distribution)

---

## 第二部分：看懂描述文件（初稿）

- [x] **第 3 章 `modelDescription.xml` 精读** → [03-model-description.md](03-model-description.md)
  - 根元素属性：`fmiVersion`、`modelName`、`instantiationToken`（对比 2.0 的 `guid`）
  - `ModelExchange` / `CoSimulation` / `ScheduledExecution` 元素与能力标志
  - `DefaultExperiment`、`LogCategories`、`ModelStructure`
  - 动手：用 XSD 校验 `FMI3.xml`，并理解 XSD 查不出的语义
  - 规范：[2.4 节](../spec-3.0.2/html/index.html#modelDescription.xml)
- [x] **第 4 章 变量系统** → [04-variables.md](04-variables.md)
  - 数据类型：Float32/64、Int8~64、Boolean、String、Binary、Clock、Enumeration
  - `variability`（constant / fixed / tunable / discrete / continuous）
  - `causality`（parameter / calculatedParameter / structuralParameter / input / output / local / independent）
  - `initial`、`reinit`、别名（`Alias`）、`valueReference`
  - 结构参数与数组（`Dimension`、`start` 列表、行优先序列化）
  - 命名约定（`flat` / `structured`）与 Clock 变量速览
  - 规范：[2.4.7 Model Variables](../spec-3.0.2/html/index.html#ModelVariables)
- [x] **第 5 章 单位、类型与注解** → [05-units-types-annotations.md](05-units-types-annotations.md)
  - `UnitDefinitions` / `BaseUnit` / `DisplayUnit` 与换算公式
  - `TypeDefinitions`、`declaredType` 的默认值与覆盖规则、枚举
  - `Annotations` 与供应商扩展
  - `terminalsAndIcons.xml`：端子分组、匹配规则、图标
  - 动手：结构校验 + 语义检查脚本，完整一致性清单
  - 规范：[2.4 节](../spec-3.0.2/html/index.html#modelDescription.xml)

## 第三部分：接口与状态机（第 6 章初稿）

- [x] **第 6 章 公共状态机** → [06-state-machine.md](06-state-machine.md)
  - 实例生命周期、`fmi3Instantiate*` 参数与失败处理
  - `FMU State Settable` / `Initialized` 两个超级状态
  - `Instantiated`、`InitializationMode`、`EventMode`、`Terminated`
  - `ConfigurationMode` 与 `ReconfigurationMode` 的区别
  - 事件迭代：`fmi3UpdateDiscreteStates` 的输出标志与循环写法
  - 动手：从 XML 读能力标志、抽取 ME/CS/SE 调用序列、对照 Reference 状态掩码
  - 规范：[2.3 节](../spec-3.0.2/html/index.html#common-state-machine)
- [ ] **第 7 章 Model Exchange**
  - 连续时间模式、事件模式、`fmi3EnterEventMode`
  - 导数、离散状态、事件指示器
  - 调用序列：`simulate_fmi3_me.c` 逐行讲解
  - 规范：3.1 / 3.2 / 3.3 节
- [ ] **第 8 章 Co-Simulation**
  - 步进接口 `fmi3DoStep`、早返回、中间更新
  - 通信步长与 `fmi3Set{Interval|Shift}Fraction`
  - 调用序列：`simulate_fmi3_cs.c` 逐行讲解
  - 规范：4.1 / 4.2 / 4.3 节
- [ ] **第 9 章 Scheduled Execution 与 Clock**
  - Clock 的种类（周期性、触发式、通信点时钟）
  - 时钟激活、`fmi3ActivateModelPartition`
  - 与 CS 的本质区别
  - 规范：5.1 / 5.2 / 5.3 节

## 第四部分：动手实现（待写）

- [ ] **第 10 章 写一个最小 FMU（ME）**
  - 从 `BouncingBall` 裁剪出最小骨架
  - 实现必需函数 + 初始化
  - 编译、打包、用 fmusim 验证
- [ ] **第 11 章 写一个最小 FMU（CS）**
  - `fmi3DoStep` 的三种实现策略
  - 事件处理与早返回
- [ ] **第 12 章 构建与打包**
  - `buildDescription.xml` 与源码分发
  - 平台元组、`binaries/` 布局、`instantiationToken` 生成
  - 常见错误：DLL 导出名、依赖缺失、路径分隔符
- [ ] **第 13 章 导入端开发**
  - 用 C 加载共享库、取函数指针
  - 用 Python / FMPy 快速验证
  - 用 `fmusim` 查看调用日志
- [ ] **第 14 章 调试与合规性**
  - XML Schema 校验
  - 用 fmusim / FMPy 做回归测试
  - 常见状态机错误与日志特征

## 附录（待写）

- [ ] 术语中英对照表（以规范 Appendix A Glossary 为基准）
- [ ] FMI 3.0 相对 2.0 的变化清单
- [ ] 常用工具清单（fmusim、FMPy、FMI Kit、Dymola、OpenModelica 等）

---

## 写作约定

- 文件名：`NN-topic.md`，例如 `03-model-description.md`。
- 每章开头标注对应规范章节和本地锚点。
- 代码、XML、命令必须能在本仓库复现。
- 习题答案放在 `<details>` 折叠块里，避免直接剧透。
- 中文术语第一次出现时附英文，例如"导入端（importer）"。
