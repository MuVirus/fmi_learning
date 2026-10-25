# 文档导航

本目录存放 FMI 3.0 相关的全部文档，按「官方规范 → 辅助指南 → 中文讲义 → 分享材料」组织。

```
docs/
├─ spec-3.0.2/     # 官方规范 3.0.2（只读存档）
├─ guides/         # 官方/社区指南（离线 HTML）
├─ notes/          # 中文教学讲义（本项目编写）
└─ talks/          # 分享会材料（大纲 / 幻灯片 / 讲义）
```

## 1. 官方规范 `spec-3.0.2/`

| 路径 | 内容 | 适合什么时候看 |
| --- | --- | --- |
| [`html/index.html`](spec-3.0.2/html/index.html) | 单页完整规范，带目录、锚点和全部插图 | **主要阅读入口**，浏览器打开即可 |
| [`adoc/`](spec-3.0.2/adoc/) | 按章节拆分的 AsciiDoc 源文件 | 想按章精读、做笔记、提交勘误时 |
| [`schema/`](spec-3.0.2/schema/) | 12 个 XML Schema（`fmi3ModelDescription.xsd` 等） | 校验/生成 `modelDescription.xml` 时 |
| [`headers/`](spec-3.0.2/headers/) | `fmi3Functions.h`、`fmi3FunctionTypes.h`、`fmi3PlatformTypes.h` | 写 C 代码实现或调用 FMU 时 |

详见 [`spec-3.0.2/README.md`](spec-3.0.2/README.md)。各资料的版本、来源和校验值见 [`SOURCES.md`](SOURCES.md)。

## 2. 辅助指南 `guides/`

| 路径 | 说明 |
| --- | --- |
| [`implementers-guide/`](guides/implementers-guide/index.html) | FMI 3.0 Implementers' Guide：官方实现者指南，讲设计取舍、常见实现问题 |
| [`fmi-3.0-cheatsheet/`](https://dr-clementcoic.github.io/fmi-cheat-sheet/)（在线） | FMI 3.0 & FMPy 速查表：状态机、函数调用顺序、Python 示例；因原站未声明许可证，未纳入仓库 |
| [`fmusim-tutorial/`](guides/fmusim-tutorial/index.html) | fmusim 官方教程：解包、检查、仿真 FMU 的完整流程 |

详见 [`guides/README.md`](guides/README.md)。

## 3. 中文讲义 `notes/`

`notes/` 是课程正文。第一、二部分已完成初稿，第三部分已完成第 6–9 章：

- [第 1 章 为什么需要 FMI](notes/01-why-fmi.md)
- [第 2 章 解包一个 FMU](notes/02-unpack-fmu.md)
- [第 3 章 `modelDescription.xml` 精读](notes/03-model-description.md)
- [第 4 章 变量系统](notes/04-variables.md)
- [第 5 章 单位、类型与注解](notes/05-units-types-annotations.md)
- [第 6 章 公共状态机](notes/06-state-machine.md)
- [第 7 章 Model Exchange](notes/07-model-exchange.md)
- [第 8 章 Co-Simulation](notes/08-co-simulation.md)
- [第 9 章 Scheduled Execution 与 Clock](notes/09-scheduled-execution.md)

后续章节（三种接口状态机、动手实现）的大纲见 [`notes/README.md`](notes/README.md)。

## 4. 分享会材料 `talks/`

`talks/` 存放面向**对外分享 / 内部培训**的演示材料，按场次分子目录，每场先定大纲再做 PPT：

| 场次 | 受众 | 时长 | 主题 | 状态 |
| --- | --- | --- | --- | --- |
| [`fmi3-cs-intro`](talks/fmi3-cs-intro/outline.md) | 软件开发工程师 | 60 min | FMI 3.0 实战，以 Co-Simulation 为主线 | 大纲已定 |

场次索引和目录约定见 [`talks/README.md`](talks/README.md)。

## 阅读建议

- **规范 HTML** 是最完整的单一文件（约 800 KB），支持 `Ctrl+F` 搜索；章节锚点可直接分享，例如：
  - `html/index.html#fmi-common-concepts` — 第 2 章 公共概念
  - `html/index.html#modelDescription.xml` — 2.4 节 模型描述 Schema
  - `html/index.html#fmi-for-co-simulation` — 第 4 章 Co-Simulation
- 规范中的代码片段和 XML 示例同时存放在 `spec-3.0.2/adoc/examples/`，方便直接复制测试。
- 离线 HTML 只依赖字体/CDN 样式，正文和图片均可正常显示；如需完全离线样式，可断网打开（内容不受影响）。
