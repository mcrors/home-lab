# MetalLB Setup (k3s Home Lab)

Add a simple, repeatable way to expose services on your LAN using MetalLB (Layer-2 / ARP mode). This repo installs MetalLB, creates your IP pool + L2 advertisement, and (optionally) runs a smoke test.

Default IP range assumed: 192.168.1.250–192.168.1.254 (already reserved in your DHCP).
Target cluster: k3s v1.24.x (works fine).

## Repo layout

```arduino
metallb-setup/
├── config.env                 # knobs: namespace, pool range, versions, flags
├── helm/
│   └── values.yaml            # minimal; document overrides here
├── manifests/
│   ├── ipaddresspool.tmpl.yaml
│   └── l2advertisement.tmpl.yaml
└── scripts/
    ├── bootstrap_repo.sh      # add/update Helm repo
    ├── deploy_metallb.sh      # install MetalLB + apply pool/advert (+ optional smoke test)
    └── uninstall_metallb.sh   # remove release & CRs (safe rollback)
```

## Prerequisites

* DHCP reserved range on your router (IPs kept out of the DHCP pool): 192.168.1.250–.254.
* CLI tools on your workstation or jump host:
    * kubectl (pointed at the correct cluster/context)
    * helm
    * envsubst (from gettext)
    * bash
* k3s (or Kubernetes) reachable; nodes Ready.

## Configure

Open config.env and adjust as needed:
* POOL_ADDRESSES="192.168.1.250-192.168.1.254" – your reserved range
* POOL_NAME, L2_ADV_NAME, NAMESPACE, RELEASE_NAME – namespacing
* CHART_VERSION – optionally pin the MetalLB chart
* MEMBERLIST_SECRET_ENABLED – set to "true" to create a memberlist secret (nice to have)
* SMOKE_TEST_ENABLED – "true" runs a temporary LB service to validate the pool
* KUBECTL_CONTEXT – set only if you need to force a specific kube-context

You can leave helm/values.yaml mostly empty; it documents overrides you might want later.

## Install

From the repo root:
```bash
chmod +x scripts/*.sh
./scripts/bootstrap_repo.sh
./scripts/deploy_metallb.sh
```

What the deploy script does:
1. Creates the namespace (if missing).
2. (Optionally) creates the memberlist secret.
3. helm upgrade --install the MetalLB chart (optionally version-pinned).
4. Waits for metallb-controller + metallb-speaker.
5. Applies IPAddressPool and L2Advertisement.
6. (Optional) Runs a smoke test LoadBalancer service and prints the assigned IP.

## Verify

Useful checks:
```bash
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system get ipaddresspools,l2advertisements
# If smoke test enabled:
kubectl get svc lb-test -o wide
```
