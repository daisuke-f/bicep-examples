param teamsGroupId string
param teamsChannelId string
param location string = resourceGroup().location

var prefix = 'postteamsmessage'
var uniqueId = substring(uniqueString(resourceGroup().id), 0, 8)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${prefix}${uniqueId}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }

  resource tableService 'tableServices@2023-05-01' = {
    name: 'default'

    resource messages 'tables@2023-05-01' = {
      name: 'Messages'
    }
  }
}

resource connections_azuretables 'Microsoft.Web/connections@2016-06-01' = {
  name: 'tableconnection'
  location: location
  properties: {
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuretables')
    }
    parameterValues: {
      storageaccount: storageAccount.name
      sharedkey: storageAccount.listkeys().keys[0].value
    }
  }
}

resource connections_teams 'Microsoft.Web/connections@2016-06-01' = {
  name: 'teamsconnection'
  location: location
  properties: {
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
    }
  }
}

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: prefix
  location: location
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        TeamsGroupId: {
          defaultValue: teamsGroupId
          type: 'String'
        }
        TeamsChannelId: {
          defaultValue: teamsChannelId
          type: 'String'
        }
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        When_a_HTTP_request_is_received: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            method: 'POST'
            schema: {
              type: 'object'
              required: [
                'key'
                'message'
              ]
              properties: {
                key: {
                  type: 'string'
                }
                subject: {
                  type: 'string'
                }
                message: {
                  type: 'string'
                }
              }
            }
          }
        }
      }
      actions: {
        Response: {
          runAfter: {
            Condition: [
              'Succeeded'
            ]
          }
          type: 'Response'
          kind: 'Http'
          inputs: {
            statusCode: 200
            body: {
              MessageId: '@{body(\'Post_new_message\')?[\'id\']}@{body(\'Reply_with_a_message\')?[\'id\']}'
              ConversationId: '@{body(\'Post_new_message\')?[\'conversationId\']}@{body(\'Reply_with_a_message\')?[\'conversationId\']}'
              MessageLink: '@{body(\'Post_new_message\')?[\'messageLink\']}@{body(\'Reply_with_a_message\')?[\'messageLink\']}'
            }
            schema: {
              type: 'object'
              properties: {
                MessageId: {
                  type: 'string'
                }
              }
            }
          }
        }
        'Get_entity_(V2)': {
          runAfter: {}
          type: 'ApiConnection'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'azuretables\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/v2/storageAccounts/@{encodeURIComponent(encodeURIComponent(\'AccountNameFromSettings\'))}/tables/@{encodeURIComponent(\'Messages\')}/entities(PartitionKey=\'@{encodeURIComponent(\'Default\')}\',RowKey=\'@{encodeURIComponent(triggerBody()?[\'key\'])}\')'
          }
        }
        Condition: {
          actions: {
            Post_new_message: {
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']'
                  }
                }
                method: 'post'
                body: {
                  recipient: {
                    groupId: '@parameters(\'TeamsGroupId\')'
                    channelId: '@parameters(\'TeamsChannelId\')'
                  }
                  messageBody: '<p class="editor-paragraph">Message via Azure Logic Apps!</p><p class="editor-paragraph">message: @{triggerBody()?[\'message\']}</p>'
                  subject: '@triggerBody()?[\'subject\']'
                }
                path: '/beta/teams/conversation/message/poster/@{encodeURIComponent(\'User\')}/location/@{encodeURIComponent(\'Channel\')}'
              }
            }
            'Insert_Entity_(V2)': {
              runAfter: {
                Post_new_message: [
                  'Succeeded'
                ]
              }
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '@parameters(\'$connections\')[\'azuretables\'][\'connectionId\']'
                  }
                }
                method: 'post'
                body: {
                  PartitionKey: 'Default'
                  RowKey: '@{triggerBody()?[\'key\']}'
                  MessageId: '@{body(\'Post_new_message\')?[\'id\']}'
                }
                path: '/v2/storageAccounts/@{encodeURIComponent(encodeURIComponent(\'AccountNameFromSettings\'))}/tables/@{encodeURIComponent(\'Messages\')}/entities'
              }
            }
          }
          runAfter: {
            'Get_entity_(V2)': [
              'Succeeded'
              'Failed'
            ]
          }
          else: {
            actions: {
              Reply_with_a_message: {
                type: 'ApiConnection'
                inputs: {
                  host: {
                    connection: {
                      name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']'
                    }
                  }
                  method: 'post'
                  body: {
                    parentMessageId: '@body(\'Get_entity_(V2)\')[\'MessageId\']'
                    recipient: {
                      groupId: '@parameters(\'TeamsGroupId\')'
                      channelId: '@parameters(\'TeamsChannelId\')'
                    }
                    messageBody: '<p class="editor-paragraph">@{triggerBody()?[\'message\']}</p>'
                  }
                  path: '/v1.0/teams/conversation/replyWithMessage/poster/@{encodeURIComponent(\'User\')}/location/@{encodeURIComponent(\'Channel\')}'
                }
              }
            }
          }
          expression: {
            and: [
              {
                equals: [
                  '@outputs(\'Get_entity_(V2)\').statusCode'
                  404
                ]
              }
            ]
          }
          type: 'If'
        }
      }
      outputs: {}
    }
    parameters: {
      '$connections': {
        value: {
          azuretables: {
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuretables')
            connectionId: connections_azuretables.id
            connectionName: 'azuretables'
          }
          teams: {
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
            connectionId: connections_teams.id
            connectionName: 'teams'
          }
        }
      }
    }
  }
}

