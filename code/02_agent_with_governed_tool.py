# =============================================================================
# 02 — A Foundry Agent whose tool call is governed by APIM      (ask #5)
# =============================================================================
# "Connectivity and governance for Foundry agents that call internal APIs,
#  tools, and MCP servers."
#
# The agent below is deliberately ordinary. That is the argument: nothing about
# the agent knows it is being governed. The governance lives in two places the
# agent author does not control —
#
#   * the SERVER url in clinical-tools-openapi.json points at APIM, not at the
#     internal system, and
#   * Session 2/policies/api-clinical-tools.xml is applied at the gateway.
#
# Which means the controls cannot be removed by editing agent configuration,
# they apply identically to every agent anybody builds, and turning a
# misbehaving agent off is a subscription change rather than a redeploy.
#
# WHAT THE GATEWAY ENFORCES ON EVERY TOOL CALL
# --------------------------------------------
#   1. Entra token validation      — which agent identity is calling
#   2. Per-agent rate limit        — 20 calls / 10s, keyed on the app id, so an
#                                    agent stuck in a re-planning loop is
#                                    contained in seconds rather than hours
#   3. Argument validation         — memberId must match ^PRV-[0-9]{8}$; this is
#                                    the concrete mitigation for INDIRECT prompt
#                                    injection, where a document the agent read
#                                    influences what it asks for
#   4. Credential mediation        — the agent's token stops at the gateway; the
#                                    internal system sees only the platform's
#                                    managed identity
#   5. Response scrubbing          — internal trace ids and server banners are
#                                    stripped, because a tool response becomes
#                                    model context and model context becomes the
#                                    next prompt
#   6. One audit trail             — every tool call, every agent, one log,
#                                    correlated on W3C traceparent
#
# ON MCP SPECIFICALLY
# -------------------
# The same argument applies to an MCP server and the same egress pattern
# governs it: point the agent's MCP tool at an APIM-fronted URL rather than at
# the server directly. APIM's own first-class "expose this API as an MCP
# server" capability is portal-driven today — the ARM resource type
# `Microsoft.ApiManagement/service/mcpServers` was probed while building this
# session and is not available on the 2024-06-01 / 2025-05-01 / 2025-09-01
# preview API versions, so it cannot yet be committed to a Bicep or Terraform
# repository. Treat it as a roadmap item and govern MCP as egress in the
# meantime; the controls above are identical either way.
# =============================================================================

import json
import os
import time
from pathlib import Path

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import OpenApiAnonymousAuthDetails, OpenApiTool
from azure.core.pipeline import PipelineRequest
from azure.core.pipeline.policies import SansIOHTTPPolicy
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

GW = os.environ["APIM_GATEWAY_URL"].rstrip("/")
APIM_KEY = os.environ["APIM_SUBSCRIPTION_KEY"]
PROJECT = os.getenv("FOUNDRY_PROJECT", "proj-personal-demo-usage")
MODEL = os.getenv("MODEL_DEPLOYMENT", "gpt-5.6-sol")


class ApimSubscriptionKeyPolicy(SansIOHTTPPolicy):
    """See Session 1/code/03 — the Projects SDK owns Authorization, so the
    APIM subscription key rides on Ocp-Apim-Subscription-Key instead."""

    def __init__(self, key: str) -> None:
        self._key = key

    def on_request(self, request: PipelineRequest) -> None:
        request.http_request.headers["Ocp-Apim-Subscription-Key"] = self._key


# azure-ai-projects 2.x moved the agents operations out of AIProjectClient.agents;
# AgentsClient is the surface that still has create_agent / threads / runs.
client = AgentsClient(
    endpoint=f"{GW}/foundry/projects/{PROJECT}",
    credential=DefaultAzureCredential(),
    per_call_policies=[ApimSubscriptionKeyPolicy(APIM_KEY)],
)

spec = json.loads((Path(__file__).parent / "clinical-tools-openapi.json").read_text())

# Anonymous auth on the TOOL definition is not the same as an ungoverned tool.
# It means the agent presents no credential of its own to the OpenAPI endpoint;
# in production you swap this for OpenApiConnectionAuthDetails so the Agent
# Service attaches an Entra token for the tools app registration and APIM's
# validate-jwt has something to check. It is anonymous here only so the session
# can be run without provisioning an app registration first — and the 401 you
# get without a token is still a real 401 from a real policy.
tool = OpenApiTool(
    name="clinical_eligibility",
    spec=spec,
    description="Look up Providence member benefit eligibility through the governed API gateway.",
    auth=OpenApiAnonymousAuthDetails(),
)

agent = client.create_agent(
    model=MODEL,
    name="prov-eligibility-assistant",
    instructions=(
        "You are a Providence benefits assistant. When a user gives you a "
        "member id, call the clinical_eligibility tool to look it up and then "
        "summarise the result in plain language. Never invent a member id, and "
        "never call the tool more than once for the same id."
    ),
    tools=tool.definitions,
)
print(f"agent    : {agent.id}")

thread = client.threads.create()
client.messages.create(
    thread_id=thread.id,
    role="user",
    content="Is member PRV-12345678 eligible, and what is their copay?",
)

run = client.runs.create(thread_id=thread.id, agent_id=agent.id)
while run.status in ("queued", "in_progress", "requires_action"):
    time.sleep(1)
    run = client.runs.get(thread_id=thread.id, run_id=run.id)
print(f"run      : {run.status}")
if run.last_error:
    print(f"error    : {run.last_error}")

for msg in client.messages.list(thread_id=thread.id):
    for part in msg.content:
        if getattr(part, "text", None):
            print(f"{msg.role}: {part.text.value}")

client.delete_agent(agent.id)

# -----------------------------------------------------------------------------
# WHAT TO LOOK AT AFTER RUNNING THIS
# -----------------------------------------------------------------------------
# APIM > APIs > Clinical tools > Metrics
#   Two request streams now exist for one user question: the agent's calls to
#   the Projects API, and the agent's tool call back through the egress API.
#   Both are Providence's traffic, both are on one gateway, both are in one
#   log. That is the whole point of the pattern — before it, the second stream
#   is invisible.
#
# Log Analytics
#   ApiManagementGatewayLogs
#   | where ApiId == "clinical-tools"
#   | project TimeGenerated, OperationId, ResponseCode,
#             AgentAppId = tostring(parse_json(RequestHeaders)["x-prov-agent-app-id"])
#
#   That query answers "which agent called which internal system, when, and did
#   it succeed" — the question a security review will ask, and the one that has
#   no answer at all if agents call internal APIs directly.
# -----------------------------------------------------------------------------
