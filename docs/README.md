# 文档导航

本目录存放 FMI 3.0 相关的全部文档，按「官方规范 → 辅助指南 → 中文讲义」组织。

```
docs/
├─ spec-3.0.2/     # 官方规范 3.0.2（只读存档）
├─ guides/         # 官方/社区指南（离线 HTML）
└─ notes/          # 中文教学讲义（本项目编写）
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

`notes/` 是后续要写的教学内容，目前只有大纲，见 [`notes/README.md`](notes/README.md)。计划覆盖：

1. FMI 是什么、解决什么问题
2. FMU 内部结构解剖
3. `modelDescription.xml` 逐字段讲解
4. 变量类型、variability、initial 与别名
5. Model Exchange 状态机与调用顺序
6. Co-Simulation 状态机与步长控制
7. Scheduled Execution 与 Clock
8. 事件处理：状态事件、时间事件、步事件
9. 用 C 实现一个最小 FMU
10. 用 C / Python 导入并仿真 FMU
11. 构建、打包与合规性检查
12. 常见错误与调试技巧

## 阅读建议

- **规范 HTML** 是最完整的单一文件（约 800 KB），支持 `Ctrl+F` 搜索；章节锚点可直接分享，例如：
  - `html/index.html#fmi-common-concepts` — 第 2 章 公共概念
  - `html/index.html#modelDescription.xml` — 2.4 节 模型描述 Schema
  - `html/index.html#fmi-for-co-simulation` — 第 4 章 Co-Simulation
- 规范中的代码片段和 XML 示例同时存放在 `spec-3.0.2/adoc/examples/`，方便直接复制测试。
- 离线 HTML 只依赖字体/CDN 样式，正文和图片均可正常显示；如需完全离线样式，可断网打开（内容不受影响）。
