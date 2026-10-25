<#
.SYNOPSIS
    使用 FMI 3.0 官方 XSD 校验 modelDescription.xml。

.DESCRIPTION
    加载 docs/spec-3.0.2/schema/fmi3ModelDescription.xsd（及其 include 的
    fmi3Variable.xsd、fmi3Type.xsd 等），对指定的 XML 文件做 Schema 校验。

    退出码：
      0  校验通过
      1  存在 Schema 错误
      2  XML 无法解析或文件不存在

.PARAMETER Path
    要校验的 XML 文件，通常是 FMU 解包后的 modelDescription.xml，
    也可以是 examples/reference-fmus/<Model>/FMI3.xml。

.PARAMETER Schema
    可选的 XSD 路径。默认使用仓库内的 FMI 3.0.2 schema。

.EXAMPLE
    .\examples\scripts\validate-model-description.ps1 `
        .\examples\reference-fmus\BouncingBall\FMI3.xml

.EXAMPLE
    .\examples\scripts\validate-model-description.ps1 `
        "$env:TEMP\BouncingBall\modelDescription.xml"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$Schema = (Join-Path $PSScriptRoot '..\..\docs\spec-3.0.2\schema\fmi3ModelDescription.xsd')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "ERROR: XML file not found: $Path" -ForegroundColor Red
    exit 2
}

if (-not (Test-Path -LiteralPath $Schema)) {
    Write-Host "ERROR: schema file not found: $Schema" -ForegroundColor Red
    exit 2
}

$xmlPath = (Resolve-Path -LiteralPath $Path).Path
$schemaPath = (Resolve-Path -LiteralPath $Schema).Path

$schemas = New-Object System.Xml.Schema.XmlSchemaSet
[void]$schemas.Add($null, $schemaPath)

$settings = New-Object System.Xml.XmlReaderSettings
$settings.ValidationType = [System.Xml.ValidationType]::Schema
$settings.Schemas = $schemas
$settings.ValidationFlags = [System.Xml.Schema.XmlSchemaValidationFlags]::ReportValidationWarnings

$script:errorCount = 0

$handler = [System.Xml.Schema.ValidationEventHandler] {
    param($sender, $e)

    $exception = $e.Exception
    $location = if ($exception) {
        "{0}:{1}:{2}" -f $xmlPath, $exception.LineNumber, $exception.LinePosition
    } else {
        $xmlPath
    }

    Write-Host ("{0}: {1}: {2}" -f $location, $e.Severity, $e.Message)

    if ($e.Severity -eq [System.Xml.Schema.XmlSeverityType]::Error) {
        $script:errorCount++
    }
}
[void]$settings.add_ValidationEventHandler($handler)

try {
    $reader = [System.Xml.XmlReader]::Create($xmlPath, $settings)
    while ($reader.Read()) { }
    $reader.Close()
}
catch {
    Write-Host "ERROR: cannot parse XML: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

if ($script:errorCount -gt 0) {
    Write-Host ("INVALID: {0} schema error(s) in {1}" -f $script:errorCount, $xmlPath) -ForegroundColor Red
    exit 1
}

Write-Host ("OK: {0} is valid against {1}" -f $xmlPath, (Split-Path -Leaf $schemaPath)) -ForegroundColor Green
exit 0
