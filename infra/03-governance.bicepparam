using './03-governance.bicep'

param apimName = 'apim-provdemo-vzl7w5xjytej4'
param foundryAccountName = 'mf-personal-demo-usage'

// toolsAudience is intentionally left at its default (environment().resourceManager)
// so a plain `az account get-access-token` can drive the agent egress demo.
// In production, set it to the clinical-tools app registration URI.
