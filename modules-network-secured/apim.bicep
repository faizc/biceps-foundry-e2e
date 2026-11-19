/**
 * @module 
 * @description This module defines the API resources using Bicep.
 * It includes configurations for creating and managing APIs, products, and policies.
 * This is version 2 (v2) of the APIM Bicep module.
 */

// ------------------
//    PARAMETERS
// ------------------
@description('The SKU of the API Management instance. Defaults to "Standardv2".')
param apimSku string = 'Standardv2'

@description('Public network access for APIM')
@allowed([
  'Enabled'
  'Disabled'
])
param apimPublicNetworkAccess string = 'Enabled'

param apiManagementName string = 'apim-${suffix}'

@description('Id of the APIM Logger')
param apimLoggerId string = ''

@description('The instrumentation key for Application Insights')
@secure()
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights')
param appInsightsId string = ''

@description('The XML content for the API policy')
param policyXml string

@description('Configuration array for AI Services')
param aiServicesConfig array = []

@description('The name of the Inference API in API Management.')
param inferenceAPIName string = 'inference-api'

@description('The description of the Inference API in API Management.')
param inferenceAPIDescription string = 'Inferencing API'

@description('The display name of the Inference API in API Management. .')
param inferenceAPIDisplayName string = 'Inference API'

@description('The name of the Inference backend pool.')
param inferenceBackendPoolName string = 'inference-backend-pool'

@description('The inference API type')
@allowed([
  'AzureOpenAI'
  'AzureAI'
  'OpenAI'
])
param inferenceAPIType string = 'AzureAI'

@description('The path to the inference API in the APIM service')
param inferenceAPIPath string = 'inference' // Path to the inference API in the APIM service

@description('Whether to configure the circuit breaker for the inference backend')
param configureCircuitBreaker bool = false

param suffix string = ''

@description('The subnet resource ID for the API Management instance')
param apimSubnet string = ''

// ------------------
//    VARIABLES
// ------------------

var logSettings = {
  headers: [ 'Content-type', 'User-agent', 'x-ms-region', 'x-ratelimit-remaining-tokens' , 'x-ratelimit-remaining-requests' ]
  body: { bytes: 8192 }
}

var updatedPolicyXml = replace(policyXml, '{backend-id}', (length(aiServicesConfig) > 1) ? inferenceBackendPoolName : aiServicesConfig[0].name)

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apiManagementName
  location: resourceGroup().location
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: 'noreply@microsoft.com'
    publisherName: 'Microsoft'
    virtualNetworkType: 'External' // "Internal" # Setting up 'Internal' Internal Virtual Network Type is not supported for Sku Type 'StandardV2'.
    publicNetworkAccess: apimPublicNetworkAccess // "Disabled" # Blocking all public network access by setting property `publicNetworkAccess` of API Management service is not enabled during service creation.
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnet
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

var endpointPath = (inferenceAPIType == 'AzureOpenAI') ? 'openai' : (inferenceAPIType == 'AzureAI') ? 'models' : ''

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: inferenceAPIName
  parent: apimService
  properties: {
    apiType: 'http'
    description: inferenceAPIDescription
    displayName: inferenceAPIDisplayName
    format: 'openapi+json'
    path: '${inferenceAPIPath}/${endpointPath}'
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: true
    type: 'http'
    value: string((inferenceAPIType == 'AzureOpenAI') ? loadJsonContent('./specs/AIFoundryOpenAI.json') : (inferenceAPIType == 'AzureAI') ? loadJsonContent('./specs/AIFoundryAzureAI.json') : (inferenceAPIType == 'OpenAI') ? loadJsonContent('./specs/AIFoundryAzureAI.json') : loadJsonContent('./specs/PassThrough.json'))
  }
}
// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis/policies
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: api
  properties: {
    format: 'rawxml'
    value: updatedPolicyXml
  }
}

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/backends
resource inferenceBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' =  [for (config, i) in aiServicesConfig: if(length(aiServicesConfig) > 0) {
  name: config.name
  parent: apimService
  properties: {
    description: 'Inference backend'
    url: '${config.endpoint}${endpointPath}'
    protocol: 'http'
    circuitBreaker: (configureCircuitBreaker) ? {
      rules: [
      {
        failureCondition: {
        count: 1
        errorReasons: [
          'Server errors'
        ]
        interval: 'PT1M'
        statusCodeRanges: [
          {
          min: 429
          max: 429
          }
        ]
        }
        name: 'InferenceBreakerRule'
        tripDuration: 'PT1M'
        acceptRetryAfter: true
      }
      ]
    }: null
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
          resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}]

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/backends
resource backendPoolOpenAI 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if(length(aiServicesConfig) > 1) {
  name: inferenceBackendPoolName
  parent: apimService
  // BCP035: protocol and url are not needed in the Pool type. This is an incorrect error.
  #disable-next-line BCP035
  properties: {
    description: 'Load balancer for multiple inference endpoints'
    type: 'Pool'
    pool: {
      services: [for (config, i) in aiServicesConfig: {
        id: '/backends/${inferenceBackend[i].name}'
        priority: config.?priority
        weight: config.?weight
      }]
    }
  }
}

resource apimLoggerAppInsights 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  name: 'apimLogger'
  parent: apimService
  properties: {
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    description: 'APIM Logger for OpenAI API'
    isBuffered: false
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
  }
}

resource apimLoggerMonitor 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = if(length(apimLoggerId) > 0) {
  parent: apimService
  name: 'azuremonitor'
  properties: {
    description: 'APIM Logger for OpenAI API'
    loggerType: 'azureMonitor'
    isBuffered: false // Set to false to ensure logs are sent immediately
    resourceId: apimLoggerId
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: api
  name: 'azuremonitor'
  properties: {
    alwaysLog: 'allErrors'
    verbosity: 'verbose'
    logClientIp: true
    loggerId: apimLoggerMonitor.id
    sampling: {
      samplingType: 'fixed'
      percentage: json('100')
    }
    frontend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        messages: 'all'
        maxSizeInBytes: 262144
      }
      responses: {
        messages: 'all'
        maxSizeInBytes: 262144
      }
    }
  }
} 

resource apiDiagnosticsAppInsights 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey)) {
  name: 'applicationinsights'
  parent: api
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    loggerId: apimLoggerAppInsights.id
    metrics: true
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: logSettings
      response: logSettings
    }
    backend: {
      request: logSettings
      response: logSettings
    }
  }
}

var foundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var foundryUserRoleDefinitionID = resourceId(
  'Microsoft.Authorization/roleDefinitions',
  foundryUser
)

resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = [
  for (config, i) in aiServicesConfig: {
    name: config.cognitiveServiceName
  }
]

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (config, i) in aiServicesConfig: if (length(aiServicesConfig) > 0) {
    scope: aiServices[i]
    name: guid(subscription().id, resourceGroup().id, config.name, foundryUserRoleDefinitionID)
    properties: {
      roleDefinitionId: foundryUserRoleDefinitionID
      principalId: apimService.identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// ------------------
//    OUTPUTS
// ------------------

output apiId string = api.id
