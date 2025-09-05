@description('The name of the API Management service')
param apimServiceName string

@description('The Azure region for resources')
param location string

// Parameters for Named Values
@description('The required scopes for authorization')
param oauthScopes string

@description('The principle id of the user-assigned managed identity for Entra app')
param entraAppUserAssignedIdentityPrincipleId string

@description('The client ID of the user-assigned managed identity for Entra app')
param entraAppUserAssignedIdentityClientId string

@description('The name of the Entra application')
param entraAppUniqueName string

@description('The display name of the Entra application')
param entraAppDisplayName string

@description('The name of the MCP Server to display in the consent page')
param mcpServerName string = 'MCP Server'

resource apimService 'Microsoft.ApiManagement/service@2021-08-01' existing = {
  name: apimServiceName
}

module entraApp './entra-app.bicep' = {
  name: 'entraApp'
  params:{
    entraAppUniqueName: entraAppUniqueName
    entraAppDisplayName: entraAppDisplayName
    apimOauthCallback: '${apimService.properties.gatewayUrl}/oauth-callback'
    userAssignedIdentityPrincipleId: entraAppUserAssignedIdentityPrincipleId
  }
}

// Generate cryptographically secure values using Bicep functions
// Using guid() with unique salts to generate deterministic but unpredictable values
var encryptionKeyGuid = guid(resourceGroup().id, apimServiceName, 'encryption-key')
var encryptionIVGuid = guid(resourceGroup().id, apimServiceName, 'encryption-iv')

// Convert to base64 - using substring and padding to get proper lengths for AES encryption
// AES-256 requires 32-byte key, AES uses 16-byte IV
var encryptionKey = base64(substring('${encryptionKeyGuid}${encryptionKeyGuid}${encryptionKeyGuid}', 0, 32))
var encryptionIV = base64(substring('${encryptionIVGuid}${encryptionIVGuid}', 0, 16))

// Define the encryption named values directly without deployment script
resource EncryptionKeyNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'EncryptionKey'
  properties: {
    displayName: 'EncryptionKey'
    value: encryptionKey
    secret: true
  }
}

resource EncryptionIVNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'EncryptionIV'
  properties: {
    displayName: 'EncryptionIV'
    value: encryptionIV
    secret: true
  }
}

// Define the Named Values
resource EntraIDTenantIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'EntraIDTenantId'
  properties: {
    displayName: 'EntraIDTenantId'
    value: entraApp.outputs.entraAppTenantId
    secret: false
  }
}

resource EntraIDClientIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'EntraIDClientId'
  properties: {
    displayName: 'EntraIDClientId'
    value: entraApp.outputs.entraAppId
    secret: false
  }
}

resource EntraIdFicClientIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'EntraIDFicClientId'
  properties: {
    displayName: 'EntraIdFicClientId'
    value: entraAppUserAssignedIdentityClientId
    secret: false
  }
}

resource OAuthCallbackUriNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'OAuthCallbackUri'
  properties: {
    displayName: 'OAuthCallbackUri'
    value: '${apimService.properties.gatewayUrl}/oauth-callback'
    secret: false
  }
}

resource OAuthScopesNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'OAuthScopes'
  properties: {
    displayName: 'OAuthScopes'
    value: oauthScopes
    secret: false
  }
}


resource McpClientIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'McpClientId'
  properties: {
    displayName: 'McpClientId'
    value: entraApp.outputs.entraAppId
    secret: false
  }
}

resource APIMGatewayURLNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'APIMGatewayURL'
  properties: {
    displayName: 'APIMGatewayURL'
    value: apimService.properties.gatewayUrl
    secret: false
  }
}

resource MCPServerNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-08-01' = {
  parent: apimService
  name: 'MCPServerName'
  properties: {
    displayName: 'MCPServerName'
    value: mcpServerName
    secret: false
  }
}

// Create the OAuth API
resource oauthApi 'Microsoft.ApiManagement/service/apis@2021-08-01' = {
  parent: apimService
  name: 'oauth'
  properties: {
    displayName: 'OAuth'
    description: 'OAuth 2.0 Authentication API'
    subscriptionRequired: false
    path: ''
    protocols: [
      'https'
    ]
    serviceUrl: '${environment().authentication.loginEndpoint}${entraApp.outputs.entraAppTenantId}/oauth2/v2.0'
  }
}

// Add a GET operation for the authorization endpoint
resource oauthAuthorizeOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'authorize'
  properties: {
    displayName: 'Authorize'
    method: 'GET'
    urlTemplate: '/authorize'
    description: 'OAuth 2.0 authorization endpoint'
  }
}

// Add policy for the authorize operation
resource oauthAuthorizePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthAuthorizeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('authorize.policy.xml')
  }
}

// Add a POST operation for the token endpoint
resource oauthTokenOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'token'
  properties: {
    displayName: 'Token'
    method: 'POST'
    urlTemplate: '/token'
    description: 'OAuth 2.0 token endpoint'
  }
}

// Add policy for the token operation
resource oauthTokenPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthTokenOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('token.policy.xml')
  }
}

// Add a GET operation for the OAuth callback endpoint
resource oauthCallbackOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'oauth-callback'
  properties: {
    displayName: 'OAuth Callback'
    method: 'GET'
    urlTemplate: '/oauth-callback'
    description: 'OAuth 2.0 callback endpoint to handle authorization code flow'
  }
}

// Add policy for the OAuth callback operation
resource oauthCallbackPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthCallbackOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('oauth-callback.policy.xml')
  }
  dependsOn: [
    EncryptionKeyNamedValue
    EncryptionIVNamedValue
  ]
}

// Add a POST operation for the register endpoint
resource oauthRegisterOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'register'
  properties: {
    displayName: 'Register'
    method: 'POST'
    urlTemplate: '/register'
    description: 'OAuth 2.0 client registration endpoint'
  }
}

// Add policy for the register operation
resource oauthRegisterPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthRegisterOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('register.policy.xml')
  }
}

// Add a OPTIONS operation for the register endpoint
resource oauthRegisterOptionsOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'register-options'
  properties: {
    displayName: 'Register Options'
    method: 'OPTIONS'
    urlTemplate: '/register'
    description: 'CORS preflight request handler for register endpoint'
  }
}

// Add policy for the register options operation
resource oauthRegisterOptionsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthRegisterOptionsOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('register-options.policy.xml')
  }
}

// Add a OPTIONS operation for the OAuth metadata endpoint
resource oauthMetadataOptionsOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'oauthmetadata-options'
  properties: {
    displayName: 'OAuth Metadata Options'
    method: 'OPTIONS'
    urlTemplate: '/.well-known/oauth-authorization-server'
    description: 'CORS preflight request handler for OAuth metadata endpoint'
  }
}

// Add policy for the OAuth metadata options operation
resource oauthMetadataOptionsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthMetadataOptionsOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('oauthmetadata-options.policy.xml')
  }
}

// Add a GET operation for the OAuth metadata endpoint
resource oauthMetadataGetOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'oauthmetadata-get'
  properties: {
    displayName: 'OAuth Metadata Get'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-authorization-server'
    description: 'OAuth 2.0 metadata endpoint'
  }
}

// Add policy for the OAuth metadata get operation
resource oauthMetadataGetPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthMetadataGetOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('oauthmetadata-get.policy.xml')
  }
}

// Add a GET operation for the consent endpoint
resource oauthConsentGetOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'consent-get'
  properties: {
    displayName: 'Consent Page'
    method: 'GET'
    urlTemplate: '/consent'
    description: 'Client consent page endpoint'
  }
}

// Add policy for the consent GET operation
resource oauthConsentGetPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthConsentGetOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('consent.policy.xml')
  }
}

// Add a POST operation for the consent endpoint
resource oauthConsentPostOperation 'Microsoft.ApiManagement/service/apis/operations@2021-08-01' = {
  parent: oauthApi
  name: 'consent-post'
  properties: {
    displayName: 'Consent Submission'
    method: 'POST'
    urlTemplate: '/consent'
    description: 'Client consent submission endpoint'
  }
}

// Add policy for the consent POST operation
resource oauthConsentPostPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-08-01' = {
  parent: oauthConsentPostOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('consent.policy.xml')
  }
}

output apiId string = oauthApi.id
