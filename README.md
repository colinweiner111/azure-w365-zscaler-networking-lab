# Microsoft 365 + Zscaler Networking Lab

Deployable Bicep lab that provisions the infrastructure described in the [Microsoft 365 + Zscaler Networking Architecture & POC](https://github.com/colinweiner111/azure-w365-zscaler-networking-poc). Two Linux routers forward Microsoft 365 traffic through IPsec tunnels (strongSwan IKEv2 + ESP with VTI) to a Linux NVA that simulates Zscaler ZIA tunnel termination.

> **Why strongSwan IPsec?** Azure does not support GRE (IP protocol 47) — the hypervisor vSwitch drops it in all directions. This lab uses IPsec (IKEv2 + ESP) with route-based VTI interfaces, matching the exact tunnel protocol used in production Zscaler deployments on Azure.

## Table of Contents

- [Lab Topology](#lab-topology)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
  - [1. Clone the repo](#1-clone-the-repo)
  - [2. Create a resource group](#2-create-a-resource-group)
  - [3. Deploy](#3-deploy)
  - [4. Post-deployment: Configure IPsec tunnels](#4-post-deployment-configure-ipsec-tunnels)
- [Testing](#testing)
  - [Test 1 — HTTPS through IPsec tunnel 1](#test-1--https-through-ipsec-tunnel-1)
  - [Test 2 — HTTPS through IPsec tunnel 2](#test-2--https-through-ipsec-tunnel-2)
  - [Test 3 — End-to-end HTTPS](#test-3--end-to-end-https-test-vm--ilb--router--ipsec--nva)
  - [Test 4 — Packet capture](#test-4--verify-traffic-traverses-ipsec-packet-capture)
  - [Test 5 — NVA access log](#test-5--verify-via-nva-access-log)
  - [Test 6 — IPsec + VTI status](#test-6--verify-ipsec-tunnel-status-and-vti-counters)
  - [Test 7 — M365 force-tunnel](#test-7--m365-traffic-path-force-tunnel-behavior)
  - [Test summary](#test-summary)
- [Architecture Reference](#architecture-reference)
- [Production Reference: IPsec Tunnel & Route-Map Configuration](#production-reference-ipsec-tunnel--route-map-configuration)
  - [IPsec Tunnel Configuration](#ipsec-tunnel-configuration-ikev2--vti)
  - [SNAT Configuration](#snat-configuration)
  - [Route-Map: M365 Optimize Breakout](#route-map-m365-optimize-breakout)
  - [Multi-NVA Scaling](#multi-nva-scaling)
  - [Microsoft 365 Subnet UDR](#microsoft-365-subnet-udr)
  - [Lab ↔ Production Mapping](#lab--production-mapping)
- [Clean Up](#clean-up)

---

## Lab Topology

![Lab Topology](images/lab-topology.drawio.svg)

**Source VNet** (`10.100.0.0/24`) — Microsoft 365 side

| Subnet | CIDR | Resources |
|---|---|---|
| W365 Subnet | `10.100.0.0/26` | Test VM (simulates Microsoft 365 Cloud PC), UDR `0.0.0.0/0 -> ILB` |
| Router Subnet | `10.100.0.64/27` | 2 × Linux routers (Ubuntu 22.04) + Internal LB |
| Bastion Subnet | `10.100.0.128/27` | Azure Bastion |

**Destination VNet** (`10.200.0.0/24`) — Zscaler mock

| Subnet | CIDR | Resources |
|---|---|---|
| NVA Subnet | `10.200.0.0/27` | Linux NVA (Ubuntu 22.04 — IPsec termination + nginx HTTPS) |
| Bastion Subnet | `10.200.0.128/27` | Azure Bastion |

**VNet Peering** — bidirectional with `allowForwardedTraffic: true`

**IPsec Tunnels** (IKEv2 + ESP via strongSwan, over private IPs via VNet peering)

| Tunnel | VTI Key | Source (Router) | Destination (NVA) | Overlay |
|---|---|---|---|---|
| vti1 | 1 | Router-1 private IP | NVA private IP | `172.16.0.0/30` |
| vti2 | 2 | Router-2 private IP | NVA private IP | `172.16.0.4/30` |

> **Traffic path:** Test VM → UDR → ILB (HA Ports, Floating IP) → Linux Router → SNAT → IPsec tunnel → Linux NVA

---

## Prerequisites

- Azure subscription with permissions to create resources
- Azure CLI (`az`) installed and authenticated

---

## Deployment

### 1. Clone the repo

```bash
git clone https://github.com/colinweiner111/azure-w365-zscaler-networking-lab.git
cd azure-w365-zscaler-networking-lab
```

### 2. Create a resource group

```bash
az group create --name rg-w365-zscaler-lab --location centralus
```

### 3. Deploy

```bash
az deployment group create \
  --resource-group rg-w365-zscaler-lab \
  --template-file deploy.bicep \
  --parameters deploy.bicepparam \
  --name w365-zscaler-lab
```

> Deployment takes approximately 10–15 minutes (Bastion hosts take the longest).

### 4. Post-deployment: Configure IPsec tunnels

After deployment completes, run the commands below from your local terminal. They pull the private IPs from the deployment outputs and configure each VM remotely — no need to SSH in manually.

**Step 1 — Save the deployment outputs as variables:**
```bash
ROUTER1_IP=$(az deployment group show --resource-group rg-w365-zscaler-lab --name w365-zscaler-lab --query "properties.outputs.router1PrivateIp.value" -o tsv)
ROUTER2_IP=$(az deployment group show --resource-group rg-w365-zscaler-lab --name w365-zscaler-lab --query "properties.outputs.router2PrivateIp.value" -o tsv)
NVA_IP=$(az deployment group show --resource-group rg-w365-zscaler-lab --name w365-zscaler-lab --query "properties.outputs.linuxNvaPrivateIp.value" -o tsv)

echo "Router-1: $ROUTER1_IP  Router-2: $ROUTER2_IP  NVA: $NVA_IP"
```

**Step 2 — Configure Router-1:**
```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-1 \
  --command-id RunShellScript \
  --scripts "sudo /usr/local/bin/configure-tunnel.sh $ROUTER1_IP $NVA_IP 1"
```

**Step 3 — Configure Router-2:**
```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-2 \
  --command-id RunShellScript \
  --scripts "sudo /usr/local/bin/configure-tunnel.sh $ROUTER2_IP $NVA_IP 2"
```

**Step 4 — Configure the Linux NVA:**
```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name linux-nva \
  --command-id RunShellScript \
  --scripts "sudo /usr/local/bin/configure-tunnel.sh $NVA_IP $ROUTER1_IP $ROUTER2_IP"
```

> The `configure-tunnel.sh` scripts are installed by cloud-init during VM provisioning. They create IPsec VTI interfaces via strongSwan, assign overlay IPs, configure SNAT (routers), and add return routes (NVA).

---

## Testing

The NVA runs nginx with a self-signed TLS certificate (installed via cloud-init), serving an HTTPS health endpoint that simulates Zscaler web inspection. All tests use `az vm run-command invoke` — no Bastion or SSH required.

### Test 1 — HTTPS through IPsec tunnel 1

```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-1 \
  --command-id RunShellScript \
  --scripts "curl -sk https://172.16.0.2/health" \
  --query 'value[0].message' -o tsv
```

**Expected:** `OK`. Confirms HTTPS works end-to-end through IPsec tunnel 1 (VTI key 1).

### Test 2 — HTTPS through IPsec tunnel 2

```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-2 \
  --command-id RunShellScript \
  --scripts "curl -sk https://172.16.0.6/health" \
  --query 'value[0].message' -o tsv
```

**Expected:** `OK`. Confirms HTTPS through IPsec tunnel 2 (VTI key 2).

### Test 3 — End-to-end HTTPS: Test VM → ILB → Router → IPsec → NVA

```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name vm-w365-test \
  --command-id RunPowerShellScript \
  --scripts "curl.exe -sk https://172.16.0.2/health" \
  --query 'value[0].message' -o tsv
```

**Expected:** `OK`. This proves the complete HTTPS path:

```
Test VM (10.100.0.4)
    → UDR (0.0.0.0/0 → 10.100.0.68)
    → ILB (HA Ports, Floating IP preserves original dest)
    → Router-1 or Router-2 (SNAT + IPsec encap)
    → VNet peering (private IP underlay)
    → Linux NVA nginx (IPsec decap → TLS termination at 172.16.0.2:443)
```

> **Why `172.16.0.2`?** Traffic to `10.200.0.4` takes the VNet peering system route, bypassing the ILB and IPsec. `172.16.0.2` has no system route, so it hits the UDR `0.0.0.0/0 → ILB` and proves the full tunnel path.

> **Key config:** FloatingIP must be enabled on the ILB so the original dest IP (`172.16.0.2`) is preserved. NSGs on the W365 and router subnets need explicit allow rules for `172.16.0.0/28` — these VTI addresses are outside the `VirtualNetwork` service tag.

### Test 4 — Verify traffic traverses IPsec (packet capture)

This proves HTTPS traffic is encrypted inside the IPsec tunnel, not sent in the clear over Azure networking.

> **Note:** The lab uses `forceencaps=yes` (NAT-T), so ESP is wrapped inside UDP port 4500. Use `udp port 4500` as the tcpdump filter — a raw `esp` filter will not match.

```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-1 \
  --command-id RunShellScript \
  --scripts "bash -c 'timeout 8 tcpdump -i eth0 udp port 4500 -nn -c 10 \
    > /tmp/cap.txt 2>&1 & sleep 1; curl -sk https://172.16.0.2/health; \
    sleep 5; cat /tmp/cap.txt'" \
  --query 'value[0].message' -o tsv
```

**Expected output** (HTTPS packets wrapped in ESP-in-UDP):
```
IP 10.100.0.69.4500 > 10.200.0.4.4500: UDP-encap: ESP(spi=0xXXXXXXXX,seq=0xN), length ...
IP 10.200.0.4.4500 > 10.100.0.69.4500: UDP-encap: ESP(spi=0xXXXXXXXX,seq=0xN), length ...
```

The ESP-in-UDP packets prove:
- **Outer header:** `10.100.0.69:4500 → 10.200.0.4:4500` (NAT-T encapsulation over VNet peering)
- **Inner payload:** encrypted HTTPS (TCP 443) traffic inside the IPsec tunnel

### Test 5 — Verify via NVA access log

```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name linux-nva \
  --command-id RunShellScript \
  --scripts "tail -10 /var/log/nginx/access.log" \
  --query 'value[0].message' -o tsv
```

**Expected:** Log entries showing requests from overlay IPs:
```
172.16.0.1 - - [timestamp] "GET /health HTTP/1.1" 200 2 "-" "curl/7.81.0"
172.16.0.5 - - [timestamp] "GET /health HTTP/1.1" 200 2 "-" "curl/7.81.0"
```

Source `172.16.0.1` = Router-1 (after SNAT), `172.16.0.5` = Router-2. This confirms HTTPS arrived through the IPsec overlay, not via the Azure underlay.

### Test 6 — Verify IPsec tunnel status and VTI counters

```bash
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name linux-nva \
  --command-id RunShellScript \
  --scripts "echo '=== IKE SAs ==='; ipsec status | grep ESTABLISHED; echo; \
    echo '=== ESP SAs ==='; ipsec status | grep INSTALLED; echo; \
    echo '=== vti1 (peer router-1) ==='; ip -s link show vti1 | grep -E 'state|peer|RX:|TX:' -A1; echo; \
    echo '=== vti2 (peer router-2) ==='; ip -s link show vti2 | grep -E 'state|peer|RX:|TX:' -A1" \
  --query "value[0].message" --output tsv
```

**Expected output:**
```
=== IKE SAs ===
tunnel1[...]: ESTABLISHED ... 10.200.0.4...10.100.0.69
tunnel2[...]: ESTABLISHED ... 10.200.0.4...10.100.0.70

=== ESP SAs ===
tunnel1{...}: INSTALLED, TUNNEL, reqid 1, ESP in UDP SPIs: ...
tunnel2{...}: INSTALLED, TUNNEL, reqid 2, ESP in UDP SPIs: ...

=== vti1 (peer router-1) ===
vti1@NONE: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1400 ... state UNKNOWN
    link/ipip 10.200.0.4 peer 10.100.0.69
    RX:  bytes packets ...
         13027     109  ...
    TX:  bytes packets ...
         33827     112  ...

=== vti2 (peer router-2) ===
vti2@NONE: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1400 ... state UNKNOWN
    link/ipip 10.200.0.4 peer 10.100.0.70
    RX:  bytes packets ...
          5256      43  ...
    TX:  bytes packets ...
         10700      35  ...
```

Both IKE SAs should show `ESTABLISHED`, both ESP SAs `INSTALLED`, and VTI RX/TX byte counts should be non-zero.

### Test 7 — M365 traffic path (force-tunnel behavior)

The UDR sends `0.0.0.0/0` to the ILB, meaning **all traffic** from the W365 subnet — including M365 — is force-tunneled through the routers. This matches the Zscaler ZIA deployment model.

This test requires RDP to the **Test VM** via Bastion. Open a command prompt:
```
tracert -h 5 -d outlook.office365.com
```

**Expected:** First hop is `10.100.0.69` or `10.100.0.70` (a router via ILB), confirming M365 traffic is also routed through the tunnel path.

> **Split-tunnel note:** In production, Zscaler uses PAC files or explicit proxy configuration to split M365 Optimize/Allow traffic direct while routing general web through ZIA. This lab demonstrates the force-tunnel baseline. To implement split-tunnel, add specific routes for [M365 endpoints](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges) to the UDR with next-hop `Internet`.

### Test summary

| # | Test | From | Command | Expected |
|---|---|---|---|---|
| 1 | HTTPS tunnel 1 | router-1 | `curl -sk https://172.16.0.2/health` | `OK` (HTTP 200) |
| 2 | HTTPS tunnel 2 | router-2 | `curl -sk https://172.16.0.6/health` | `OK` (HTTP 200) |
| 3 | HTTPS end-to-end | vm-w365-test | `curl.exe -sk https://172.16.0.2/health` | `OK` (HTTP 200) |
| 4 | Packet capture | router-1 | `tcpdump -i eth0 udp port 4500` | ESP-in-UDP encapsulated traffic |
| 5 | NVA access log | linux-nva | `tail /var/log/nginx/access.log` | Requests from `172.16.0.1`/`.5` |
| 6 | IPsec + VTI status | linux-nva | `ipsec statusall` + `ip -s link show vti1` | ESTABLISHED SAs, non-zero RX/TX |
| 7 | M365 force-tunnel | vm-w365-test (Bastion RDP) | `tracert outlook.office365.com` | First hop = router IP |

---

## Architecture Reference

This lab implements the architecture defined in:
**[Microsoft 365 + Zscaler Networking Architecture & POC](https://github.com/colinweiner111/azure-w365-zscaler-networking-poc)**

---

## Production Reference: IPsec Tunnel & Route-Map Configuration

This lab uses Linux routers with strongSwan IPsec (IKEv2 + ESP + VTI), matching the production tunnel protocol. Below are the production C8000V NVA configs for reference.

### IPsec Tunnel Configuration (IKEv2 + VTI)

```
! --- IKEv2 Proposal ---
crypto ikev2 proposal ZSCALER_PROPOSAL
 encryption aes-cbc-256
 integrity sha256
 group 14
!
! --- IKEv2 Policy ---
crypto ikev2 policy ZSCALER_POLICY
 proposal ZSCALER_PROPOSAL
!
! --- IKEv2 Keyring ---
crypto ikev2 keyring ZSCALER_KEYRING
 peer ZSCALER_ZEN_PRIMARY
  address <ZSCALER_ZEN_PRIMARY_IP>
  pre-shared-key <PSK>
 peer ZSCALER_ZEN_SECONDARY
  address <ZSCALER_ZEN_SECONDARY_IP>
  pre-shared-key <PSK>
!
! --- IKEv2 Profile ---
crypto ikev2 profile ZSCALER_PROFILE
 match identity remote address <ZSCALER_ZEN_PRIMARY_IP> 255.255.255.255
 match identity remote address <ZSCALER_ZEN_SECONDARY_IP> 255.255.255.255
 authentication remote pre-share
 authentication local pre-share
 keyring local ZSCALER_KEYRING
!
! --- IPsec Transform Set ---
crypto ipsec transform-set ZSCALER_TS esp-aes 256 esp-sha256-hmac
 mode tunnel
!
! --- IPsec Profile ---
crypto ipsec profile ZSCALER_IPSEC_PROFILE
 set transform-set ZSCALER_TS
 set ikev2-profile ZSCALER_PROFILE
!
! --- IPsec VTI to Zscaler ZEN (primary) ---
interface Tunnel0
 description IPsec VTI to Zscaler ZEN - Primary
 ip address 172.16.0.1 255.255.255.252
 ip mtu 1400
 ip tcp adjust-mss 1360
 tunnel source GigabitEthernet1
 tunnel destination <ZSCALER_ZEN_PRIMARY_IP>
 tunnel mode ipsec ipv4
 tunnel protection ipsec profile ZSCALER_IPSEC_PROFILE
 keepalive 10 3
!
! --- IPsec VTI to Zscaler ZEN (secondary) ---
interface Tunnel1
 description IPsec VTI to Zscaler ZEN - Secondary
 ip address 172.16.0.5 255.255.255.252
 ip mtu 1400
 ip tcp adjust-mss 1360
 tunnel source GigabitEthernet1
 tunnel destination <ZSCALER_ZEN_SECONDARY_IP>
 tunnel mode ipsec ipv4
 tunnel protection ipsec profile ZSCALER_IPSEC_PROFILE
 keepalive 10 3
```

### SNAT Configuration

```
! --- NAT inside/outside ---
interface GigabitEthernet1
 ip nat outside
!
interface Tunnel0
 ip nat outside
!
interface Tunnel1
 ip nat outside
!
! --- PAT via NVA public IP (return-path symmetry through ILB) ---
ip nat inside source list NAT_ACL interface GigabitEthernet1 overload
!
ip access-list extended NAT_ACL
 permit ip 10.100.0.0 0.0.0.63 any
```

### Route-Map: M365 Optimize Breakout

```
! --- M365 Optimize prefix list ---
! Source: https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges
ip prefix-list M365_OPTIMIZE seq 10 permit 13.107.64.0/18
ip prefix-list M365_OPTIMIZE seq 20 permit 52.112.0.0/14
ip prefix-list M365_OPTIMIZE seq 30 permit 52.120.0.0/14
ip prefix-list M365_OPTIMIZE seq 40 permit 52.122.0.0/15
ip prefix-list M365_OPTIMIZE seq 50 permit 104.146.128.0/17
ip prefix-list M365_OPTIMIZE seq 60 permit 150.171.32.0/22
ip prefix-list M365_OPTIMIZE seq 70 permit 150.171.40.0/22
!
! --- ACL matching M365 Optimize destinations ---
ip access-list extended M365_OPTIMIZE_ACL
 permit ip 10.100.0.0 0.0.0.63 13.107.64.0 0.0.63.255
 permit ip 10.100.0.0 0.0.0.63 52.112.0.0 0.3.255.255
 permit ip 10.100.0.0 0.0.0.63 52.120.0.0 0.3.255.255
 permit ip 10.100.0.0 0.0.0.63 52.122.0.0 0.1.255.255
 permit ip 10.100.0.0 0.0.0.63 104.146.128.0 0.0.127.255
 permit ip 10.100.0.0 0.0.0.63 150.171.32.0 0.0.3.255
 permit ip 10.100.0.0 0.0.0.63 150.171.40.0 0.0.3.255
!
! --- Route-map: M365 Optimize → direct internet, all else → IPsec ---
route-map TRAFFIC_STEERING permit 10
 description M365 Optimize - direct internet breakout
 match ip address M365_OPTIMIZE_ACL
 set interface GigabitEthernet1
!
route-map TRAFFIC_STEERING permit 20
 description All other internet - IPsec to Zscaler
 set interface Tunnel0
!
! --- Apply to inbound interface ---
interface GigabitEthernet1
 ip policy route-map TRAFFIC_STEERING
```

### Multi-NVA Scaling

```
  NVA-1 (PIP-1) ──── IPsec Tunnel A ────┐
  NVA-2 (PIP-2) ──── IPsec Tunnel B ────┼──── Zscaler ZEN
  NVA-3 (PIP-3) ──── IPsec Tunnel C ────┤
  NVA-4 (PIP-4) ──── IPsec Tunnel D ────┘
```

### Microsoft 365 Subnet UDR

| UDR Destination | Next Hop | Purpose |
|---|---|---|
| `0.0.0.0/0` | ILB frontend IP | All internet → ILB → NVA → route-map decision |
| `10.0.0.0/8` | Firewall private IP | East-west: spoke-to-spoke, private endpoints |
| `172.16.0.0/12` | Firewall private IP | East-west: spoke-to-spoke, on-premises |

### Lab ↔ Production Mapping

| Lab Component | Production Equivalent |
|---|---|
| Linux router (Ubuntu) + strongSwan IPsec VTI | NVA appliance + IPsec tunnel |
| iptables MASQUERADE | `ip nat inside source` (PAT) |
| Linux NVA (nginx) | Zscaler ZEN node |
| strongSwan VTI config | `interface Tunnel` (IPsec VTI) |
| UDR `0.0.0.0/0` → ILB | Same |
| All traffic force-tunneled | Route-map splits M365 direct vs. IPsec |

---

## Clean Up

```bash
az group delete --name rg-w365-zscaler-lab --yes --no-wait
```
