# D3 (workout W6) - Token attribution, and the table everyone queries wrongly.
# Runs the chargeback query against the Log Analytics workspace, then runs the
# classic-schema version copied from every AI-gateway blog post so the room sees
# exactly how it fails. Portal is the primary surface for this workout; this is
# the same two queries on one command if the portal is slow or a tab is lost.

$ErrorActionPreference = 'Stop'
$rg  = 'rg-personal-demo-usages'
$law = 'log-provdemo-vzl7w5xjytej4'

# Single-quoted KQL: double quotes do not survive PowerShell -> az argument passing.
$k1 = @'
AppMetrics
| where TimeGenerated > ago(1h)
| where Name == 'Total Tokens'
| extend Team        = tostring(Properties['Team']),
         CostCenter  = tostring(Properties['CostCenter']),
         Model       = tostring(Properties['Model']),
         ApiId       = tostring(Properties['ApiId']),
         ServiceTier = tostring(Properties['ServiceTier']),
         App         = tostring(Properties['App'])
| summarize Tokens = sum(Sum) by Team, Model, ApiId
| order by Tokens desc
'@

$k2 = @'
customMetrics
| where timestamp > ago(1h)
| where name == 'Total Tokens'
| summarize Tokens = sum(valueSum)
'@

function Show-Kql([string]$q) {
  foreach ($line in ($q -split "`n")) { Write-Host ('        {0}' -f $line.TrimEnd()) -ForegroundColor Gray }
}

# az is a batch file: a multiline argument is truncated at the first newline.
function ConvertTo-OneLine([string]$q) { (($q -split "`n") | ForEach-Object { $_.Trim() }) -join ' ' }

Write-Host ''
Write-Host '  D3  The gateway already stamped the dimensions. Chargeback is a group-by.' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

$wsid = az monitor log-analytics workspace show -g $rg -n $law --query customerId -o tsv
Write-Host ''
Write-Host ('  workspace  {0}   ({1})' -f $law, $wsid) -ForegroundColor DarkGray

Write-Host ''
Write-Host '  [1/2] K1  workspace schema  ->  AppMetrics / Properties / Sum' -ForegroundColor White
Show-Kql $k1

$rows = az monitor log-analytics query -w $wsid --analytics-query (ConvertTo-OneLine $k1) -o json | ConvertFrom-Json

Write-Host ''
if (-not $rows -or $rows.Count -eq 0) {
  Write-Host '        no rows in the last hour - run demo-d1.ps1 first, then allow a couple of' -ForegroundColor Yellow
  Write-Host '        minutes for metric ingestion before re-running this.' -ForegroundColor Yellow
} else {
  Write-Host ('        {0,-22}  {1,-16}  {2,-16}  {3}' -f 'TEAM', 'MODEL', 'API', 'TOKENS') -ForegroundColor White
  Write-Host ('        {0}' -f ('-' * 68)) -ForegroundColor DarkGray
  foreach ($r in $rows) {
    Write-Host ('        {0,-22}  {1,-16}  {2,-16}  ' -f $r.Team, $r.Model, $r.ApiId) -NoNewline -ForegroundColor Gray
    Write-Host $r.Tokens -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host '  [2/2] K2  classic schema  ->  what most teams paste from a blog post' -ForegroundColor White
Show-Kql $k2

$ErrorActionPreference = 'Continue'
$out = az monitor log-analytics query -w $wsid --analytics-query (ConvertTo-OneLine $k2) -o json 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'

Write-Host ''
if ($code -eq 0) {
  Write-Host '        (returned without error)' -ForegroundColor Yellow
  Write-Host ('        {0}' -f ($out -join ' ')) -ForegroundColor Gray
} else {
  Write-Host '        FAILS - the table does not exist in a workspace-based resource' -ForegroundColor Red
  $lines = @($out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match 'resolve|SemanticError|BadArgument' })
  if (-not $lines) { $lines = @($out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -First 3) }
  foreach ($line in $lines) { Write-Host ('        {0}' -f $line) -ForegroundColor Gray }
}

Write-Host ''
Write-Host ('  {0,-22}  {1,-22}  {2}' -f 'CLASSIC NAME', 'WORKSPACE NAME', 'HOLDS') -ForegroundColor White
Write-Host ('  {0}' -f ('-' * 76)) -ForegroundColor DarkGray
$map = @(
  [pscustomobject]@{ A = 'customMetrics'; B = 'AppMetrics'; C = 'where the token metric lands' }
  [pscustomobject]@{ A = 'customDimensions'; B = 'Properties'; C = 'the six dimensions' }
  [pscustomobject]@{ A = 'valueSum'; B = 'Sum'; C = 'the token count' }
  [pscustomobject]@{ A = 'timestamp'; B = 'TimeGenerated'; C = 'every time filter you will write' }
  [pscustomobject]@{ A = 'requests'; B = 'AppRequests'; C = 'gateway request telemetry' }
)
foreach ($m in $map) {
  Write-Host ('  {0,-22}  ' -f $m.A) -NoNewline -ForegroundColor Gray
  Write-Host ('{0,-22}  ' -f $m.B) -NoNewline -ForegroundColor Yellow
  Write-Host $m.C -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Six dimensions on every call, stamped by the gateway. Untagged traffic is' -ForegroundColor DarkGray
Write-Host '  permanently unattributable - you cannot retro-fit a dimension.' -ForegroundColor DarkGray
Write-Host ''
