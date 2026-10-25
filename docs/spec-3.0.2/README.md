# FMI 3.0.2 官方规范

本目录是 [modelica/fmi-standard v3.0.2](https://github.com/modelica/fmi-standard/releases/tag/v3.0.2) 的离线存档（2024-11-27 发布）。

## 目录

| 目录/文件 | 说明 |
| --- | --- |
| `html/index.html` | **完整规范单页 HTML**，含目录、交叉引用和全部插图，推荐日常阅读 |
| `html/images/` | HTML 引用的 SVG / PNG 图片（含 `schema/` 下的 Schema 结构图） |
| `adoc/` | 规范的 AsciiDoc 源文件，一章一文件，便于搜索、引用和做笔记 |
| `adoc/examples/` | 规范中出现的完整 XML / C 代码示例 |
| `adoc/images/` | AsciiDoc 版引用的图片源文件（含 `.drawio` 源） |
| `schema/` | 12 个 XML Schema 定义文件 |
| `headers/` | FMI 3.0 C 接口头文件 |
| `CHANGELOG.md` | v3.0.2 发布说明（相对 3.0.1 的修正列表） |

## 规范章节速查

| 章节 | HTML 锚点 | AsciiDoc 源文件 |
| --- | --- | --- |
| 1. Introduction（含 1.1 What's new in FMI 3.0） | [`#_introduction`](html/index.html#_introduction) | `1___overview.adoc` |
| 2. Common Concepts | [`#fmi-common-concepts`](html/index.html#fmi-common-concepts) | `2___common_concepts.adoc` |
| 2.1 Mathematical Notation | [`#mathematical-definitions`](html/index.html#mathematical-definitions) | `2_1_common_math.adoc` |
| 2.2 General Mechanisms（变量、时钟、事件等） | [`#general-mechanisms`](html/index.html#general-mechanisms) | `2_2_common_mechanisms.adoc` |
| 2.3 State Machine and Semantics | [`#common-state-machine`](html/index.html#common-state-machine) | `2_3_common_states.adoc` |
| 2.4 FMI Description Schema | [`#modelDescription.xml`](html/index.html#modelDescription.xml) | `2_4_common_schema.adoc` |
| 2.5 FMU Distribution | [`#fmu-distribution`](html/index.html#fmu-distribution) | `2_5_fmu_distribution.adoc` |
| 2.6 Versioning and Layered Standards | [`#VersioningLayered`](html/index.html#VersioningLayered) | `2_6_versioning_layered_standards.adoc` |
| 3. FMI for Model Exchange | [`#fmi-for-model-exchange`](html/index.html#fmi-for-model-exchange) | `3___model_exchange.adoc` |
| 3.1 Concepts | [`#concepts-model-exchange`](html/index.html#concepts-model-exchange) | `3_1_model_exchange_math.adoc` |
| 3.2 State Machine | [`#state-machine-model-exchange`](html/index.html#state-machine-model-exchange) | `3_2_model_exchange_api.adoc` |
| 3.3 Code Example | [`#_code_example`](html/index.html#_code_example) | `3_3_model_exchange_example.adoc` |
| 3.4 Description Schema | [`#model-exchange-schema`](html/index.html#model-exchange-schema) | `3_4_model_exchange_schema.adoc` |
| 4. FMI for Co-Simulation | [`#fmi-for-co-simulation`](html/index.html#fmi-for-co-simulation) | `4___co-simulation.adoc` |
| 4.1 Concepts | [`#concepts-co-simulation`](html/index.html#concepts-co-simulation) | `4_1_co-simulation_math.adoc` |
| 4.2 State Machine | [`#state-machine-co-simulation`](html/index.html#state-machine-co-simulation) | `4_2_co-simulation_api.adoc` |
| 4.3 Code Examples | [`#_code_examples`](html/index.html#_code_examples) | `4_3_co-simulation_example.adoc` |
| 4.4 Description Schema | [`#co-simulation-schema`](html/index.html#co-simulation-schema) | `4_4_co-simulation_schema.adoc` |
| 5. FMI for Scheduled Execution | [`#fmi-for-scheduled-execution`](html/index.html#fmi-for-scheduled-execution) | `5___scheduled_execution.adoc` |
| 5.1 Concepts | [`#concepts-scheduled-execution`](html/index.html#concepts-scheduled-execution) | `5_1_scheduled_execution_math.adoc` |
| 5.2 State Machine | [`#state-machine-scheduled-execution`](html/index.html#state-machine-scheduled-execution) | `5_2_scheduled_execution_api.adoc` |
| 5.3 Code Example | [`#example-scheduled-execution`](html/index.html#example-scheduled-execution) | `5_3_scheduled_execution_example.adoc` |
| 5.4 Description Schema | [`#scheduled-execution-schema`](html/index.html#scheduled-execution-schema) | `5_4_scheduled_execution_schema.adoc` |
| Appendix A: Glossary（术语表） | [`#glossary`](html/index.html#glossary) | `7___appendix.adoc` |
| References | [`#_references`](html/index.html#_references) | `6___literature.adoc` |

## XML Schema（`schema/`）

| 文件 | 作用 |
| --- | --- |
| `fmi3ModelDescription.xsd` | **入口 Schema**，校验 `modelDescription.xml` |
| `fmi3InterfaceType.xsd` | `ModelExchange` / `CoSimulation` / `ScheduledExecution` 元素 |
| `fmi3Variable.xsd` | 变量定义（`Float32/64`、`Int*`、`Boolean`、`String`、`Binary`、`Clock` 等） |
| `fmi3Type.xsd` | 用户自定义类型（`Float32Type`、`EnumerationType` 等） |
| `fmi3Unit.xsd` | 单位与 `DisplayUnit` 定义 |
| `fmi3VariableDependency.xsd` | 变量依赖关系 |
| `fmi3BuildDescription.xsd` | `buildDescription.xml`（源码分发） |
| `fmi3Annotation.xsd` | 供应商扩展注解 |
| `fmi3Terminal.xsd` | Terminal 定义（FMI 3.0 新增） |
| `fmi3TerminalsAndIcons.xsd` | `terminalsAndIcons/terminalsAndIcons.xml` |
| `fmi3LayeredStandardManifest.xsd` | 分层标准清单 `fmi-ls-manifest.xml` |
| `fmi3AttributeGroups.xsd` | 公共属性组 |

## C 头文件（`headers/`）

| 文件 | 内容 |
| --- | --- |
| `fmi3PlatformTypes.h` | 平台相关类型（`fmi3Float64`、`fmi3ValueReference`、`fmi3Instance` 等） |
| `fmi3FunctionTypes.h` | 所有回调函数类型与 `fmi3CallbackFunctions` 结构 |
| `fmi3Functions.h` | FMU 必须导出的 `fmi3*` 函数声明与版本宏 |

## 用法提示

- 直接双击 `html/index.html` 用浏览器打开即可离线阅读。
- 想全文检索某一术语（例如 `structural parameter`），推荐在 `adoc/` 目录用编辑器全局搜索，比 HTML 更方便定位段落。
- 校验 XML 时，`schema/fmi3ModelDescription.xsd` 通过 `xs:include` 引用同目录其他 XSD，**不要单独移动某个 XSD 文件**。
