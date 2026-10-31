#!/usr/bin/env bash
# Uji trafik pod-to-pod lewat Prisma AIRS firewall (PAN CNI -> GWLBE -> GWLB -> FW).
# Pakai: bash k8s/test.sh
#
# Semua tes berasal dari pod "client" di namespace airs-demo.
#
#   No | Skenario              | Asal              | Tujuan               | Lewat            | Port
#   ---+-----------------------+-------------------+----------------------+------------------+-----
#    1 | Namespace SAMA        | airs-demo/client  | airs-demo/web        | Service ClusterIP|  80
#    2 | Namespace SAMA        | airs-demo/client  | airs-demo/web        | Service headless |  80
#    3 | Namespace SAMA        | airs-demo/client  | airs-demo/web (tiap) | IP pod langsung  |  80
#    4 | Namespace BEDA        | airs-demo/client  | airs-demo-b/web2     | Service ClusterIP|  81
#    5 | Namespace BEDA        | airs-demo/client  | airs-demo-b/web2     | Service headless |  81
#    6 | Namespace BEDA        | airs-demo/client  | airs-demo-b/web2     | IP pod langsung  |  81
#
# ClusterIP : DNS -> IP virtual Service, kube-proxy meneruskan ke salah satu pod.
# Headless  : DNS langsung mengembalikan IP pod (tanpa IP virtual).
# IP pod    : tanpa DNS dan tanpa Service sama sekali.
# Kolom "node" menunjukkan apakah pod tujuan satu node dengan client atau beda node
# (beda node = trafik juga melewati jaringan VPC antar-node).
#
# Kedua namespace HARUS ber-annotation paloaltonetworks.com/firewall=pan-fw,
# kalau tidak, salah satu arah tidak lewat firewall.
#
# Filter Traffic log firewall:
#   tes 1-3 (web)  : ( port.dst eq 80 ) and ( addr.src neq 10.20.250.12 )
#   tes 4-6 (web2) : ( port.dst eq 81 )
set -u

PASS=0; FAIL=0
CLIENT_NODE=$(kubectl -n airs-demo get pod -l app=client -o jsonpath='{.items[0].spec.nodeName}')

curl_code() {
  kubectl -n airs-demo exec deploy/client -- curl -s -o /dev/null -w "%{http_code}" -m 5 "$1" 2>/dev/null || true
}

node_rel() {  # $1 = node tujuan
  [ "$1" = "$CLIENT_NODE" ] && echo "satu node" || echo "beda node"
}

run() {  # $1 = label, $2 = url
  local code; code=$(curl_code "$2")
  if [ "$code" = "200" ]; then PASS=$((PASS+1)); r="PASS"; else FAIL=$((FAIL+1)); r="FAIL"; fi
  printf "  %-62s -> %s  %s\n" "$1" "${code:-000}" "$r"
}

echo "== Prasyarat: annotation namespace (harus pan-fw di keduanya)"
kubectl get ns airs-demo airs-demo-b \
  -o custom-columns=NAMESPACE:.metadata.name,FIREWALL:'.metadata.annotations.paloaltonetworks\.com/firewall'
echo
echo "== Posisi pod (client di node: $CLIENT_NODE)"
kubectl get pods -n airs-demo   -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName --no-headers
kubectl get pods -n airs-demo-b -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName --no-headers
echo

echo "== NAMESPACE SAMA: airs-demo/client -> airs-demo/web (port 80)"
for i in 1 2 3; do run "[1] via Service ClusterIP  http://web            (#$i)" "http://web"; done
for i in 1 2 3; do run "[2] via Service headless   http://web-direct     (#$i)" "http://web-direct"; done
for p in $(kubectl -n airs-demo get pod -l app=web -o jsonpath='{range .items[*]}{.status.podIP},{.spec.nodeName}{" "}{end}'); do
  ip=${p%%,*}; node=${p#*,}
  run "[3] via IP pod langsung   http://$ip ($(node_rel "$node"))" "http://$ip"
done
echo

echo "== NAMESPACE BEDA: airs-demo/client -> airs-demo-b/web2 (port 81)"
for i in 1 2 3; do run "[4] via Service ClusterIP  web2.airs-demo-b:81    (#$i)" "http://web2.airs-demo-b.svc.cluster.local:81"; done
for i in 1 2 3; do run "[5] via Service headless   web2-direct.airs-demo-b:81 (#$i)" "http://web2-direct.airs-demo-b.svc.cluster.local:81"; done
for p in $(kubectl -n airs-demo-b get pod -l app=web2 -o jsonpath='{range .items[*]}{.status.podIP},{.spec.nodeName}{" "}{end}'); do
  ip=${p%%,*}; node=${p#*,}
  run "[6] via IP pod langsung   http://$ip:81 ($(node_rel "$node"))" "http://$ip:81"
done
echo

echo "== Ringkasan: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
