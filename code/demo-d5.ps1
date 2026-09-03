# D5 (workout W8, optional) - The same governed tool call from inside a real
# Foundry agent. Creates an agent whose OpenAPI tool server URL points at APIM,
# asks it one question, prints the run status and answer, then deletes the agent.
# Nothing in the agent knows it is governed - that is the argument.
# Run only if there is time in hand.

$ErrorActionPreference = 'Stop'
$py = 'C:\Users\jaypadhya\.venvs\prov-apim\Scripts\python.exe'

Write-Host ''
Write-Host '  D5  A real Foundry agent. Two request streams, one gateway, one log.' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

if (-not (Test-Path $py)) { throw "venv python not found at $py" }
if (-not (Test-Path (Join-Path $PSScriptRoot '.env'))) { throw "Session 2\code\.env is missing - copy it from Session 1\code" }

Write-Host ''
Write-Host '  [1/1] Foundry Agents SDK  ->  Projects API via APIM  ->  OpenAPI tool via APIM' -ForegroundColor White
Write-Host '        the tool server URL in the OpenAPI spec is the gateway, not the backend' -ForegroundColor DarkGray
Write-Host ''

Push-Location $PSScriptRoot
try { & $py '02_agent_with_governed_tool.py' } finally { Pop-Location }

Write-Host ''
Write-Host '  One user question produced two governed request streams: the agent''s calls to' -ForegroundColor DarkGray
Write-Host '  the Projects API, and the agent''s tool call back through the egress API.' -ForegroundColor DarkGray
Write-Host ''
