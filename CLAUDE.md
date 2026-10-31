# CLAUDE.md

Konteks untuk sesi Claude yang bekerja di repo ini. Baca ini dulu, lalu `README.md` untuk detail langkah.

## Tentang repo

Lab PoC **Prisma AIRS AI Runtime Firewall + EKS** di AWS `ap-southeast-3` (Jakarta), dikelola **Strata Cloud Manager (SCM)**, folder SCM `AIRS-EKS-Jakarta`.

- Satu VPC `10.20.0.0/16`: node EKS (private-a/b), firewall single-arm di subnet inspection, **GWLB + GWLB endpoint** (`10.20.252.4`), mgmt subnet `10.20.251.0/28` berisi eth0 firewall (`.10`) dan **IP-tag collector** (`.11`).
- **PAN CNI** (chart `charts/ai-runtime-security`, di-vendor dari `PaloAltoNetworks/prisma-airs-helm`) membelokkan trafik pod dari namespace ber-annotation `paloaltonetworks.com/firewall=pan-fw` ke GWLBE.
- **Tag collector** (SCM: "Context Collector Agent") membaca EKS dengan token ServiceAccount dan membagikan IP-tag ke firewall lewat User-ID redistribution port 5007, untuk Dynamic Address Group.
- Diagram: `docs/airs-eks-gwlb-tc.png`.

## Aturan kerja (wajib)

1. **Bahasa:** jawab dalam Bahasa Indonesia santai-profesional. Ringkas. Pakai paragraf atau TL;DR kalau diminta ringkasan.
2. **Verify before exec:** cek dulu (baca file, `terraform plan`, `?` di CLI PAN-OS) sebelum menyarankan perintah yang mengubah sesuatu. Kalau sintaks CLI PAN-OS tidak pasti, katakan dan suruh cek dengan `?`.
3. **Jangan ubah security policy** firewall kecuali diminta eksplisit. DAG boleh dibuat; memakainya di rule adalah keputusan user.
4. **Jangan pernah menampilkan secret:** auth code, PIN ID/value, `vm-auth-key`, token ServiceAccount, kredensial STS, isi `*.tfvars`, isi `cred*.json`. Kalau perlu memeriksa, cek panjang/format saja tanpa mencetak nilai.
5. **Jangan commit credentials.** `.gitignore` sudah mengecualikan `terraform.tfvars`, `*.auto.tfvars`, `*.tfstate*`, `.terraform/`, `cred*.json`, `aws-cred*`, `trust-*.json`, `*.pem`. Contoh nilai hanya di file `*.example` dengan placeholder.
6. **Redaksi di dokumen:** pakai placeholder `<ACCOUNT_ID>`, `<TSG_ID>`, `<DISCOVERY_ACCOUNT_ID>`, `<OTID>`, `<EKS_ENDPOINT_HOST>`, `<FW_MGMT_EIP>`, `<TC_MGMT_EIP>`, `<VPCE_ID>`, `<ADMIN_IP>`. Jangan tulis nama/identitas pribadi.
7. **Akui kalau salah atau tidak yakin.** Bedakan fakta terverifikasi vs dugaan. Untuk produk PANW, rujuk docs.paloaltonetworks.com dan sebutkan kalau dokumentasi tidak membahasnya.
8. **Perubahan Terraform:** pastikan `plan` hanya berisi perubahan yang diharapkan (terutama tidak ada replace firewall/EKS/IAM role yang sedang dipakai) sebelum apply.

## Struktur

| Path | Isi |
|---|---|
| `network.tf`, `eks.tf`, `firewall.tf`, `gwlb.tf`, `pan-cni.tf` | Infrastruktur inti |
| `tag-collector.tf` | Tag collector (toggle `enable_tag_collector`) |
| `gwlb-test.tf`, `scp-helper.tf` | Resource uji sementara (toggle, default off) |
| `k8s/airs-demo-all.yaml`, `k8s/test.sh` | Demo dan uji 15 cek (harus `15 PASS, 0 FAIL`) |
| `k8s/tag-collector-serviceaccount.yaml` | SA `pan-plugin-user` + RBAC tambahan untuk tag collector |
| `*.example` | Template variabel tanpa secret |

## Perintah umum

```bash
terraform plan -var enable_tag_collector=true
terraform apply -var enable_tag_collector=true
$(terraform output -raw kubeconfig_command)
kubectl apply -f k8s/airs-demo-all.yaml
bash k8s/test.sh
```

Firewall / tag collector (PAN-OS CLI), contoh cek:

```
show plugins vm_series aws gwlb
show plugins kubernetes status
show plugins kubernetes counters
show redistribution service client all
show object registered-ip all
```

## Gotcha yang sudah ditemukan (jangan diulang)

- **CLI PAN-OS:** perintah `set` panjang satu baris dari dokumentasi sering `Invalid syntax`; pecah satu atribut per baris. `api-server-address` diisi hostname EKS **tanpa `https://`**. `match` di CLI bukan regex (tidak mendukung `a|b`).
- **Candidate config** tetap tersimpan walau sesi ditutup. Commit yang gagal meninggalkan entri yang menggagalkan commit berikutnya: hapus dengan `delete ...` dulu.
- **Overlay routing** bisa menyala lagi setelah push SCM. Desain ini single-arm: harus `False`.
- **vpce → subinterface association** bekerja untuk trafik GWLB biasa (route table), tapi **tidak** untuk trafik PAN CNI (selalu zone parent `LAN`). Segmentasi Kubernetes pakai DAG, bukan zone. `associate` butuh ID `vpce-...` (bukan `vpce-svc-...`). Subinterface di AWS butuh IP statis dummy (DHCP tidak dapat IP).
- **Tag collector hanya menerima token ServiceAccount** (`File should be json containing Token and CA cert.`). File AWS/IAM role, kredensial STS, dan token EKS hasil IAM sudah dicoba dan ditolak. `private_cluster_role` tidak pernah di-assume. Jangan ulangi eksperimen IAM tanpa info baru dari PANW.
- **RBAC chart PANW kurang** untuk tag collector: perlu `serviceaccounts`/`namespaces` (get/list/watch) dan `watch` untuk `nodes`/`endpoints`. Sudah ada di `k8s/tag-collector-serviceaccount.yaml`; jangan apply `plugin-serviceaccount.yaml` asli karena menimpa izin itu.
- **Cluster dibuat ulang** = hostname endpoint dan token SA berubah; kredensial di tag collector harus diperbarui.
- **Template SCM tag collector** memakai TGW dan VPC `10.20.0.0/16` (overlap). Tidak dipakai; sudah diadaptasi ke satu VPC tanpa TGW. Nilai `authcodes`/PIN di template adalah placeholder huruf berulang.
- **Discovery PANW** memakai role onboarding `airs-aws-logs_ip_tag` (sesi `cloud-ip-tag-k8s`, `ListClusters`/`DescribeCluster` tiap ±15 menit). Panggilan Kubernetes API tidak terlihat di CloudTrail.
- **Container discovery dari cloud PANW** butuh EKS auth mode `API_AND_CONFIG_MAP` dan endpoint public yang mengizinkan IP perimeter PANW (lihat README 4.0). Kalau `eks_public_access_cidrs` dipersempit, discovery bisa putus.
- **Konfigurasi DLP dari SCM** (`PII Basic Block All Data` → `DLP App Exclusion`) memunculkan error validasi di tag collector.

## Pertanyaan terbuka ke PANW

- Dukungan zone/subinterface per GWLB endpoint untuk trafik PAN CNI.
- Cara memakai `private_cluster_role` (IAM) untuk tag collector, alih-alih token ServiceAccount.
- Versi PAN-OS tag collector: dokumentasi menyebut 11.2.10, template SCM memakai 12.2.3.
