# FMI 3.0.2 发布说明

> 来源：<https://github.com/modelica/fmi-standard/releases/tag/v3.0.2>（2024-11-27）

FMI 3.0.2 is a maintenance release with clarifications and bugfixes and no new features compared to FMI 3.0.1.
FMUs created according to FMI 3.0.2 are valid FMUs according to FMI 3.0 and FMI 3.0.1 and vice versa.

## What's Changed

- Add explicit void argument to preemption callbacks by @t-sommer in https://github.com/modelica/fmi-standard/pull/1899
- Update CONTRIBUTING.adoc by @chrbertsch in https://github.com/modelica/fmi-standard/pull/1900
- Remove angle brackets from Float{32|64} in variability section by @t-sommer in https://github.com/modelica/fmi-standard/pull/1895
- Add xrefs in variability section by @t-sommer in https://github.com/modelica/fmi-standard/pull/1894
- Unify snippet comment with rest of standard by @hsilm in https://github.com/modelica/fmi-standard/pull/1910
- Document initial number of continuous states by @t-sommer in https://github.com/modelica/fmi-standard/pull/1911
- Correct types for decimal clock interval/shift by @pmai in https://github.com/modelica/fmi-standard/pull/1904
- Fixing reference to incorrect table by @PeterMeisrimelModelon in https://github.com/modelica/fmi-standard/pull/1918
- Fix typo in "Platform Tuple Definition" section id by @t-sommer in https://github.com/modelica/fmi-standard/pull/1926
- Bump copyright year to 2024 by @t-sommer in https://github.com/modelica/fmi-standard/pull/1927
- Remove duplicate API reference by @msabathier in https://github.com/modelica/fmi-standard/pull/1928
- Remove requirement to call fmi3Terminate when terminateSimulation = fmi3True by @t-sommer in https://github.com/modelica/fmi-standard/pull/1941
- Remove requirement to call fmi3FreeInstance or fmi3Reset by @t-sommer in https://github.com/modelica/fmi-standard/pull/1940
- Clarify the information flow of clocks by @klausschuch in https://github.com/modelica/fmi-standard/pull/1944
- Clarify multiple Clock ticks per Event Mode for different Clock types by @PTaeuberDS in https://github.com/modelica/fmi-standard/pull/1937
- Fix the fmi3GetOutputDerivatives description by @klausschuch in https://github.com/modelica/fmi-standard/pull/1951
- Remove excess column in table "Definition of initial" by @t-sommer in https://github.com/modelica/fmi-standard/pull/1954
- Allow setting continuous states in Continuous Time Mode by @t-sommer in https://github.com/modelica/fmi-standard/pull/1956
- Add missing blank lines by @t-sommer in https://github.com/modelica/fmi-standard/pull/1968
- Add definition of reinitialization to glossary by @t-sommer in https://github.com/modelica/fmi-standard/pull/1964
- Bump actions/checkout from v3 to v4.1.7 by @t-sommer in https://github.com/modelica/fmi-standard/pull/1972
- Bump actions/upload-artifact from v3 to v4.4.0 by @t-sommer in https://github.com/modelica/fmi-standard/pull/1973
- Allow setting continuous states in Event Mode if reinit = false by @t-sommer in https://github.com/modelica/fmi-standard/pull/1955
- Clarify meaning of DefaultExperiment.stepSize for Model Exchange by @t-sommer in https://github.com/modelica/fmi-standard/pull/1980
- Bump Reference FMUs submodule to v0.0.34 by @t-sommer in https://github.com/modelica/fmi-standard/pull/1981
- Clarify when to use Scheduled Execution by @t-sommer in https://github.com/modelica/fmi-standard/pull/1979
- Introduce matching rule 'none' by @snps-ribbe in https://github.com/modelica/fmi-standard/pull/1976
- Unify description of reverse domain name notation, strong recommendation to use it for variable and terminal kinds by @chrbertsch in https://github.com/modelica/fmi-standard/pull/1977
- Fixed some spelling mistakes and inconsistent mathematical notations by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/1983
- Fixed typo in 2.4 by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/1992
- Fixed up asciidoc warnings by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/2000
- Fixed typos by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/2002
- Cleaned up mathematical notation for physical units by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/1995
- Added explanation to fmi3{Get|Set}{Interval|Shift}Fraction arguments by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/1993
- Updated documentation on patch releases by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/2007
- Added non-normative explanation for usage of stepSize in ME by @Tc-Fast in https://github.com/modelica/fmi-standard/pull/2005

**Full Changelog**: https://github.com/modelica/fmi-standard/compare/v3.0.1...v3.0.2
