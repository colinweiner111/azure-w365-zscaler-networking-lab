@description('Bastion name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('AzureBastionSubnet resource ID')
param subnetId string

@description('Tags')
param tags object = {}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
