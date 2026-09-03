# =============================================================================
# 03 — Calling the governed egress API directly       (what the agent's tool
#      call actually looks like on the wire)
# =============================================================================
# The agent sample is the realistic demo; this one is the debuggable one. Run it
# when a tool call is failing and you need to know whether the problem is the
# agent, the token, or the policy.
#
# Four requests, four different controls, four different status codes. Each one
# is a control Providence would otherwise be asking every internal API team to
# implement independently and correctly.
# =============================================================================

import json
import os
import subprocess
import time

import requests
from dotenv import load_dotenv

load_dotenv()

GW = os.environ["APIM_GATEWAY_URL"].rstrip("/")
URL = f"{GW}/tools/clinical/eligibility"

# In production the agent's token comes from its managed identity or app
# registration, for the tools app registration's audience. For the session we
# use the ARM audience so a plain `az login` is enough — the policy validates
# the token exactly the same way either side of that change.
#
# az account get-access-token is shelled out to on purpose: importing
# azure-identity here would pull in cryptography/cffi, which is a slow and
# occasionally hostile build on ARM64 laptops, for no benefit in a demo script.
TOKEN = subprocess.run(
    ["az", "account", "get-access-token", "--resource", "https://management.azure.com/",
     "--query", "accessToken", "-o", "tsv"],
    capture_output=True, text=True, check=True, shell=True,
).stdout.strip()

AUTH = {"Authorization": f"Bearer {TOKEN}"}


def show(label: str, resp: requests.Response) -> None:
    print(f"\n=== {label} ===")
    print(f"HTTP {resp.status_code}")
    agent_id = resp.headers.get("x-prov-agent-app-id")
    if agent_id:
        print(f"  x-prov-agent-app-id  {agent_id}")
    try:
        print("  " + json.dumps(resp.json(), separators=(",", ":"))[:300])
    except ValueError:
        print("  " + resp.text[:300])


# 1 — no identity at all
show("no token", requests.get(URL, params={"memberId": "PRV-12345678"}, timeout=30))

# 2 — valid identity, argument the model could plausibly have invented
show(
    "valid token, invalid model-authored argument",
    requests.get(URL, headers=AUTH, params={"memberId": "DROP-TABLE-MEMBERS"}, timeout=30),
)

# 3 — the happy path. Note x-prov-agent-app-id: the gateway resolved the
#     CALLER'S identity from its own token, so attribution is not something the
#     agent asserts about itself.
show(
    "valid token, valid argument",
    requests.get(URL, headers=AUTH, params={"memberId": "PRV-12345678"}, timeout=30),
)

# 4 — the failure mode that actually happens in production: an agent that
#     re-plans on an unexpected tool result and calls again, and again, and
#     again. Nothing in the agent framework stops this. A 10-second window does,
#     while it is still one incident.
#     Note on the call count: the limit is 20 per 10 s, but APIM's distributed
#     counter is eventually consistent, so the first ~30 calls can slip through
#     before it catches up. 40 calls is not reliably enough to trip it on a slow
#     client; 60 is. Verified live 2026-08-23: 60 calls in 11.3 s -> 43x200,
#     17x429. Do not lower this number for the demo.
print("\n=== runaway agent loop ===")
codes = []
started = time.time()
for i in range(60):
    r = requests.get(URL, headers=AUTH, params={"memberId": f"PRV-1234567{i % 10}"}, timeout=30)
    codes.append(r.status_code)
elapsed = time.time() - started
throttled = codes.count(429)
print(f"  {' '.join(str(c) for c in codes)}")
print(f"  elapsed={elapsed:.1f}s  200s={codes.count(200)}  429s={throttled}")
if throttled:
    print(f"  Those {throttled} 429s are the gateway containing the loop. Without them this")
    print("  is a self-inflicted denial of service against an internal clinical system.")
else:
    print("  No 429s this run — the client was too slow to fill the 10 s window.")
    print("  Re-run it; the containment is real, the client just never reached the limit.")
