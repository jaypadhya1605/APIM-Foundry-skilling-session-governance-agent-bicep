// =============================================================================
// Providence | APIM for Microsoft Foundry — Phase 3: governance
// -----------------------------------------------------------------------------
// SESSION 2 material. Layers the governance stack on top of the Session 1
// gateway without touching it:
//
//   * llm-token-limit          quota + noisy-neighbour protection   (ask 4)
//   * llm-content-safety       uniform safety across every model    (ask 4)
//   * llm-emit-token-metric    chargeback dimensions                (ask 4)
//   * clinical-tools API       agent -> internal API egress control (ask 5)
//   * alerts + workbook        the part everyone forgets            (ask 4)
//
// Deliberately a SEPARATE deployment from 02-ai-gateway.bicep. Governance is
// tuned far more often than routing is, and a change to a token quota must not
// require re-validating every API definition. Splitting the two also lets each
// session show a live `az deployment group create` that changes exactly one
// layer.
//
//   pwsh %TEMP%\deploy-prov-governance.ps1
// =============================================================================

targetScope = 'resourceGroup'

@description('Name of the APIM instance created by 01-platform.bicep.')
param apimName string

@description('Name of the existing Microsoft Foundry (AIServices) account. Also hosts the Content Safety data plane.')
param foundryAccountName string

@description('Entra tenant id used to validate agent tokens on the egress API.')
param tenantId string = subscription().tenantId

@description('Audience the clinical-tools API validates agent tokens against. In production this is the tools app registration URI; the demo uses the ARM audience so a CLI token can drive it.')
param toolsAudience string = environment().resourceManager

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource appiLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' existing = {
  parent: apim
  name: 'appinsights'
}

resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: 'appi-${split(apimName, '-')[1]}-${split(apimName, '-')[2]}'
}

var contentSafetyHost = 'https://${foundryAccountName}.cognitiveservices.azure.com'

// -----------------------------------------------------------------------------
// Named values
// -----------------------------------------------------------------------------
resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'prov-tenant-id'
  properties: {
    displayName: 'prov-tenant-id'
    value: tenantId
    secret: false
    tags: ['governance', 'session-2']
  }
}

resource nvToolsAudience 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'prov-tools-audience'
  properties: {
    displayName: 'prov-tools-audience'
    value: toolsAudience
    secret: false
    tags: ['governance', 'session-2']
  }
}

// -----------------------------------------------------------------------------
// Content Safety, reached WITHOUT a key
//
// Providence's Foundry account has disableLocalAuth = true, so there is no key
// to give an APIM backend. Rather than relax that, mediate: an internal APIM
// API attaches the gateway's managed identity, and the backend points at it.
// The full reasoning is in ../policies/api-content-safety-internal.xml.
//
// A circuit breaker is not optional here. Content Safety sits in the
// synchronous path of every governed request, so if it degrades without a
// breaker the safety control becomes the outage.
//
// Which raises the question worth asking out loud in the session: when Content
// Safety is unavailable, does the platform fail open or fail closed?
// llm-content-safety fails CLOSED — the request errors. For a health system
// that is almost certainly right, but it must be a decision on record with the
// risk owner, not a default nobody chose.
// -----------------------------------------------------------------------------
resource productInternal 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'internal-platform'
  properties: {
    displayName: 'Internal — platform only'
    description: 'Not for app teams. Carries the internal APIs the gateway calls on its own behalf.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
    // Deliberately NOT published to the developer portal, and deliberately
    // carrying no governance policy: a content-safety check must never trigger
    // a content-safety check.
  }
}

resource subInternal 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'sub-internal-content-safety'
  properties: {
    displayName: 'platform-internal-content-safety'
    scope: productInternal.id
    state: 'active'
    allowTracing: false
  }
}

resource apiContentSafety 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'content-safety-internal'
  properties: {
    displayName: 'Content Safety (internal, MI-mediated)'
    description: 'Keyless passthrough to Azure AI Content Safety using the gateway managed identity. Called by llm-content-safety, not by app teams.'
    path: 'internal/content-safety'
    protocols: ['https']
    subscriptionRequired: true
    serviceUrl: contentSafetyHost
  }
}

resource opContentSafetyAny 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiContentSafety
  name: 'any-post'
  properties: {
    displayName: 'POST — any Content Safety path'
    method: 'POST'
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}

resource polContentSafety 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiContentSafety
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/api-content-safety-internal.xml')
  }
  dependsOn: [opContentSafetyAny]
}

resource linkContentSafety 'Microsoft.ApiManagement/service/products/apiLinks@2024-05-01' = {
  parent: productInternal
  name: 'link-content-safety'
  properties: {
    apiId: apiContentSafety.id
  }
}

resource backendContentSafety 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'content-safety'
  properties: {
    title: 'Azure AI Content Safety (via MI mediation)'
    description: 'Prompt Shields and category classification for every model on the platform. Keyless.'
    protocol: 'http'
    url: '${apim.properties.gatewayUrl}/internal/content-safety'
    credentials: {
      header: {
        // listSecrets() at deploy time: the key is generated by APIM, read by
        // ARM, and written straight back into the backend definition. It never
        // exists in a file, a parameter or a pipeline variable.
        'Ocp-Apim-Subscription-Key': [subInternal.listSecrets().primaryKey]
      }
    }
    circuitBreaker: {
      rules: [
        {
          name: 'safety-degraded'
          failureCondition: {
            count: 10
            interval: 'PT1M'
            statusCodeRanges: [{ min: 500, max: 599 }]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
  dependsOn: [polContentSafety, linkContentSafety]
}

// -----------------------------------------------------------------------------
// Governed product policies
//
// Same two products created in Session 1 — this only replaces their policy
// documents. Show `az deployment group create` running against a live gateway
// and the quota appearing on the next request. Governance that requires a
// maintenance window is governance that gets deferred.
// -----------------------------------------------------------------------------
resource productCardiology 'Microsoft.ApiManagement/service/products@2024-05-01' existing = {
  parent: apim
  name: 'team-cardiology'
}

resource productRevCycle 'Microsoft.ApiManagement/service/products@2024-05-01' existing = {
  parent: apim
  name: 'team-revenue-cycle'
}

resource polProductCardiology 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = {
  parent: productCardiology
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/product-team-cardiology-governed.xml')
  }
  dependsOn: [backendContentSafety]
}

resource polProductRevCycle 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = {
  parent: productRevCycle
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/product-team-revenue-cycle-governed.xml')
  }
  dependsOn: [backendContentSafety]
}

// -----------------------------------------------------------------------------
// Egress: the clinical tools API an agent calls  (ask 5)
//
// subscriptionRequired = false on purpose. The caller here is an AGENT holding
// an Entra token, not an app holding a subscription key. Requiring both would
// mean putting a key in the agent's tool definition, which is the thing we are
// trying to avoid.
// -----------------------------------------------------------------------------
resource apiTools 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'clinical-tools'
  properties: {
    displayName: 'Clinical tools (agent egress)'
    description: 'Internal tools exposed to Foundry Agents under gateway governance. Entra-authenticated, rate limited per agent, arguments validated.'
    path: 'tools/clinical'
    protocols: ['https']
    subscriptionRequired: false
    serviceUrl: 'https://mock.invalid'
  }
}

resource opEligibility 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: apiTools
  name: 'eligibility-lookup'
  properties: {
    displayName: 'Member eligibility lookup'
    method: 'GET'
    urlTemplate: '/eligibility'
    description: 'Returns coverage for a member id. Agent-callable tool.'
    request: {
      queryParameters: [
        {
          name: 'memberId'
          type: 'string'
          required: true
          description: 'Providence member id, format PRV-########'
        }
      ]
    }
    responses: [{ statusCode: 200, description: 'OK' }]
  }
}

resource polTools 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: apiTools
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/api-clinical-tools.xml')
  }
  dependsOn: [nvTenantId, nvToolsAudience, opEligibility]
}

resource polOpEligibility 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opEligibility
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/op-eligibility-lookup.xml')
  }
  dependsOn: [polTools]
}

resource diagTools 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: apiTools
  name: 'applicationinsights'
  properties: {
    loggerId: appiLogger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 }
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    frontend: {
      response: { headers: ['x-prov-agent-app-id', 'x-prov-correlation-id'] }
    }
  }
  dependsOn: [polTools]
}

// -----------------------------------------------------------------------------
// Alerts
//
// A quota nobody is paged about is a report, not a control. Two rules, and they
// deliberately watch different things:
//
//   429 rate   -> a team is hitting its ceiling. Capacity or budget conversation.
//   5xx rate   -> the gateway or a backend is failing. Incident.
//
// Both are on the APIM resource rather than on Foundry, because the gateway is
// the only place that sees every team's traffic on one timeline.
// -----------------------------------------------------------------------------
resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-prov-ai-platform'
  location: 'global'
  properties: {
    groupShortName: 'provai'
    enabled: true
    emailReceivers: [
      {
        name: 'platform-team'
        emailAddress: 'jaypadhya@microsoft.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

resource alertThrottling 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-prov-ai-throttling'
  location: 'global'
  properties: {
    description: 'A team is being throttled at the gateway. Either the quota is wrong or the workload changed.'
    severity: 3
    enabled: true
    scopes: [apim.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'throttled-requests'
          metricNamespace: 'Microsoft.ApiManagement/service'
          metricName: 'Requests'
          operator: 'GreaterThan'
          threshold: 20
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'BackendResponseCode'
              operator: 'Include'
              values: ['429']
            }
          ]
        }
      ]
    }
    actions: [{ actionGroupId: alertActionGroup.id }]
  }
}

resource alertGatewayErrors 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-prov-ai-gateway-5xx'
  location: 'global'
  properties: {
    description: 'The AI gateway is returning server errors. Check policy expressions and backend circuit breakers first.'
    severity: 1
    enabled: true
    scopes: [apim.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'server-errors'
          metricNamespace: 'Microsoft.ApiManagement/service'
          metricName: 'Requests'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'GatewayResponseCodeCategory'
              operator: 'Include'
              values: ['5xx']
            }
          ]
        }
      ]
    }
    actions: [{ actionGroupId: alertActionGroup.id }]
  }
}

output contentSafetyBackend string = contentSafetyHost
output toolsPath string = '${apim.properties.gatewayUrl}/tools/clinical/eligibility'
output appInsightsId string = appi.id
