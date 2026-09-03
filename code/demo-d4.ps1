# D4 (workout W8) - Agent egress. Four calls, four status codes.
# Everything before this governed an application calling a model. This governs a
# model calling an application: the caller is non-deterministic and the arguments
# are authored by a model that may have read a hostile document.

$ErrorActionPreference = 'Stop'
$apim = 'apim-provdemo-vzl7w5xjytej4'
$gw   = "https://$apim.azure-api.net"
$url  = "$gw/tools/clinical/eligibility"

function Invoke-Tool([string]$uri, [hashtable]$headers) {
  try {
    $r = Invoke-WebRequest -Method Get -Uri $uri -Headers $headers
    $c = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    [pscustomobject]@{ Status = [int]$r.StatusCode; Agent = ($r.Headers['x-prov-agent-app-id'] -join ''); Body = $c }
  } catch {
    [pscustomobject]@{ Status = [int]$_.Exception.Response.StatusCode.value__; Agent = ''; Body = [string]$_.ErrorDetails.Message }
  }
}

function Show-Call([string]$label, [string]$qs, [string]$auth) {
  Write-Host ('        GET  /tools/clinical/eligibility?{0}' -f $qs) -ForegroundColor DarkGray
  Write-Host ('        Authorization: {0}' -f $auth) -ForegroundColor DarkGray
}

function Show-Result($res, [int]$expected, [string]$why) {
  $col = if ($res.Status -eq $expected) { 'Green' } else { 'Red' }
  Write-Host ('        HTTP {0}   {1}' -f $res.Status, $why) -ForegroundColor $col
  if ($res.Agent) { Write-Host ('        x-prov-agent-app-id  {0}' -f $res.Agent) -ForegroundColor Gray }
  if ($res.Body) { Write-Host ('        {0}' -f ($res.Body -replace '\s+', ' ').Trim()) -ForegroundColor Gray }
}

Write-Host ''
Write-Host '  D4  A model calling your application. Four calls, four status codes.' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

$agentToken = az account get-access-token --resource https://management.azure.com/ -o tsv --query accessToken

Write-Host ''
Write-Host '  [1/4] No bearer token  ->  validate-jwt' -ForegroundColor White
Show-Call 'E1' 'memberId=PRV-12345678' '(none)'
$e1 = Invoke-Tool "$url`?memberId=PRV-12345678" @{}
Show-Result $e1 401 'unauthenticated caller pretending to be the agent'

Write-Host ''
Write-Host '  [2/4] Valid token, model-authored argument fails ^PRV-[0-9]{8}$  ->  argument validation' -ForegroundColor White
Show-Call 'E2' 'memberId=DROP-TABLE-MEMBERS' 'Bearer <agent token>'
$e2 = Invoke-Tool "$url`?memberId=DROP-TABLE-MEMBERS" @{ Authorization = "Bearer $agentToken" }
Show-Result $e2 400 'the argument the model authored never reaches the internal system'

Write-Host ''
Write-Host '  [3/4] Valid token, valid argument  ->  credential mediation' -ForegroundColor White
Show-Call 'E3' 'memberId=PRV-12345678' 'Bearer <agent token>'
$e3 = Invoke-Tool "$url`?memberId=PRV-12345678" @{ Authorization = "Bearer $agentToken" }
Show-Result $e3 200 'the agent never holds the downstream credential'

Write-Host ''
Write-Host '  [4/4] Runaway re-planning loop, 60 calls  ->  rate-limit-by-key on the agent object id' -ForegroundColor White
Write-Host '        fired in parallel - sequential calls are slower than the 20-per-10s window' -ForegroundColor DarkGray
Write-Host '        and never trip it' -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
$codes = 0..59 | ForEach-Object -ThrottleLimit 12 -Parallel {
  try {
    (Invoke-WebRequest -Method Get -Uri "$using:url`?memberId=PRV-1234567$($_ % 10)" `
      -Headers @{ Authorization = "Bearer $using:agentToken" }).StatusCode
  } catch { $_.Exception.Response.StatusCode.value__ }
}
$sw.Stop()

Write-Host ''
for ($i = 0; $i -lt $codes.Count; $i += 10) {
  Write-Host '        ' -NoNewline
  foreach ($c in $codes[$i..([Math]::Min($i + 9, $codes.Count - 1))]) {
    $col = if ($c -eq 429) { 'Yellow' } elseif ($c -eq 200) { 'DarkGray' } else { 'Red' }
    Write-Host ('{0}  ' -f $c) -NoNewline -ForegroundColor $col
  }
  Write-Host ''
}
$ok  = ($codes | Where-Object { $_ -eq 200 }).Count
$thr = ($codes | Where-Object { $_ -eq 429 }).Count
Write-Host ''
Write-Host ('        {0} calls in {1}s   {2} x 200   ' -f $codes.Count, [math]::Round($sw.Elapsed.TotalSeconds, 1), $ok) -NoNewline -ForegroundColor Gray
Write-Host ('{0} x 429' -f $thr) -ForegroundColor Yellow

Write-Host ''
Write-Host ('  {0,-4}  {1,-24}  {2,-8}  {3}' -f '#', 'BLOCK', 'CODE', 'WHAT IT STOPS') -ForegroundColor White
Write-Host ('  {0}' -f ('-' * 90)) -ForegroundColor DarkGray
$rows = @(
  [pscustomobject]@{ N = '1'; B = 'validate-jwt'; C = $e1.Status; W = 'an unauthenticated caller pretending to be the agent' }
  [pscustomobject]@{ N = '2'; B = 'rate-limit-by-key'; C = 429; W = "a re-planning loop calling the tool 60 times ($thr throttled)" }
  [pscustomobject]@{ N = '3'; B = 'argument validation'; C = $e2.Status; W = 'a model-authored memberId that fails the regex' }
  [pscustomobject]@{ N = '4'; B = 'credential mediation'; C = $e3.Status; W = 'the agent holding a downstream credential' }
)
foreach ($row in $rows) {
  Write-Host ('  {0,-4}  {1,-24}  ' -f $row.N, $row.B) -NoNewline -ForegroundColor Gray
  Write-Host ('{0,-8}  ' -f $row.C) -NoNewline -ForegroundColor Yellow
  Write-Host $row.W -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  The failure mode is not malice. An agent gets an unexpected result, re-plans,' -ForegroundColor DarkGray
Write-Host '  and calls the same tool forty times in eight seconds. The counter is keyed on' -ForegroundColor DarkGray
Write-Host '  the agent object id, not the user.' -ForegroundColor DarkGray
Write-Host ''
