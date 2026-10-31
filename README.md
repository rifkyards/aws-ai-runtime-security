# Prisma AIRS + EKS (Jakarta): Firewall, GWLB, PAN CNI, dan IP-Tag Collector

Lab PoC di `ap-southeast-3`: satu VPC berisi cluster EKS, firewall **Prisma AIRS AI Runtime** di subnet samping, **GWLB + GWLB endpoint**, **PAN CNI** (CNI chaining) yang membelokkan trafik pod ke firewall, dan **IP-tag collector** (Context Collector Agent) yang mengirim tag Kubernetes ke firewall untuk Dynamic Address Group.

> **Credentials tidak ada di repo.** `terraform.tfvars`, `tag-collector.auto.tfvars`, state Terraform, dan file kredensial yang dibuat saat mengikuti README (`cred*.json`, `aws-cred*`) di-ignore oleh `.gitignore`. Mulai dari file `*.example`.
>
> **Redaksi.** Nilai sensitif atau spesifik tenant ditulis sebagai placeholder: `<ACCOUNT_ID>`, `<TSG_ID>`, `<DISCOVERY_ACCOUNT_ID>`, `<OTID>`, `<EKS_ENDPOINT_HOST>`, `<FW_MGMT_EIP>`, `<TC_MGMT_EIP>`, `<NAT_EIP>`, `<VPCE_ID>`, `<ADMIN_IP>`. Auth code, PIN, token, dan isi `*.tfvars` tidak pernah ditulis di sini. Isi nilai aslinya di `terraform.tfvars` / `tag-collector.auto.tfvars` (jangan di-commit ke repo publik).

![HLD](docs/airs-eks-gwlb-tc.png)

---

## Daftar isi

1. [Arsitektur](#1-arsitektur)
2. [Isi folder](#2-isi-folder)
3. [Prasyarat](#3-prasyarat)
4. [Discovery oleh PANW (onboarding cloud account)](#4-discovery-oleh-panw-onboarding-cloud-account)
5. [Infrastruktur (Terraform)](#5-infrastruktur-terraform)
6. [Firewall Prisma AIRS](#6-firewall-prisma-airs)
7. [PAN CNI dan uji trafik](#7-pan-cni-dan-uji-trafik)
8. [IP-Tag Collector](#8-ip-tag-collector)
9. [Dynamic Address Group (DAG)](#9-dynamic-address-group-dag)
10. [Temuan dan batasan](#10-temuan-dan-batasan)
11. [Troubleshooting](#11-troubleshooting)
12. [Hapus / rollback](#12-hapus--rollback)
13. [Referensi](#13-referensi)

---

## 1. Arsitektur

```
VPC 10.20.0.0/16 (ap-southeast-3)
│
├─ private-a 10.20.0.0/20 (AZ-a) ┐ Node EKS (managed node group)
├─ private-b 10.20.16.0/20 (AZ-b)┘   Pod ─► AWS VPC CNI ─► pan-cni (chained, DaemonSet)
│                                                      │ ke pan-ngfw-svc = GWLBE
│                                                      ▼
├─ gwlbe 10.20.252.0/28 (AZ-a)     GWLB endpoint 10.20.252.4
│                                                      │
├─ inspection 10.20.250.0/28 (AZ-a) GWLB ─GENEVE 6081─► FW eth1 = ethernet1/1 10.20.250.10
│
├─ mgmt 10.20.251.0/28 (AZ-a)      FW eth0 10.20.251.10 + EIP ─► SCM
│                                   Tag collector 10.20.251.11 + EIP
│                                     ├─ HTTPS 443 ─► EKS API (private endpoint, token SA)
│                                     └─◄ 5007 ── FW eth0 menarik IP-tag (User-ID redistribution)
│
└─ public-a/b 10.20.100.0/24, 10.20.101.0/24 (NAT GW, IGW)
```

| Komponen | Subnet / IP | Fungsi |
|---|---|---|
| Node EKS | private-a / private-b | Menjalankan pod. PAN CNI membelokkan trafik pod dari namespace ber-annotation |
| GWLB endpoint | `10.20.252.4` | Tujuan `pan-ngfw-svc` (endpoint PAN CNI) |
| GWLB | inspection | Meneruskan ke firewall via GENEVE 6081, health check TCP 443 |
| Firewall eth1 (`ethernet1/1`) | `10.20.250.10` | Interface data, terminasi GENEVE |
| Firewall eth0 | `10.20.251.10` + `<FW_MGMT_EIP>` | Management, koneksi ke SCM |
| Tag collector | `10.20.251.11` + `<TC_MGMT_EIP>` | Membaca EKS, membuat IP-tag, membagikannya ke firewall |

---

## 2. Isi folder

| File | Isi |
|---|---|
| `versions.tf`, `variables.tf`, `outputs.tf` | Provider, variabel, output |
| `network.tf` | VPC, subnet node/public, NAT GW, subnet inspection + mgmt |
| `eks.tf` | Cluster EKS, managed node group, rule SG node (pod-to-pod semua port, dari firewall) |
| `firewall.tf` | SG, ENI eth0/eth1, EIP mgmt, EC2 firewall + bootstrap |
| `gwlb.tf` | Subnet GWLBE, GWLB, target group GENEVE, endpoint service, GWLB endpoint |
| `pan-cni.tf` | Helm release PAN CNI (`endpoints` = IP GWLBE) |
| `tag-collector.tf` | EC2 tag collector, IAM (dari template SCM), EKS access entry, SG 443 ke EKS API dan 5007 dari firewall |
| `tag-collector.auto.tfvars.example` | Contoh `tc_bootstrap_options` (salin ke `tag-collector.auto.tfvars`, yang di-ignore git) |
| `gwlb-test.tf` | Opsional: EC2 uji trafik GWLB normal (route table) |
| `scp-helper.tf` | Opsional: EC2 sementara sumber `scp import` untuk tag collector |
| `charts/ai-runtime-security/` | Chart resmi `PaloAltoNetworks/prisma-airs-helm` (MIT) |
| `k8s/airs-demo-all.yaml` | Demo: ns `airs-demo` + `airs-demo-b` (ber-annotation), web :80, web2 :81, client |
| `k8s/test.sh` | Uji 6 skenario, ringkasan PASS/FAIL |
| `k8s/tag-collector-serviceaccount.yaml` | ServiceAccount + RBAC untuk tag collector (versi PANW + izin tambahan) |
| `terraform.tfvars.example` | Contoh variabel utama (salin ke `terraform.tfvars`, yang di-ignore git) |
| `.gitignore` | Mengecualikan state, tfvars asli, kredensial (`cred*.json`, `aws-cred*`, `*.pem`) |
| `docs/airs-eks-gwlb-tc.png` | Diagram HLD |

---

## 3. Prasyarat

- [ ] Region Jakarta (`ap-southeast-3`) sudah di-enable di akun AWS
- [ ] Subscribe image Prisma AIRS di AWS Marketplace (`ami-0ac089e9d177c663d`, PAN-OS 12.2.3)
- [ ] EC2 key pair di `ap-southeast-3`
- [ ] Auth code (deployment profile) dan Device Certificate PIN ID + value
- [ ] Folder di Strata Cloud Manager (contoh: `AIRS-EKS-Jakarta`)
- [ ] Cloud account AWS sudah di-onboard di SCM (lihat bagian 4)
- [ ] Terraform ≥ 1.5, AWS CLI v2, kubectl, helm
- [ ] IP publik Anda untuk `admin_cidrs` (`<ADMIN_IP>/32`)

---

## 4. Discovery oleh PANW (onboarding cloud account)

### 4.1 Apa yang terjadi

Saat account AWS di-onboard ke SCM (Prisma AIRS → cloud discovery), PANW membuat IAM role di account Anda dan memakainya dari cloud PANW untuk menemukan resource, termasuk cluster EKS.

Teramati di CloudTrail:

| Role | Sesi | Panggilan | Frekuensi |
|---|---|---|---|
| `arn:aws:iam::<ACCOUNT_ID>:role/airs-aws-logs_ip_tag` | `cloud-ip-tag-k8s` | `eks:ListClusters`, `eks:DescribeCluster` | ± tiap 15 menit |

Access entry EKS yang ada untuk role onboarding: `role/airs-aws-logs`. Role `airs-aws-logs_ip_tag` **tidak** punya access entry.

### 4.2 Cek sendiri

```bash
aws cloudtrail lookup-events --region ap-southeast-3 \
  --lookup-attributes AttributeKey=Username,AttributeValue=cloud-ip-tag-k8s --max-results 20 \
  --query 'Events[].[EventTime,EventName]' --output table

aws eks list-access-entries --cluster-name airs-eks --region ap-southeast-3 --output table
```

> Panggilan ke Kubernetes API (list pod, dsb.) tidak tercatat di CloudTrail. Untuk melihatnya, aktifkan EKS audit log.

### 4.3 Template "Context Collector Agent" dari SCM

SCM men-generate Terraform tag collector (`<alias>_AGENT_AWS_AP-SOUTHEAST-3_<id>`, `firewallType: Context Collector Agent`) berisi tiga project: `tgw_project`, `tc_project`, `tc_iam_project`. Project ini **tidak** dipakai langsung. Bagian yang relevan sudah diadaptasi ke `tag-collector.tf` (lihat bagian 8).

---

## 5. Infrastruktur (Terraform)

### 5.1 Isi variabel

```bash
cp terraform.tfvars.example terraform.tfvars
```

Isi `admin_cidrs`, `ssh_key_name`, dan `bootstrap_options` (`dgname`, `authcodes`, PIN). File ini di-ignore git.

| Key `bootstrap_options` | Nilai | Catatan |
|---|---|---|
| `panorama-server` | `cloud` | Dikelola SCM |
| `dgname` | `AIRS-EKS-Jakarta` | Folder SCM |
| `tplname` | `otid:<OTID>` | Dari SCM |
| `plugin-op-commands` | `advance-routing:enable` | Jangan `aws-gwlb-overlay-routing` (desain satu kaki) |
| `mgmt-interface-swap` | `disable` | eth0 = mgmt, eth1 = ethernet1/1 |
| `authcodes`, `vm-series-auto-registration-pin-id`, `-pin-value` | wajib | Dicek precondition |

Variabel penting lain: `enable_gwlb = true` (default), `eks_public_access_cidrs`, `install_pan_cni`, `cluster_id`.

### 5.2 Deploy

```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan          # ±20–25 menit
```

```bash
$(terraform output -raw kubeconfig_command)
```

```bash
terraform output pan_cni_endpoint      # harus IP GWLBE (10.20.252.4)
terraform output fw_mgmt_public_ip
```

---

## 6. Firewall Prisma AIRS

### 6.1 Tunggu firewall muncul di SCM

10–20 menit setelah instance jalan. Cek di SCM (Cloud Managed Devices) atau via SSH:

```bash
ssh -i <key>.pem admin@<FW_MGMT_EIP>
```

```
show system bootstrap status
show panorama-status
```

### 6.2 Interface, zone, routing (SCM, folder `AIRS-EKS-Jakarta`)

Konfigurasi yang terbukti jalan (single-arm GWLB):

| Objek | Nilai |
|---|---|
| `ethernet1/1` | Layer3, **DHCP client** (dapat `10.20.250.10`), zone `LAN`, logical router `default` |
| Interface management profile | `healthcheck` dengan **HTTPS** (untuk health check GWLB TCP 443) |
| Logical router | `default` (advanced routing), default route dari DHCP |
| Security policy | Tidak diubah untuk PoC. Trafik pod-to-pod cocok `intrazone-default` (allow) atau rule uji |

Push Config, lalu cek:

```
show interface ethernet1/1
```

### 6.3 Plugin GWLB

```
request plugins vm_series aws gwlb inspect enable yes
```

```
request plugins vm_series aws gwlb overlay-routing enable no
```

```
show plugins vm_series aws gwlb
```

Harus `GWLB enabled: True`, `Overlay Routing: False`.

> Overlay routing bisa menyala lagi setelah push dari SCM kalau opsi **Enable Overlay Routing** tercentang di deployment workflow SCM. Overlay hanya untuk desain dua kaki (egress lewat `eth1/2`). Cek lagi setiap selesai push.

### 6.4 Subinterface per GWLB endpoint (eksperimen)

Langkah yang dicoba:

1. Subinterface `ethernet1/1.10`: tag 10, zone `eks-sub` (contoh), LR `default`, **IPv4 static dummy** `100.64.10.1/30` (DHCP tidak dapat IP karena AWS tidak melayani VLAN).
2. Asosiasi endpoint (pakai ID endpoint `vpce-...`, bukan `vpce-svc-...`):

```
request plugins vm_series aws gwlb associate vpc-endpoint <VPCE_ID> interface ethernet1/1.10
```

```
show plugins vm_series aws gwlb
```

Hasil:

| Sumber trafik lewat GWLBE yang sama | Zone di firewall |
|---|---|
| EC2 biasa, dirutekan ke GWLBE lewat route table (`gwlb-test.tf`) | **`eks-sub`** (`ethernet1/1.10`) |
| Pod EKS lewat PAN CNI (menembak IP GWLBE langsung) | **`LAN`** (`ethernet1/1`) |

Kesimpulan: asosiasi vpce → subinterface **bekerja untuk trafik GWLB biasa, tapi tidak diterapkan ke trafik PAN CNI** (counter `flow_rcv_geneve_fast_decap` / `flow_fwaas_*`, tidak ada counter vpce). Segmentasi trafik Kubernetes dilakukan dengan DAG (bagian 9). Sudah dieskalasi ke PANW.

Untuk menghapus subinterface: disassociate dulu, lepas `$LAN.10` dari Virtual Router, Logical Router, dan zone, baru hapus interface-nya, lalu push.

```
request plugins vm_series aws gwlb disassociate vpc-endpoint <VPCE_ID> interface ethernet1/1.10
```

---

## 7. PAN CNI dan uji trafik

### 7.1 Validasi PAN CNI

```bash
kubectl get pods -n kube-system -l k8s-app=pan-cni -o wide
```

```bash
kubectl get endpointslices -n kube-system | grep pan
```

```bash
helm get values ai-runtime-security -n kube-system
```

`endpoints` harus `10.20.252.4` (GWLBE). Value chart diatur di `pan-cni.tf`; jangan edit `charts/ai-runtime-security/values.yaml`. Kalau memasang manual dengan Helm, set `install_pan_cni = false` supaya tidak bentrok dengan Terraform:

```bash
helm upgrade --install ai-runtime-security ./charts/ai-runtime-security -n kube-system \
  --set endpoints=10.20.252.4 --set fwtrustcidr=10.20.250.0/28 --set clusterid=1 --set deployTo=eks
```

### 7.2 Deploy demo

```bash
kubectl apply -f k8s/airs-demo-all.yaml
```

```bash
kubectl get pods -n airs-demo -o wide
```

```bash
kubectl get pods -n airs-demo-b -o wide
```

### 7.3 Uji

```bash
bash k8s/test.sh
```

Hasil yang diharapkan: `Ringkasan: 15 PASS, 0 FAIL` (namespace sama dan beda, ClusterIP / headless / IP pod, termasuk lintas node).

Bukti trafik lewat firewall:

- Traffic log: `( port.dst eq 80 )` untuk web, `( port.dst eq 81 )` untuk web2
- CLI firewall: `show session all filter destination-port 81`
- Trafik GENEVE: `show counter global filter delta yes` (`flow_rcv_geneve_fast_decap` = `flow_tx_geneve_encap`)

---

## 8. IP-Tag Collector

Tag collector adalah VM dengan **AMI yang sama dengan firewall**, berjalan dalam mode tag collector (`plugin-op-commands=tag_collector_mode_flag:enable`, `tplname=otid:<OTID>;label:CtxColl`). Ia membaca pod/namespace/service dari EKS dan membagikan IP-tag ke firewall lewat User-ID redistribution (port 5007).

### 8.1 Adaptasi dari template SCM

| Template SCM | Di project ini |
|---|---|
| `tgw_project` (Transit Gateway) | **Tidak dipakai**. Tag collector satu VPC dengan EKS |
| `tc_project`: VPC baru `10.20.0.0/16`, IP `10.20.0.14` | Subnet mgmt yang ada, `10.20.251.11` + EIP (VPC template akan overlap) |
| `tc_project`: SG 443/22 dari `0.0.0.0/0` | Dibatasi ke `admin_cidrs`; tambah 5007 dari SG mgmt firewall |
| `tc_iam_project`: `private_cluster_role` + `k8s-policy` | Sama (nama dipertahankan), plus EKS access entry `AmazonEKSViewPolicy` |
| (tidak ada) | Rule SG cluster EKS: 443 dari tag collector |

### 8.2 Nilai bootstrap

```bash
cp tag-collector.auto.tfvars.example tag-collector.auto.tfvars
```

Isi `tc_bootstrap_options` dan `tc_instance_role_name` dari template SCM (`tc_project/terraform.tfvars` dan `tc_iam_project/terraform.tfvars`). File ini di-ignore git.

**Jangan diganti** (spesifik tenant): `tsg-id` (`<TSG_ID>`), `tplname`, `dgname`, `discovery-account-id` (`<DISCOVERY_ACCOUNT_ID>`), `cluster-account-ids` (memetakan ke `<ACCOUNT_ID>`), `ip-tag-svc-endpoint`, `cdl-region`.

**Wajib diganti** (template mengisinya dengan placeholder huruf berulang):

- `authcodes`
- `vm-series-auto-registration-pin-id` (UUID 36 karakter)
- `vm-series-auto-registration-pin-value`

`vm-auth-key` boleh kosong. `tplname` mengandung `;`, jadi user_data tag collector dipisah baris baru.

### 8.3 Deploy

```bash
aws sts get-caller-identity
```

```bash
terraform plan  -var enable_tag_collector=true
```

```bash
terraform apply -var enable_tag_collector=true
```

```bash
terraform output tag_collector_mgmt_public_ip
```

Tunggu 10–15 menit, lalu:

```bash
ssh -i <key>.pem admin@<TC_MGMT_EIP>
```

Kalau nilai bootstrap salah, perbaiki tfvars lalu buat ulang VM:

```bash
terraform apply -var enable_tag_collector=true -replace='aws_instance.tc[0]'
```

### 8.4 ServiceAccount dan kredensial

Kredensial cluster **harus token ServiceAccount Kubernetes** (lihat 10.2).

```bash
kubectl apply -f k8s/tag-collector-serviceaccount.yaml
```

```bash
kubectl auth can-i watch nodes --as=system:serviceaccount:kube-system:pan-plugin-user
```

```bash
kubectl -n kube-system get secret pan-plugin-user-secret -o json > cred.json
gzip -c cred.json | base64 | tr -d '\n' | pbcopy
rm cred.json
```

Manifest ini adalah `charts/ai-runtime-security/plugin-serviceaccount.yaml` dari PANW (tidak dipasang oleh Helm karena di luar `templates/`) ditambah izin read-only:

| Izin tambahan | Gejala kalau tidak ada |
|---|---|
| `serviceaccounts`, `namespaces`: get/list/watch | Polling `Failed to get service accounts. Invalid permissions.` |
| `nodes`, `endpoints`: get/watch | Watching tertahan `Initializing`, counter `node_cred_err` / `endpoint_cred_err` naik |

Hostname endpoint EKS (tanpa `https://`):

```bash
aws eks describe-cluster --name airs-eks --region ap-southeast-3 \
  --query cluster.endpoint --output text | sed 's#https://##'
```

### 8.5 Daftarkan cluster (CLI tag collector)

Satu atribut per baris (versi satu baris dari dokumentasi menghasilkan `Invalid syntax`):

```
configure
set deviceconfig plugins kubernetes setup cluster-credentials airs-eks api-server-address <EKS_ENDPOINT_HOST>
set deviceconfig plugins kubernetes setup cluster-credentials airs-eks cluster-type EKS
set deviceconfig plugins kubernetes setup cluster-credentials airs-eks cluster-credential-file service-account-cred <BASE64>
set deviceconfig plugins kubernetes setup cluster-credentials airs-eks labels no-labels
set deviceconfig plugins kubernetes monitoring-definition airs-eks-mon cluster-credentials airs-eks
set deviceconfig plugins kubernetes monitoring-definition airs-eks-mon enable yes
commit
exit
```

```
show plugins kubernetes status
```

```
show plugins kubernetes counters
```

Target: Polling dan Watching `Connected`, `*_cred_err` tidak terus naik.

Paksa polling ulang (setelah RBAC diperbaiki):

```
configure
set deviceconfig plugins kubernetes monitoring-definition airs-eks-mon enable no
commit
set deviceconfig plugins kubernetes monitoring-definition airs-eks-mon enable yes
commit
```

Tes token dari laptop (`200` boleh, `403` RBAC kurang, `401` token ditolak):

```bash
EP=$(aws eks describe-cluster --name airs-eks --region ap-southeast-3 --query cluster.endpoint --output text)
TOKEN=$(kubectl -n kube-system get secret pan-plugin-user-secret -o jsonpath='{.data.token}' | base64 -d)
for p in /api/v1/pods /api/v1/serviceaccounts /api/v1/namespaces; do
  echo "$p -> $(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" $EP$p)"
done
unset TOKEN
```

> Kalau cluster dibuat ulang, hostname dan token berubah: apply ulang ServiceAccount, buat ulang `cred.json`, dan update kredensial di tag collector.

### 8.6 Redistribution ke firewall (SCM)

**Identity Services → Identity Redistribution → Add Agent**, scope `AIRS-EKS-Jakarta`:

| Field | Isi |
|---|---|
| Name | `airs-eks-tag-collector` |
| Enabled | ya |
| Host | `10.20.251.11` |
| Port | `5007` |
| Data Type | **IP to Tag** |
| Collector Name / Pre-Shared Key | kosong (PoC) |

Push Config. Cek di tag collector:

```
show redistribution service client all
```

Hasil yang benar: `10.20.251.10/<port>  ...  T` (firewall sebagai client IP-tag).

Kalau kosong: cek `show user user-id-agent state all` di firewall, dan aktifkan layanan User-ID di mgmt tag collector (`set deviceconfig system service disable-userid-service no`, cek nama opsi dengan `?`).

### 8.7 Verifikasi tag di firewall

```
show object registered-ip all
```

IP pod harus muncul dengan tag `k8s.*`.

---

## 9. Dynamic Address Group (DAG)

SCM → **Objects → Address → Address Groups → Add**, scope `AIRS-EKS-Jakarta`:

1. Name `dag-ns-airs-demo`, Type **Dynamic**
2. **Edit Match Criteria → tab CIE**, cari `airs-demo`, pilih tag namespace (bukan label `k8s.app.*`)
3. Ulangi untuk `dag-ns-airs-demo-b`
4. Push Config

```
show object dynamic-address-group all
```

DAG hanya object. Pemakaian di security rule (misalnya `airs-demo → airs-demo-b` port 81 allow) adalah perubahan policy terpisah. Session lewat ClusterIP juga dicatat ke IP Service, jadi sertakan tag Service (`k8s.svc*`) bila perlu.

---

## 10. Temuan dan batasan

### 10.1 Subinterface/zone untuk trafik PAN CNI

Asosiasi GWLB endpoint → subinterface tidak berlaku untuk trafik PAN CNI (lihat 6.4). Semua trafik pod masuk zone parent (`LAN`). Segmentasi dilakukan per tag (DAG), bukan per zone.

### 10.2 IAM role untuk tag collector

Yang sudah dicoba dan **ditolak** oleh plugin Kubernetes tag collector (PAN-OS 12.2.3):

| Kredensial | Hasil |
|---|---|
| File AWS `role_arn` + `credential_source=Ec2InstanceMetadata` (base64) | `File should be json containing Token and CA cert.` |
| File AWS berisi kredensial STS dari `private_cluster_role` | Ditolak, pesan sama |
| JSON berbentuk secret berisi token EKS hasil IAM (`aws eks get-token`) | Ditolak, pesan sama |

CLI hanya menawarkan `service-account-cred` dan `service-account-json`, dan `scp import` hanya punya tipe `k8s-service-account`. `private_cluster_role` tidak pernah di-assume (CloudTrail). Jadi **token ServiceAccount adalah satu-satunya jalur yang jalan**. Pertanyaan pemakaian `private_cluster_role` sudah diajukan ke PANW.

### 10.3 Lain-lain

- Firewall tunggal di AZ-a: node AZ-b melintas AZ (biaya dan latensi). Untuk HA, tambah firewall per AZ di target group GWLB.
- Fargate tidak tercakup (PAN CNI berupa DaemonSet).
- Konfigurasi DLP dari SCM (`PII Basic Block All Data` → `DLP App Exclusion`) memunculkan error validasi di tag collector. Perbaiki di SCM bila commit tag collector gagal.

---

## 11. Troubleshooting

| Gejala | Cek |
|---|---|
| `plan` gagal di `data.aws_ami.fw` | AMI tidak ada di region / Marketplace belum subscribe |
| Firewall tidak muncul di SCM | `dgname`, auth code/PIN, akses internet mgmt (EIP, route ke IGW) |
| Helm/kubectl timeout ke EKS API | IP publik Anda tidak ada di `eks_public_access_cidrs` |
| Pod lintas node gagal | Rule SG node `ingress_self_all` |
| Target group GWLB unhealthy | Mgmt profile HTTPS belum terpasang di `ethernet1/1` |
| Trafik ke GWLB tapi tidak ada balasan | `request plugins vm_series aws gwlb inspect enable yes` |
| Overlay routing `True` lagi setelah push | Opsi overlay di SCM, matikan lagi (6.3) |
| `associate ... should be less than or equal to 22 characters` | Pakai ID endpoint `vpce-...`, bukan `vpce-svc-...` |
| Hapus subinterface ditolak `references from ... virtual-router` | Lepas dari Virtual Router, Logical Router, zone dulu |
| Tag collector `Invalid permissions` | RBAC ServiceAccount (8.4), tes dengan `curl` |
| Watching `Initializing` terus | Izin `watch` nodes/endpoints, cek `show plugins kubernetes counters` |
| Redistribution client kosong | SG 5007, agent di SCM sudah di-push, layanan User-ID tag collector |
| Commit tag collector gagal setelah tes | Hapus entri candidate yang gagal (`delete ...`) lalu commit |

---

## 12. Hapus / rollback

Matikan inspeksi satu namespace:

```bash
kubectl annotate namespace airs-demo paloaltonetworks.com/firewall-
kubectl rollout restart deployment -n airs-demo
```

Hapus tag collector:

```bash
kubectl delete -f k8s/tag-collector-serviceaccount.yaml
terraform apply
```

Hapus semua (workload dulu, baru infrastruktur):

```bash
kubectl delete -f k8s/airs-demo-all.yaml
terraform destroy
```

Setelah destroy, deactivate lisensi firewall dan tag collector di SCM/CSP.

---

## 13. Referensi

- Basics of Container Security (CNI chaining): https://docs.paloaltonetworks.com/prisma-airs/ai-runtime-security/airs-vm-firewall/microperimeter/cni-chaining-concept-overview
- Secure VMs and Kubernetes Clusters in AWS (SCM): https://docs.paloaltonetworks.com/prisma-airs/ai-inventory/scm-config-protect-vms-k8s-aws
- Deploy Prisma AIRS Network Intercept in AWS (overlay routing): https://docs.paloaltonetworks.com/prisma-airs/ai-runtime-security/airs-managed-saas-firewall/add-ai-instance-for-aws
- Associate a VPC Endpoint with a VM-Series Interface: https://docs.paloaltonetworks.com/vm-series/deployment/public-cloud/set-up-the-vm-series-firewall-on-aws/vm-series-integration-with-gateway-load-balancer/associate-a-vpc-endpoint-with-a-vm-series-interface
- Deploy a Tag Collector Agent on AWS: https://docs.paloaltonetworks.com/prisma-airs/ai-inventory/cloud-resource-discovery/private-cluster-discovery/deploy-a-tag-collector-agent-to-secure-private-clusters
- Harvest IP-Tags from Kubernetes Clusters: https://docs.paloaltonetworks.com/prisma-airs/getting-started/use-case-harvesting-ip-tags-k8s-clusters
- Service account untuk cluster authentication (CN-Series): https://docs.paloaltonetworks.com/cn-series/getting-started/cn-series-deployment-prereq/create-service-accounts-for-cluster-authentication-with-cn-series
- VM-Series bootstrap parameters: https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/create-bootstrap-configuration-files
- Helm chart: https://github.com/PaloAltoNetworks/prisma-airs-helm
