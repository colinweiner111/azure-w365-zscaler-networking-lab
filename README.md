# Microsoft 365 + Zscaler Networking Lab

Deployable Bicep lab that provisions the infrastructure described in the [Microsoft 365 + Zscaler Networking Architecture & POC](https://github.com/colinweiner111/azure-w365-zscaler-networking-poc). Two Linux routers forward Microsoft 365 traffic through VXLAN tunnels to a Linux NVA that simulates Zscaler ZIA tunnel termination.

> **Why VXLAN instead of GRE?** Azure's SDN drops IP protocol 47 (GRE) between VMs. VXLAN (UDP 4789) over VNet peering is the supported alternative.

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
| NVA Subnet | `10.200.0.0/27` | Linux NVA (Ubuntu 22.04 — VXLAN termination) |
| Bastion Subnet | `10.200.0.128/27` | Azure Bastion |

**VNet Peering** — bidirectional with `allowForwardedTraffic: true`

**VXLAN Tunnels** (over private IPs via VNet peering)

| Tunnel | VNI | Source (Router) | Destination (NVA) | Overlay |
|---|---|---|---|---|
| vxlan1 | 100 | Router-1 private IP | NVA private IP | `172.16.0.0/30` |
| vxlan2 | 200 | Router-2 private IP | NVA private IP | `172.16.0.4/30` |

> **Traffic path:** Test VM → UDR → ILB (HA Ports) → Linux Router → SNAT → VXLAN tunnel → Linux NVA

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

### 4. Post-deployment: Configure VXLAN tunnels

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

> The `configure-tunnel.sh` scripts are installed by cloud-init during VM provisioning. They create the VXLAN interfaces, assign overlay IPs, configure SNAT (routers), and add return routes (NVA).

---

## Testing

After configuring the VXLAN tunnels, run the following tests to validate HTTPS traffic through the full path and verify it traverses the VXLAN tunnel.

The NVA runs nginx with a self-signed TLS certificate (installed via cloud-init), serving an HTTPS health endpoint that simulates Zscaler web inspection.

### Test 1 — HTTPS through VXLAN tunnel 1

SSH to **Router-1** via Bastion:
```bash
curl -sk -o /dev/null -w 'Status: %{http_code}, Time: %{time_total}s\n' https://172.16.0.2/health
curl -sk https://172.16.0.2/health
```
**Expected:** `Status: 200`, response `OK`. Confirms HTTPS (TCP 443) works end-to-end through VXLAN tunnel 1 (VNI 100).

### Test 2 — HTTPS through VXLAN tunnel 2

SSH to **Router-2** via Bastion:
```bash
curl -sk -o /dev/null -w 'Status: %{http_code}, Time: %{time_total}s\n' https://172.16.0.6/health
curl -sk https://172.16.0.6/health
```
**Expected:** `Status: 200`, response `OK`. Confirms HTTPS through VXLAN tunnel 2 (VNI 200).

### Test 3 — End-to-end HTTPS: Test VM → ILB → Router → VXLAN → NVA

RDP to the **Test VM** via Bastion. Open PowerShell:
```powershell
# Bypass self-signed cert validation
[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
$web = New-Object Net.WebClient
$web.DownloadString('https://172.16.0.2/health')
```
**Expected:** Returns `OK`. This proves the complete HTTPS path:

```
Test VM (10.100.0.4)
    → UDR (0.0.0.0/0 → 10.100.0.68)
    → ILB (HA Ports, hash-based distribution)
    → Router-1 (SNAT + VXLAN encap)
    → VNet peering (private IP underlay)
    → Linux NVA nginx (VXLAN decap → TLS termination at 172.16.0.2:443)
```

### Test 4 — Verify traffic traverses VXLAN (packet capture)

This is the key proof that HTTPS is encapsulated inside VXLAN, not routed via Azure's SDN.

SSH to **Router-1** via Bastion:
```bash
# Start tcpdump on eth0 (underlay) while curling NVA over the overlay
sudo bash -c 'timeout 8 tcpdump -i eth0 udp port 4789 -nn -c 10 > /tmp/cap.txt 2>&1 &
sleep 1; curl -sk https://172.16.0.2/health; sleep 5; cat /tmp/cap.txt'
```

**Expected output** (each HTTPS packet wrapped in VXLAN):
```
IP 10.100.0.69.xxxxx > 10.200.0.4.4789: VXLAN, flags [I] (0x08), vni 100
IP 172.16.0.1.xxxxx > 172.16.0.2.443: Flags [S], ...     # TLS SYN
IP 10.200.0.4.xxxxx > 10.100.0.69.4789: VXLAN, flags [I] (0x08), vni 100
IP 172.16.0.2.443 > 172.16.0.1.xxxxx: Flags [S.], ...    # TLS SYN-ACK
```

The two layers visible in each line prove:
- **Outer header:** `10.100.0.69 → 10.200.0.4` on UDP 4789 (VXLAN underlay over VNet peering)
- **Inner header:** `172.16.0.1 → 172.16.0.2` on TCP 443 (HTTPS inside the tunnel)

### Test 5 — Verify via NVA access log

SSH to **Linux NVA** via Bastion:
```bash
tail -10 /var/log/nginx/access.log
```

**Expected:** Log entries showing requests from overlay IPs:
```
172.16.0.1 - - [timestamp] "GET /health HTTP/1.1" 200 2 "-" "curl/7.81.0"
172.16.0.5 - - [timestamp] "GET /health HTTP/1.1" 200 2 "-" "curl/7.81.0"
```

Source `172.16.0.1` = Router-1 (after SNAT), `172.16.0.5` = Router-2. This confirms HTTPS arrived through the VXLAN overlay, not via the Azure underlay.

### Test 6 — Verify VXLAN interface counters

```bash
ip -s link show vxlan1    # RX/TX byte and packet counts
ip -s link show vxlan2    # Should show non-zero counters after tests
```

### Test 7 — M365 traffic path (force-tunnel behavior)

The UDR sends `0.0.0.0/0` to the ILB, meaning **all traffic** from the Microsoft 365 subnet — including M365 — is force-tunneled through the routers. This matches the Zscaler ZIA deployment model.

From the **Test VM** via Bastion:
```
tracert -h 5 -d outlook.office365.com
```

**Expected:** First hop is `10.100.0.69` or `10.100.0.70` (a router via ILB), confirming M365 traffic is also routed through the tunnel path.

> **Split-tunnel note:** In production, Zscaler uses PAC files or explicit proxy configuration to split M365 Optimize/Allow traffic direct while routing general web through ZIA. This lab demonstrates the force-tunnel baseline. To implement split-tunnel, add specific routes for [M365 endpoints](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges) to the UDR with next-hop `Internet`.

### Test summary

| # | Test | From | Command | Expected |
|---|---|---|---|---|
| 1 | HTTPS tunnel 1 | Router-1 | `curl -sk https://172.16.0.2/health` | `OK` (HTTP 200) |
| 2 | HTTPS tunnel 2 | Router-2 | `curl -sk https://172.16.0.6/health` | `OK` (HTTP 200) |
| 3 | HTTPS end-to-end | Test VM | PowerShell WebClient to `172.16.0.2` | `OK` (HTTP 200) |
| 4 | Packet capture | Router-1 | `tcpdump -i eth0 udp port 4789` | VXLAN-encapsulated TCP 443 |
| 5 | NVA access log | NVA | `tail /var/log/nginx/access.log` | Requests from `172.16.0.1`/`.5` |
| 6 | Interface counters | NVA | `ip -s link show vxlan1` | Non-zero RX/TX |
| 7 | M365 force-tunnel | Test VM | `tracert outlook.office365.com` | First hop = router IP |

### Running tests via Azure CLI (without Bastion)

```bash
# HTTPS from Router-1 through VXLAN
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-1 \
  --command-id RunShellScript \
  --scripts "curl -sk https://172.16.0.2/health"

# HTTPS from Router-2 through VXLAN
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-2 \
  --command-id RunShellScript \
  --scripts "curl -sk https://172.16.0.6/health"

# Packet capture proof (VXLAN encapsulation visible)
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name router-1 \
  --command-id RunShellScript \
  --scripts "bash -c 'timeout 8 tcpdump -i eth0 udp port 4789 -nn -c 10 \
    > /tmp/cap.txt 2>&1 & sleep 1; curl -sk https://172.16.0.2/health; \
    sleep 5; cat /tmp/cap.txt'"

# NVA access log verification
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name linux-nva \
  --command-id RunShellScript \
  --scripts "tail -10 /var/log/nginx/access.log"

# End-to-end HTTPS from Test VM (Windows)
az vm run-command invoke \
  --resource-group rg-w365-zscaler-lab \
  --name vm-w365-test \
  --command-id RunPowerShellScript \
  --scripts "[Net.ServicePointManager]::ServerCertificateValidationCallback = {\$true}; \
    (New-Object Net.WebClient).DownloadString('https://172.16.0.2/health')"
```

---

## Architecture Reference

This lab implements the architecture defined in:
**[Microsoft 365 + Zscaler Networking Architecture & POC](https://github.com/colinweiner111/azure-w365-zscaler-networking-poc)**

---

## Production Reference: GRE Tunnel & Route-Map Configuration

This lab uses Linux routers with VXLAN because Azure blocks GRE (protocol 47) between VMs. Below are the production NVA configs this lab simulates.

### GRE Tunnel Configuration

```
! --- GRE Tunnel to Zscaler ZEN (primary) ---
interface Tunnel0
 description GRE to Zscaler ZEN - Primary
 ip address 172.16.0.1 255.255.255.252
 ip mtu 1400
 ip tcp adjust-mss 1360
 tunnel source GigabitEthernet1
 tunnel destination <ZSCALER_ZEN_PRIMARY_IP>
 tunnel mode gre ip
 keepalive 10 3
!
! --- GRE Tunnel to Zscaler ZEN (secondary) ---
interface Tunnel1
 description GRE to Zscaler ZEN - Secondary
 ip address 172.16.0.5 255.255.255.252
 ip mtu 1400
 ip tcp adjust-mss 1360
 tunnel source GigabitEthernet1
 tunnel destination <ZSCALER_ZEN_SECONDARY_IP>
 tunnel mode gre ip
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
! --- Route-map: M365 Optimize → direct internet, all else → GRE ---
route-map TRAFFIC_STEERING permit 10
 description M365 Optimize - direct internet breakout
 match ip address M365_OPTIMIZE_ACL
 set interface GigabitEthernet1
!
route-map TRAFFIC_STEERING permit 20
 description All other internet - GRE to Zscaler
 set interface Tunnel0
!
! --- Apply to inbound interface ---
interface GigabitEthernet1
 ip policy route-map TRAFFIC_STEERING
```

### Multi-NVA Scaling

```
  NVA-1 (PIP-1) ──── GRE Tunnel A ────┐
  NVA-2 (PIP-2) ──── GRE Tunnel B ────┼──── Zscaler ZEN
  NVA-3 (PIP-3) ──── GRE Tunnel C ────┤
  NVA-4 (PIP-4) ──── GRE Tunnel D ────┘
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
| Linux router (Ubuntu) + VXLAN | NVA appliance + GRE tunnel |
| iptables MASQUERADE | `ip nat inside source` (PAT) |
| Linux NVA (nginx) | Zscaler ZEN node |
| iproute2 VXLAN config | `interface Tunnel` |
| UDR `0.0.0.0/0` → ILB | Same |
| All traffic force-tunneled | Route-map splits M365 direct vs. GRE |

---

## Clean Up

```bash
az group delete --name rg-w365-zscaler-lab --yes --no-wait
```
