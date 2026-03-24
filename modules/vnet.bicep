@description('VNet name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('VNet address space')
param addressPrefix string

@description('Subnet definitions')
param subnets array

@description('Tags')
param tags object = {}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [
  for subnet in subnets: if (subnet.name != 'AzureBastionSubnet') {
    name: 'nsg-${subnet.name}'
    location: location
    tags: tags
    properties: {
      securityRules: contains(subnet, 'nsgRules') ? subnet.nsgRules! : []
    }
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      for (subnet, i) in subnets: {
        name: subnet.name
        properties: {
          addressPrefix: subnet.addressPrefix
          networkSecurityGroup: subnet.name != 'AzureBastionSubnet'
            ? { id: nsg[i].id }
            : null
          routeTable: contains(subnet, 'routeTableId') && subnet.routeTableId != ''
            ? { id: subnet.routeTableId }
            : null
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetIds object = reduce(vnet.properties.subnets, {}, (cur, next) => union(cur, { '${next.name}': next.id }))
