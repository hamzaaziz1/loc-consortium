# Kubernetes deployment

A Helm chart for the six-node consortium, developed against kind.

## What this is and is not

It brings the network up on kind with mutual TLS intact, permissioning
enforced, and the same genesis the Compose stack uses. The EKS and AKS notes
below are notes: they describe what changes and why, and neither has been
deployed. Saying so is more useful than implying otherwise.

## Quick start

```bash
bash tools/kind-cluster.sh          # cluster, with images loaded
bash tools/k8s-prepare.sh           # chart files, node pubkeys, secrets
helm lint deploy/helm/besu-consortium
helm upgrade --install loc deploy/helm/besu-consortium \
  --namespace loc-consortium \
  -f deploy/helm/besu-consortium/values-kind.yaml \
  -f deploy/helm/besu-consortium/values-nodes.yaml
kubectl -n loc-consortium get pods -w
```

## The problem this chart exists to solve

**Besu's static node list requires IP addresses.** An enode URL carries a
public key and an address; devp2p identifies peers by the key and treats the
address as a route, so name resolution is deliberately outside the protocol.
Besu refuses to start with a hostname in the list.

Pods cannot have fixed IPs. So the addresses are not known when the chart is
rendered, only when the pods exist.

**The solve:** a StatefulSet per node behind a headless service, giving each
pod a stable DNS name, and an init container that resolves those names to
addresses at startup and writes the static node list into a shared volume.

Three details that matter and are easy to miss.

`publishNotReadyAddresses: true` on the headless service. Readiness depends on
peering, and peering depends on resolution, so if DNS waited for readiness the
network could never form. Peer-to-peer workloads differ from ordinary services
precisely here.

The init container retries resolution for two minutes. On a cold start a peer's
pod may not exist yet, and a missing entry means that node can never be
dialled. Waiting beats writing a list that is quietly incomplete.

**The permissions file is copied, not mounted.** ConfigMap mounts are always
read-only, and Besu proves at startup that it can *write* the permissions file,
because the `perm_add*` RPC methods persist allowlist changes back to it. A
read-only mount fails with `ERROR_ALLOWLIST_PERSIST_FAIL`. The init container
copies it into a writable `emptyDir`.

## One StatefulSet per node

Replicas are interchangeable; these nodes are not. Each has its own identity
key, TLS certificate, organisation and role. Modelling them as six replicas
would mean indexing secrets by ordinal and trusting the ordering never changes,
which is the kind of implicit coupling that breaks quietly.

## Secrets

Created by `tools/k8s-prepare.sh` with `kubectl`, never templated from values.
A values file ends up in shell history, CI logs and Helm's release storage.

**One simplification versus Compose, stated rather than hidden.** The chart
mounts the whole keystore secret into every node, so each pod can read every
other node's keystore. Compose mounts each node only its own. The reason is
that this is a single-tenant demonstration cluster; in a real consortium each
organisation runs its own cluster and mounts only its own key material, and
this is the first thing to change when that is true.

## What changes for EKS

**Storage class.** `standard` does not exist. Use `gp3` with an explicit
`StorageClass`, and set `volumeBindingMode: WaitForFirstConsumer` so the volume
is created in the same availability zone as the pod. Without it a pod can be
scheduled where its volume cannot follow, and the symptom is a pod stuck in
`Pending` with an event about zone mismatch.

**Node placement.** Validators should sit in different availability zones,
because the whole point of BFT is surviving the loss of one. Use pod
anti-affinity on `consortium/role: validator` with
`topology.kubernetes.io/zone`. A four-validator consortium that loses two to a
single zone failure has lost quorum, which is the one failure the design is
meant to prevent.

**Secrets.** Replace the `kubectl create secret` step with the AWS Secrets
Manager CSI driver or External Secrets Operator, so key material never passes
through a developer's machine.

**RPC exposure.** The endpoint requires a client certificate, so a load
balancer in front of it is not the hole it first appears, but it is still
attack surface. Use an internal NLB and keep it inside the VPC. **Do not
terminate TLS at the load balancer**: that would strip client certificates and
silently disable the authentication the whole design rests on. Pass TCP
through.

**Peer traffic.** Besu 26.8.1 has no peer-to-peer TLS (ADR 0005), so devp2p
traffic is unencrypted. Inside a VPC that may be acceptable; across VPCs or
accounts it is not, and this is where a service mesh with sidecar mTLS or
WireGuard between nodes belongs.

## What changes for AKS

Largely the same, with three differences.

**Storage.** `managed-csi-premium` for the data volumes. Standard disks have
burst-limited IOPS and a Besu node doing state writes will hit them.

**Secrets.** The Azure Key Vault Provider for Secrets Store CSI Driver.

**Zones.** Not every Azure region offers availability zones. Where they are
absent, validator anti-affinity falls back to node-level spreading, which
protects against node failure but not datacentre failure. That is a weaker
guarantee and the consortium members should be told which one they have.

## What is not here

**The permissioning controller, the proxy and observability.** The chart covers
the network. The controller would be a Deployment with the same mutual TLS
configuration, and the operator proxy becomes unnecessary in-cluster, because a
client running inside can present its own certificate and talk to the RPC
service directly. The proxy exists for Foundry's limitation on a developer
machine, not as a general pattern.

**Ingress.** Deliberately. Exposing a mutually authenticated RPC endpoint
publicly is a decision with a threat model attached, and that belongs in m9
rather than in a default.
