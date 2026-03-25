// ============================================================
// Microsoft 365 + Zscaler Networking Lab
// Main deployment orchestrator
// ============================================================

targetScope = 'resourceGroup'

@description('Azure region')
param location string = resourceGroup().location

@description('Admin username for all VMs')
param adminUsername string

@secure()
@description('Admin password for all VMs')
param adminPassword string

@description('Source-side Linux router VM size')
param routerVmSize string = 'Standard_D2s_v5'

@description('Tags applied to all resources')
param tags object = {
  project: 'w365-zscaler-lab'
  environment: 'lab'
}

// ============================================================
// Variables
// ============================================================

var sourceVnetName = 'vnet-source-w365'
var destVnetName = 'vnet-dest-zscaler'
var ilbFrontendIp = '10.100.0.68' // Static IP in router subnet

// Cloud-init for destination NVA (simulates Zscaler)
var cloudInitDest = loadFileAsBase64('scripts/cloud-init-dest-nva.yaml')

// Cloud-init for source-side Linux routers (IPsec VTI + SNAT)
var cloudInitSource = loadFileAsBase64('scripts/cloud-init-source-router.yaml')

// NSG rules for router subnet — allow IPsec (IKE + NAT-T + ESP) inbound
var routerNsgRules = [
  {
    name: 'AllowIKE-Inbound'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Udp'
      sourcePortRange: '*'
      destinationPortRange: '500'
      sourceAddressPrefix: '10.200.0.0/24'
      destinationAddressPrefix: '*'
      description: 'Allow IKE (UDP 500) from dest VNet'
    }
  }
  {
    name: 'AllowNATT-Inbound'
    properties: {
      priority: 101
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Udp'
      sourcePortRange: '*'
      destinationPortRange: '4500'
      sourceAddressPrefix: '10.200.0.0/24'
      destinationAddressPrefix: '*'
      description: 'Allow IPsec NAT-T (UDP 4500) from dest VNet'
    }
  }
  {
    name: 'AllowESP-Inbound'
    properties: {
      priority: 102
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '10.200.0.0/24'
      destinationAddressPrefix: '*'
      description: 'Allow ESP (protocol 50) from dest VNet'
    }
  }
  {
    name: 'AllowSSH-Inbound'
    properties: {
      priority: 110
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '22'
      sourceAddressPrefix: '10.100.0.128/27'
      destinationAddressPrefix: '*'
      description: 'Allow SSH from Bastion subnet'
    }
  }
  {
    name: 'AllowForwardedTraffic-Inbound'
    properties: {
      priority: 200
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '10.100.0.0/26'
      destinationAddressPrefix: '*'
      description: 'Allow UDR-forwarded traffic from W365 subnet (FloatingIP preserves original dst)'
    }
  }
]

// NSG rules for W365 subnet — allow outbound to VTI overlay addresses
var w365NsgRules = [
  {
    name: 'AllowVtiOverlay-Outbound'
    properties: {
      priority: 100
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '10.100.0.0/26'
      destinationAddressPrefix: '172.16.0.0/28'
      description: 'Allow outbound to VTI overlay addresses (not in VirtualNetwork service tag)'
    }
  }
]

// NSG rules for destination NVA subnet
var destNvaNsgRules = [
  {
    name: 'AllowIKE-Inbound'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Udp'
      sourcePortRange: '*'
      destinationPortRange: '500'
      sourceAddressPrefix: '10.100.0.0/24'
      destinationAddressPrefix: '*'
      description: 'Allow IKE (UDP 500) from source VNet'
    }
  }
  {
    name: 'AllowNATT-Inbound'
    properties: {
      priority: 101
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Udp'
      sourcePortRange: '*'
      destinationPortRange: '4500'
      sourceAddressPrefix: '10.100.0.0/24'
      destinationAddressPrefix: '*'
      description: 'Allow IPsec NAT-T (UDP 4500) from source VNet'
    }
  }
  {
    name: 'AllowESP-Inbound'
    properties: {
      priority: 102
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '10.100.0.0/24'
      destinationAddressPrefix: '*'
      description: 'Allow ESP (protocol 50) from source VNet'
    }
  }
  {
    name: 'AllowSSH-Inbound'
    properties: {
      priority: 110
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '22'
      sourceAddressPrefix: '10.200.0.128/27'
      destinationAddressPrefix: '*'
      description: 'Allow SSH from Bastion subnet'
    }
  }
]

// ============================================================
// UDR — Microsoft 365 subnet default route to ILB
// ============================================================

resource udrW365 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'udr-w365-subnet'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-ilb'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: ilbFrontendIp
        }
      }
    ]
  }
}

// ============================================================
// Source VNet (Microsoft 365 side)
// ============================================================

module sourceVnet 'modules/vnet.bicep' = {
  name: 'deploy-source-vnet'
  params: {
    name: sourceVnetName
    location: location
    addressPrefix: '10.100.0.0/24'
    tags: tags
    subnets: [
      {
        name: 'snet-w365'
        addressPrefix: '10.100.0.0/26'
        routeTableId: udrW365.id
        nsgRules: w365NsgRules
      }
      {
        name: 'snet-router'
        addressPrefix: '10.100.0.64/27'
        nsgRules: routerNsgRules
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.100.0.128/27'
      }
    ]
  }
}

// ============================================================
// Destination VNet (Zscaler mock)
// ============================================================

module destVnet 'modules/vnet.bicep' = {
  name: 'deploy-dest-vnet'
  params: {
    name: destVnetName
    location: location
    addressPrefix: '10.200.0.0/24'
    tags: tags
    subnets: [
      {
        name: 'snet-nva'
        addressPrefix: '10.200.0.0/27'
        nsgRules: destNvaNsgRules
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: '10.200.0.128/27'
      }
    ]
  }
}

// ============================================================
// VNet Peering (required for IPsec between VNets)
// ============================================================

resource peeringSourceToDest 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: '${sourceVnetName}/source-to-dest'
  properties: {
    remoteVirtualNetwork: {
      id: destVnet.outputs.vnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
  dependsOn: [sourceVnet]
}

resource peeringDestToSource 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  name: '${destVnetName}/dest-to-source'
  properties: {
    remoteVirtualNetwork: {
      id: sourceVnet.outputs.vnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
  dependsOn: [destVnet]
}

// ============================================================
// Internal Load Balancer (HA Ports)
// ============================================================

module ilb 'modules/internal-lb.bicep' = {
  name: 'deploy-ilb'
  params: {
    name: 'ilb-router'
    location: location
    subnetId: sourceVnet.outputs.subnetIds['snet-router']
    frontendIp: ilbFrontendIp
    tags: tags
  }
}

// ============================================================
// Source-side Linux routers (IPsec VTI + SNAT)
// ============================================================

module router1 'modules/linux-nva.bicep' = {
  name: 'deploy-router-1'
  params: {
    name: 'router-1'
    location: location
    subnetId: sourceVnet.outputs.subnetIds['snet-router']
    vmSize: routerVmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    cloudInitBase64: cloudInitSource
    lbBackendPoolId: ilb.outputs.backendPoolId
    tags: tags
  }
}

module router2 'modules/linux-nva.bicep' = {
  name: 'deploy-router-2'
  params: {
    name: 'router-2'
    location: location
    subnetId: sourceVnet.outputs.subnetIds['snet-router']
    vmSize: routerVmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    cloudInitBase64: cloudInitSource
    lbBackendPoolId: ilb.outputs.backendPoolId
    tags: tags
  }
}

// ============================================================
// Linux NVA (destination side — simulates Zscaler)
// ============================================================

module linuxNva 'modules/linux-nva.bicep' = {
  name: 'deploy-linux-nva'
  params: {
    name: 'linux-nva'
    location: location
    subnetId: destVnet.outputs.subnetIds['snet-nva']
    adminUsername: adminUsername
    adminPassword: adminPassword
    cloudInitBase64: cloudInitDest
    tags: tags
  }
}

// ============================================================
// Test VM (simulates Microsoft 365 Cloud PC)
// ============================================================

module testVm 'modules/test-vm.bicep' = {
  name: 'deploy-test-vm'
  params: {
    name: 'vm-w365-test'
    location: location
    subnetId: sourceVnet.outputs.subnetIds['snet-w365']
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
  }
}

// ============================================================
// Bastion — Source VNet
// ============================================================

module bastionSource 'modules/bastion.bicep' = {
  name: 'deploy-bastion-source'
  params: {
    name: 'bastion-source'
    location: location
    subnetId: sourceVnet.outputs.subnetIds.AzureBastionSubnet
    tags: tags
  }
}

// ============================================================
// Bastion — Destination VNet
// ============================================================

module bastionDest 'modules/bastion.bicep' = {
  name: 'deploy-bastion-dest'
  params: {
    name: 'bastion-dest'
    location: location
    subnetId: destVnet.outputs.subnetIds.AzureBastionSubnet
    tags: tags
  }
}

// ============================================================
// Outputs
// ============================================================

output router1PublicIp string = router1.outputs.publicIp
output router1PrivateIp string = router1.outputs.privateIp
output router2PublicIp string = router2.outputs.publicIp
output router2PrivateIp string = router2.outputs.privateIp
output linuxNvaPublicIp string = linuxNva.outputs.publicIp
output linuxNvaPrivateIp string = linuxNva.outputs.privateIp
output testVmPrivateIp string = testVm.outputs.privateIp
output ilbFrontendIp string = ilb.outputs.frontendIp

output postDeploymentInstructions string = '''
=== Post-Deployment Steps ===
IPsec VTI tunnels over VNet peering (IKEv2 + ESP via strongSwan).
Use private IPs from the outputs below.

1. SSH to Router-1 via Bastion and run:
   sudo /usr/local/bin/configure-tunnel.sh <router1PrivateIp> <linuxNvaPrivateIp> 1

2. SSH to Router-2 via Bastion and run:
   sudo /usr/local/bin/configure-tunnel.sh <router2PrivateIp> <linuxNvaPrivateIp> 2

3. SSH to Linux NVA via Bastion and run:
   sudo /usr/local/bin/configure-tunnel.sh <linuxNvaPrivateIp> <router1PrivateIp> <router2PrivateIp>

4. Verify tunnels: ping 172.16.0.2 from Router-1, ping 172.16.0.6 from Router-2

5. Test end-to-end: RDP to test VM via Bastion, verify traffic flows through ILB -> Router -> IPsec -> NVA
'''
