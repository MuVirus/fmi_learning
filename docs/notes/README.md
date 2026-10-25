# 中文教学讲义（大纲）

这是后续要编写的中文课程内容。每章计划包含：**概念讲解 → 规范原文对应章节 → 代码/XML 实例 → 练习**。

## 第一部分：入门

- [ ] **第 1 章 为什么需要 FMI**
  - 模型交换与联合仿真的痛点
  - FMI、FMU、FMI 版本（1.0 / 2.0 / 3.0）的关系
  - ME / CS / SE 三种接口该选哪个
  - 规范：1.2 节 Overview
- [ ] **第 2 章 解包一个 FMU**
  - FMU 就是一个 ZIP：`modelDescription.xml` + 二进制 + 资源
  - 目录布局、`binaries/` 平台元组、`sources/`、`resources/`、`documentation/`
  - 动手：解包 `examples/fmus/3.0/BouncingBall.fmu`，画出目录树
  - 规范：2.5 节 FMU Distribution

## 第二部分：看懂描述文件

- [ ] **第 3 章 `modelDescription.xml` 精读**
  - 根元素属性：`fmiVersion`、`modelName`、`GUID`
  - `ModelExchange` / `CoSimulation` / `ScheduledExecution` 元素
  - `DefaultExperiment`、`UnitDefinitions`、`TypeDefinitions`
  - 动手：用 XSD 校验 `FMI3.xml`
  - 规范：2.4 节
- [ ] **第 4 章 变量系统**
  - 数据类型：Float32/64、Int8~64、Boolean、String、Binary、Clock、Enumeration
  - `variability`（constant / fixed / tunable / discrete / continuous）
  - `causality`（parameter / calculatedParameter / input / output / local / independent）
  - `initial`、`reinit`、别名（`aliases`）、`ValueReference`
  - 结构参数与数组（`dimension`、`start` 列表）
  - 规范：2.2 节 General Mechanisms
- [ ] **第 5 章 单位、类型与注解**
  - `UnitDefinitions` / `DisplayUnit`
  - 自定义类型与枚举
  - `annotations` 与供应商扩展
  - 规范：2.4 节

## 第三部分：接口与状态机

- [ ] **第 6 章 公共状态机**
  - 实例生命周期、`fmi3Instantiate*` / `fmi3FreeInstance`
  - 状态迁移图逐条解读
  - 规范：2.3 节
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

## 第四部分：动手实现

- [ ] **第 10 章 写一个最小 FMU（ME）**
  - 从 `BouncingBall` 裁剪出最小骨架
  - 实现 5 个必需函数 + 初始化
  - 编译、打包、用 fmusim 验证
- [ ] **第 11 章 写一个最小 FMU（CS）**
  - `fmi3DoStep` 的三种实现策略
  - 事件处理与早返回
- [ ] **第 12 章 构建与打包**
  - `buildDescription.xml` 与源码分发
  - 平台元组、`binaries/` 布局、GUID 生成
  - 常见错误：DLL 导出名、依赖缺失、路径分隔符
- [ ] **第 13 章 导入端开发**
  - 用 C 加载共享库、取函数指针
  - 用 Python / FMPy 快速验证
  - 用 `fmusim` 查看调用日志
- [ ] **第 14 章 调试与合规性**
  - XML Schema 校验
  - 用 fmusim / FMPy 做回归测试
  - 常见状态机错误与日志特征

## 附录

- [ ] 术语中英对照表（以规范 Appendix A Glossary 为基准）
- [ ] FMI 3.0 相对 2.0 的变化清单
- [ ] 常用工具清单（fmusim、FMPy、FMI Kit、Dymola、OpenModelica 等）

> 写作时请同步标注对应的规范章节锚点，方便读者在 `docs/spec-3.0.2/html/index.html` 中定位原文。
