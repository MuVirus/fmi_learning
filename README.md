# FMI 3.0 教学项目

从零开始学习 **FMI 3.0（Functional Mock-up Interface）** 的教学仓库：规范原文、官方参考实现、辅助指南，以及后续要编写的中文讲义和练习。

## 目录结构

```
fmi_learning/
├─ docs/                        # 所有文档
│  ├─ spec-3.0.2/              # FMI 3.0.2 官方规范
│  │  ├─ html/                 #   可离线阅读的 HTML（含图片）
│  │  ├─ adoc/                 #   按章节拆分的 AsciiDoc 源文件
│  │  ├─ schema/               #   XML Schema（*.xsd）
│  │  └─ headers/              #   C 接口头文件（fmi3*.h）
│  ├─ guides/                  # 官方/社区指南（Implementers' Guide、速查表等）
│  ├─ notes/                   # 中文教学讲义（第 1–9 章已完成初稿）
│  └─ talks/                   # 分享会材料（大纲 / 幻灯片 / 讲义）
├─ examples/                    # 所有代码与示例
│  ├─ reference-fmus/          # 官方 Reference FMUs（C 源码）
│  ├─ fmus/                    # 预编译好的 FMU 包（FMI 2.0 / 3.0）
│  ├─ xml/                     # 教学用的最小 modelDescription.xml 示例
│  └─ scripts/                 # XSD 校验与语义检查脚本（PowerShell）
└─ tools/                       # 自研工具（规划中，如 FMU 检查器）
```

每个目录下都有 `README.md` 说明用途和用法，建议从 [`docs/README.md`](docs/README.md) 开始；课程正文从 [`docs/notes/README.md`](docs/notes/README.md) 开始。

## 快速开始

1. **浏览规范**：用浏览器打开 [`docs/spec-3.0.2/html/index.html`](docs/spec-3.0.2/html/index.html)，左侧有完整目录，可离线阅读。
2. **对照源码**：打开 [`examples/reference-fmus/BouncingBall/`](examples/reference-fmus/BouncingBall)，这是最小的 FMI 3.0 示例之一（小球弹跳，含状态事件），包含 `model.c`、`FMI3.xml`、`config.h`。
3. **编译 FMU**（需要 CMake + C 编译器）：

   ```powershell
   cd examples/reference-fmus
   cmake -B build .
   cmake --build build
   # 生成的 FMU 位于 build/fmus/
   ```

4. **直接运行现成 FMU**：预编译的 FMU 在 [`examples/fmus/3.0/`](examples/fmus/3.0)，解包或交给导入端即可：

   ```powershell
   # 方式 A：用 fmusim（需先安装，见 https://modelica.github.io/fmusim/）
   fmusim .\examples\fmus\3.0\BouncingBall.fmu --show-model-description

   # 方式 B：用仓库里已编译好的 FMI 3.0 ME 示例程序
   .\examples\reference-fmus\build\temp\BouncingBall_me.exe `
       .\examples\fmus\3.0\BouncingBall.fmu
   ```

5. **校验描述文件**：用仓库脚本对任意 `modelDescription.xml` 做 XSD 校验和语义检查：

   ```powershell
   .\examples\scripts\validate-model-description.ps1 .\examples\reference-fmus\BouncingBall\FMI3.xml
   .\examples\scripts\check-model-description.ps1    .\examples\reference-fmus\BouncingBall\FMI3.xml
   ```

## 建议学习路线

| 阶段 | 目标 | 对应资料 |
| --- | --- | --- |
| 1. 建立概念 | 搞清楚 ME / CS / SE 三种接口、FMU 是什么 | 规范第 1 章、[速查表](docs/guides/fmi-3.0-cheatsheet/index.html) |
| 2. 看懂 FMU | 会解包 FMU，读懂 `modelDescription.xml` | 规范 2.4 节、`examples/reference-fmus/*/FMI3.xml` |
| 3. 掌握状态机 | 理解初始化、事件模式、步进与终止流程 | 规范 2.3 / 3.2 / 4.2 / 5.2 节 |
| 4. 动手实现 | 编译、修改、调试一个 FMU | `examples/reference-fmus` |
| 5. 做导入端 | 用 C 或 Python 调用 FMU 的 FMI 函数 | 规范 3.3/4.3 节、`examples/reference-fmus/examples/` |
| 6. 进阶主题 | 时钟、数组、结构参数、分层标准 | 规范 2.2/2.6 节、`docs/notes/` |

## 资料版本与来源

| 资料 | 版本 | 来源 |
| --- | --- | --- |
| FMI 规范 | **3.0.2**（2024-11-27） | [modelica/fmi-standard @ v3.0.2](https://github.com/modelica/fmi-standard/releases/tag/v3.0.2) |
| Reference FMUs | **v0.0.42** | [modelica/Reference-FMUs](https://github.com/modelica/Reference-FMUs) |
| FMI 3.0 Implementers' Guide | main | [modelica.github.io/fmi-guides](https://modelica.github.io/fmi-guides/main/fmi-guide/) |
| FMI 3.0 & FMPy Cheatsheet | 在线版（未存档） | [dr-clementcoic.github.io/fmi-cheat-sheet](https://dr-clementcoic.github.io/fmi-cheat-sheet/) |
| fmusim 教程 | 在线版 | [modelica.github.io/fmusim/tutorial](https://modelica.github.io/fmusim/tutorial/) |

> FMI 3.0.2 是 3.0 系列的维护版本，只做澄清和修正，不引入新特性；按 3.0.2 生成的 FMU 与 3.0 / 3.0.1 互相兼容。完整来源、Commit 和 SHA-256 见 [`docs/SOURCES.md`](docs/SOURCES.md)。

## 许可说明

- **FMI 规范正文**：CC BY-SA 4.0；随附的 C 头文件、XML Schema 等源码数据：BSD-2-Clause。版权归 Modelica Association Project FMI，完整许可见 [`docs/spec-3.0.2/LICENSE.txt`](docs/spec-3.0.2/LICENSE.txt)。
- **FMI Implementers' Guide**：文档 CC BY-SA 4.0，随附代码 BSD-2-Clause，见 [`docs/guides/implementers-guide/LICENSE.txt`](docs/guides/implementers-guide/LICENSE.txt)。
- **Reference FMUs**：代码与预编译 FMU 均为 BSD-2-Clause，见 [`examples/reference-fmus/LICENSE.txt`](examples/reference-fmus/LICENSE.txt) 和 [`examples/fmus/LICENSE.txt`](examples/fmus/LICENSE.txt)。
- **FMPy 速查表**：原站未声明许可证，因此未纳入本仓库，仅提供在线链接。
- **本项目原创内容**：中文讲义与工具代码暂未指定许可证，后续补充。
