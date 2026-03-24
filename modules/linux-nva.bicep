@description('Linux NVA name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Subnet resource ID')
param subnetId string

@description('VM size')
param vmSize string = 'Standard_D2s_v5'

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password')
param adminPassword string

@description('Cloud-init script (base64 encoded)')
param cloudInitBase64 string

@description('Tags')
param tags object = {}

@description('Optional: LB backend pool ID to associate with')
param lbBackendPoolId string = ''

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

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: pip.id
          }
          loadBalancerBackendAddressPools: lbBackendPoolId != ''
            ? [{ id: lbBackendPoolId }]
            : []
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: cloudInitBase64
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmName string = vm.name
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output publicIp string = pip.properties.ipAddress
output nicId string = nic.id
