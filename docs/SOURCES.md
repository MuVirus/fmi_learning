# 资料出处与校验信息

记录每份资料的来源、版本、抓取时间和校验值，便于日后更新或复核。

## FMI 3.0.2 规范

| 项目 | 内容 |
| --- | --- |
| 版本 | FMI 3.0.2（2024-11-27） |
| 仓库 | <https://github.com/modelica/fmi-standard> |
| Tag / Commit | `v3.0.2` / `b8778deaf5b746ba4a2f6c155d53f8a33eebbd33` |
| 抓取方式 | `git clone --depth 1 --branch v3.0.2`；HTML 抓自 <https://fmi-standard.org/docs/3.0.2/> |
| 抓取时间 | 2026-10-25 |
| HTML SHA-256 | `FB8B39B0A74A9AFF8D84A4E15FFCE3AF3571FB474F2B8AF120D9B8382CD5C739` |

存档内容：

- `docs/spec-3.0.2/html/`：规范单页 HTML + 全部图片（含从官网补下的 40 张 Schema 结构图）
- `docs/spec-3.0.2/adoc/`：仓库 `docs/` 下的 AsciiDoc 源文件与示例
- `docs/spec-3.0.2/schema/`：仓库 `schema/*.xsd`
- `docs/spec-3.0.2/headers/`：仓库 `headers/fmi3*.h`
- `docs/spec-3.0.2/CHANGELOG.md`：v3.0.2 Release Notes

> HTML 版中的 Schema 图片在仓库里是构建时生成的（`docs/images/schema/` 默认只有 `.gitignore`），因此额外从官网抓取并补齐。

## Reference FMUs

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.0.42 |
| 仓库 | <https://github.com/modelica/Reference-FMUs> |
| Commit | `75d16f87da2fba3c552c99cd683128a9591c1fa3` |
| Release 包 | <https://github.com/modelica/Reference-FMUs/releases/download/v0.0.42/Reference-FMUs.zip> |
| Release SHA-256 | `B6B4A195B9C0F6BDD3459CD949CBB35FC21EE2049D6DAB4CB7A3BA7DA63B1E97` |
| 抓取时间 | 2026-10-25 |

存档内容：

- `examples/reference-fmus/`：完整源码仓库（去掉 `.git` 和 `build/`）
- `examples/fmus/2.0/`、`examples/fmus/3.0/`：Release 包中的预编译 FMU
- `examples/fmus/LICENSE.txt`：Release 包中的 BSD-2 许可

本机另用 Visual Studio 2022 + CMake 4.4.2 验证编译通过，产物在 `examples/reference-fmus/build/`（已被 `.gitignore` 忽略）。

## 辅助指南

| 资料 | 在线地址 | 存档路径 | 抓取时间 |
| --- | --- | --- | --- |
| FMI 3.0 Implementers' Guide | <https://modelica.github.io/fmi-guides/main/fmi-guide/> | `docs/guides/implementers-guide/` | 2026-10-25 |
| FMI 3.0 & FMPy Cheatsheet | <https://dr-clementcoic.github.io/fmi-cheat-sheet/> | 仅在线（原站未声明许可证） | 2026-10-25 |
| fmusim Tutorial | <https://modelica.github.io/fmusim/tutorial/> | `docs/guides/fmusim-tutorial/` | 2026-10-25 |

指南均为单页 HTML，已连同 CSS/JS/图片一起存档；外部链接仍需联网。

## 更新方法

```powershell
# 规范（更新到新 tag 时替换 v3.0.2）
git clone --depth 1 --branch v3.0.2 https://github.com/modelica/fmi-standard.git
# Reference FMUs
git clone --depth 1 https://github.com/modelica/Reference-FMUs.git
# 预编译 FMU
curl.exe -L -o Reference-FMUs.zip `
  https://github.com/modelica/Reference-FMUs/releases/latest/download/Reference-FMUs.zip
```
