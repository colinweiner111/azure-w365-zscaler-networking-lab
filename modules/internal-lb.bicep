@description('Load balancer name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Subnet resource ID for the frontend IP')
param subnetId string

@description('Frontend private IP address')
param frontendIp string

@description('Tags')
param tags object = {}

resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: frontendIp
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'router-pool'
      }
    ]
    loadBalancingRules: [
      {
        name: 'ha-ports'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', name, 'frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', name, 'router-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', name, 'health-probe')
          }
          protocol: 'All'
          frontendPort: 0
          backendPort: 0
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'SourceIP'
        }
      }
    ]
    probes: [
      {
        name: 'health-probe'
        properties: {
          protocol: 'Tcp'
          port: 22
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

output lbId string = lb.id
output backendPoolId string = lb.properties.backendAddressPools[0].id
output frontendIp string = lb.properties.frontendIPConfigurations[0].properties.privateIPAddress
