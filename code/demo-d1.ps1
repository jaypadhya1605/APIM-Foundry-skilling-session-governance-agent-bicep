# D1 - Two teams, one gateway, two different sets of limits.
# Sends the same logical request under two product subscriptions and diffs the
# governance headers the gateway stamps on the way out.

$ErrorActionPreference = 'Stop'
$rg   = 'rg-personal-demo-usages'
$apim = 'apim-provdemo-vzl7w5xjytej4'
$sub  = '2852c4f9-8fcc-47c1-8e96-c4142a9ae463'
$gw   = "https://$apim.azure-api.net"

function Get-Key([string]$name) {
  (az rest --method post --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/subscriptions/$name/listSecrets?api-version=2024-05-01" -o json | ConvertFrom-Json).primaryKey
}

function Invoke-Governed([string]$uri, [string]$key, [string]$body) {
  $r = Invoke-WebRequest -Method Post -Uri $uri -Headers @{ 'api-key' = $key; 'Content-Type' = 'application/json' } -Body $body
  # Headers[...] is a string[] in pwsh 7; join or it prints as {value}
  $h = { param($n) ($r.Headers[$n] -join '') }
  [pscustomobject]@{
    Status    = [string]$r.StatusCode
    Team      = & $h 'x-prov-team'
    Tier      = & $h 'x-prov-service-tier'
    Cost      = & $h 'x-prov-cost-center'
    Model     = & $h 'x-prov-model'
    Tokens    = & $h 'x-prov-tokens-consumed'
    TpmLeft   = & $h 'x-prov-tpm-remaining'
    QuotaLeft = & $h 'x-prov-quota-tokens-remaining'
  }
}

Write-Host ''
Write-Host '  D1  Same model. Same request. Two products.' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

$cardKey = Get-Key 'sub-cardiology-scribe'
$revKey  = Get-Key 'sub-revcycle-triage'

Write-Host ''
Write-Host '  [1/2] Cardiology  ->  POST /aoai/deployments/gpt-5.6-sol/chat/completions' -ForegroundColor White
$a = Invoke-Governed "$gw/aoai/deployments/gpt-5.6-sol/chat/completions?api-version=2025-01-01-preview" $cardKey `
     '{"messages":[{"role":"user","content":"Reply with the single word: governed"}],"max_completion_tokens":2000}'

Write-Host '  [2/2] Revenue Cycle  ->  POST /foundry/openai/v1/chat/completions' -ForegroundColor White
$b = Invoke-Governed "$gw/foundry/openai/v1/chat/completions" $revKey `
     '{"model":"gpt-5.6-sol","messages":[{"role":"user","content":"Reply with the single word: bulk"}],"max_completion_tokens":2000}'

$rows = @(
  [pscustomobject]@{ H='HTTP status';                   A=$a.Status;    B=$b.Status }
  [pscustomobject]@{ H='x-prov-team';                   A=$a.Team;      B=$b.Team }
  [pscustomobject]@{ H='x-prov-service-tier';           A=$a.Tier;      B=$b.Tier }
  [pscustomobject]@{ H='x-prov-cost-center';            A=$a.Cost;      B=$b.Cost }
  [pscustomobject]@{ H='x-prov-model';                  A=$a.Model;     B=$b.Model }
  [pscustomobject]@{ H='x-prov-tokens-consumed';        A=$a.Tokens;    B=$b.Tokens }
  [pscustomobject]@{ H='x-prov-tpm-remaining';          A=$a.TpmLeft;   B=$b.TpmLeft }
  [pscustomobject]@{ H='x-prov-quota-tokens-remaining'; A=$a.QuotaLeft; B=$b.QuotaLeft }
)

Write-Host ''
Write-Host ('  {0,-31}  {1,-22}  {2}' -f 'RESPONSE HEADER', 'CARDIOLOGY', 'REVENUE CYCLE') -ForegroundColor White
Write-Host ('  {0}' -f ('-' * 76)) -ForegroundColor DarkGray
foreach ($row in $rows) {
  Write-Host ('  {0,-31}  ' -f $row.H) -NoNewline -ForegroundColor Gray
  $c = if ($row.A -eq $row.B) { 'DarkGray' } else { 'Yellow' }
  Write-Host ('{0,-22}  {1}' -f $row.A, $row.B) -ForegroundColor $c
}

Write-Host ''
Write-Host '  Yellow = set by product policy. Neither application sent any of it.' -ForegroundColor DarkGray
Write-Host ''
