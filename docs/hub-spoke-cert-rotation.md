# Scenario C: hub-to-spoke communication across hub certificate rotation

This scenario checks that RHACM managed spokes stay connected when
[cert-manager](https://cert-manager.io/docs/) issues and rotates the hub API
server certificate, using the KlusterletConfig from
[telco-reference PR #1027](https://github.com/openshift-kni/telco-reference/pull/1027)
([OCPBUGS-85774](https://issues.redhat.com/browse/OCPBUGS-85774),
[CNF-21564](https://issues.redhat.com/browse/CNF-21564)).

By default, ACM gives spokes the CA it detects from the hub API certificate
secret. cert-manager does not store the root CA there, so a certificate change
can disconnect the spokes. The
[KlusterletConfig](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/clusters/index#set-hub-kube-api-server)
with `serverVerificationStrategy: UseCustomCABundles` gives the spokes the root
CA instead, so they trust every certificate it signs.

> **Important:** the custom bundle *replaces* the spoke's trusted CA; it is not
> added to it. On a hub with connected spokes, the bundle must also hold the CA
> of the certificate the hub serves today, or the spokes disconnect
> ([Step 4](#step-4-distribute-the-root-ca-to-the-spoke)).

| Input | Value |
|-------|-------|
| cert-manager | `cert-manager-operator.v1.20.1` from `redhat-operators` |
| KlusterletConfig | [manifests/hub-klusterletconfig.yaml](../manifests/hub-klusterletconfig.yaml), the same `spec` as PR #1027 |
| Issuer | A self-signed root CA with a CA `ClusterIssuer` (PR #1027 uses ACME; the trust mechanism is the same) |
| Validated on | OCP 4.22 SNO hub with ACM/MCE 2.17.3 and an OCP 4.22 spoke, November 2026 |

## Flow overview

```mermaid
flowchart TD
    subgraph setup["Set up the hub"]
        direction LR
        S1["1 · Baseline"] --> S2["2 · Install cert-manager"] --> S3["3 · Root CA + issuer"]
    end
    subgraph trust["Distribute trust"]
        direction LR
        S4["4 · CA bundle +<br/>KlusterletConfig"] --> V4{"Spoke<br/>AVAILABLE?"}
        V4 -. no .-> REC["Recover<br/>the spoke"]
        REC -.-> V4
    end
    subgraph swap["Switch the hub certificate"]
        direction LR
        S5["5 · Update kubeconfig"] --> S6["6 · Serve cert-manager cert"] --> C1(["✓ Spoke checks"])
    end
    subgraph rot["Rotate (2–3 times)"]
        direction LR
        S7["7 · Rotate cert"] --> C2(["✓ Spoke checks"])
        C2 -. again .-> S7
    end
    setup --> trust
    trust -- yes --> swap
    swap --> rot
    rot --> CL["Cleanup"]
```

## Prerequisites

- A hub with RHACM 2.11 or later, and a managed spoke that is `JOINED=True`
  and `AVAILABLE=True`. The [ZTP setup guide](ztp-hub-spoke-setup.md) can
  provision both.
- Cluster-admin kubeconfigs for the hub and the spoke.
- `oc`, `openssl`, `envsubst`, and `curl`.
- Optional: [`cmctl`](https://cert-manager.io/docs/reference/cmctl/)
  (`brew install cmctl`) for Step 7.

Download the helper scripts into a working directory, set the environment, and
load the helpers. All later commands run in this directory, against the hub
unless they pass `--kubeconfig "$SPOKE_KUBECONFIG"`.

```bash
mkdir -p ~/hub-spoke-test && cd ~/hub-spoke-test
base=https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main
curl -sL -O "$base/scripts/hub-spoke-helpers.sh" -O "$base/scripts/spoke-checks.sh"
chmod +x spoke-checks.sh

export HUB_KUBECONFIG="/path/to/hub-kubeconfig"
export SPOKE_KUBECONFIG="/path/to/spoke-kubeconfig"
export SPOKE_NAME="my-spoke"   # ManagedCluster name on the hub
source ./hub-spoke-helpers.sh
```

[`hub-spoke-helpers.sh`](../scripts/hub-spoke-helpers.sh) sets `KUBECONFIG`
and `HUB_API_HOST`, and defines `hub_served_cert`, `wait_for_served_cert`,
`pem_subjects`, `hub_bootstrap_ca`, `spoke_bootstrap_ca`, and `issued_serial`.

[`spoke-checks.sh`](../scripts/spoke-checks.sh) runs the six spoke
communication checks and prints `PASS` or `FAIL` for each. It takes about two
minutes:

| # | Check |
|---|-------|
| 1 | The hub reports the spoke `AVAILABLE` |
| 2 | The spoke's `managed-cluster-lease` renews |
| 3 | Every add-on is `AVAILABLE` |
| 4 | A new ManifestWork reaches the spoke (creates a ConfigMap there) |
| 5 | No `x509` errors in any klusterlet pod |
| 6 | The spoke's bootstrap CA matches the hub's and trusts the served certificate's issuer |

## Step 1: Record the baseline

```bash
hub_served_cert -subject -issuer -serial -enddate | tee hub-api-cert.baseline
./spoke-checks.sh
```

All checks should pass before you start.

## Step 2: Install cert-manager on the hub

```bash
oc apply -f "$base/manifests/hub-cert-manager-namespace.yaml"
oc apply -f "$base/manifests/subscription-cert-manager.yaml"
oc -n cert-manager-operator get installplan
```

Approve the InstallPlan for `cert-manager-operator.v1.20.1`, then create the
operand:

```bash
oc -n cert-manager-operator patch installplan <installplan-name> \
  --type merge -p '{"spec":{"approved":true}}'
oc -n cert-manager-operator wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv/cert-manager-operator.v1.20.1 --timeout=5m

oc apply -f "$base/manifests/cert-manager-cr.yaml"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  oc -n cert-manager rollout status deploy/$d
done
```

## Step 3: Create the root CA and issuer

[hub-root-ca-issuer.yaml](../manifests/hub-root-ca-issuer.yaml) creates a
self-signed root CA (`CN=hub-root-ca`) and a `ClusterIssuer` named
`hub-root-ca-issuer`:

```bash
oc apply -f "$base/manifests/hub-root-ca-issuer.yaml"
oc -n cert-manager wait --for=condition=Ready certificate/hub-root-ca --timeout=2m
oc wait --for=condition=Ready clusterissuer/hub-root-ca-issuer --timeout=2m

oc -n cert-manager get secret hub-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > hub-root-ca.pem
openssl x509 -in hub-root-ca.pem -noout -subject -ext basicConstraints
```

**Pass:** `subject=CN=hub-root-ca` and `CA:TRUE`.

## Step 4: Distribute the root CA to the spoke

Build the bundle from the root CA **plus** the OpenShift API serving CAs the
hub still uses, so the spoke trusts both the current certificate and the
cert-manager one. Then create the labeled ConfigMap (the label value must be
`"true"`), apply the KlusterletConfig, and annotate the spoke:

```bash
oc -n openshift-kube-apiserver get configmap kube-apiserver-server-ca \
  -o jsonpath='{.data.ca-bundle\.crt}' > ocp-api-server-ca.pem
cat hub-root-ca.pem ocp-api-server-ca.pem > hub-ca-bundle.pem
pem_subjects < hub-ca-bundle.pem

oc -n multicluster-engine create configmap cert-manager-hub-ca-bundle \
  --from-file=ca-bundle.crt=hub-ca-bundle.pem --dry-run=client -o yaml | oc apply -f -
oc -n multicluster-engine label configmap cert-manager-hub-ca-bundle \
  import.open-cluster-management.io/ca-bundle=true --overwrite

oc apply -f "$base/manifests/hub-klusterletconfig.yaml"
oc annotate managedcluster "$SPOKE_NAME" \
  agent.open-cluster-management.io/klusterlet-config=cert-manager-ca-config --overwrite
```

If the spoke already selects a KlusterletConfig (check with
`oc get managedcluster "$SPOKE_NAME" -o jsonpath='{.metadata.annotations.agent\.open-cluster-management\.io/klusterlet-config}'`),
don't overwrite the annotation, or its other settings (proxy, node placement)
are lost. Add the `hubKubeAPIServerConfig` section to that KlusterletConfig
instead.

For a new ZTP spoke, set the annotation in the ClusterInstance instead:

```yaml
spec:
  extraAnnotations:
    ManagedCluster:
      agent.open-cluster-management.io/klusterlet-config: "cert-manager-ca-config"
```

Within about a minute, the import controller regenerates the spoke's bootstrap
kubeconfig, the spoke applies it, and the klusterlet agent restarts once. Then
run the checks:

```bash
./spoke-checks.sh
```

**Pass:** all checks pass, and check 6 lists `CN=hub-root-ca` alongside the
`kube-apiserver-*-signer` CAs. Do not continue until this passes. If the spoke
disconnects, see
[Recovering a disconnected spoke](#recovering-a-disconnected-spoke).

## Step 5: Keep your hub kubeconfig working

Once the hub serves a `hub-root-ca` certificate, `oc` with your current
kubeconfig fails with `x509: certificate signed by unknown authority`. Back up
the kubeconfig and add the root CA to it:

```bash
cp "$HUB_KUBECONFIG" "$HUB_KUBECONFIG.bak"
HUB_CLUSTER="$(oc config view --minify -o jsonpath='{.clusters[0].name}')"
{
  oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d
  cat hub-root-ca.pem
} > hub-kubeconfig-ca.pem
oc config set "clusters.$HUB_CLUSTER.certificate-authority-data" \
  "$(base64 < hub-kubeconfig-ca.pem | tr -d '\n')"
oc whoami
```

If your kubeconfig uses `certificate-authority` (a file path) instead, append
the root CA to that file.

## Step 6: Serve a cert-manager certificate from the hub API

Issue the [hub API certificate](../manifests/hub-api-certificate.yaml) and
point the `APIServer` at it. The patch replaces any existing
`namedCertificates`; if the hub already has some, edit the list instead.

```bash
curl -sL "$base/manifests/hub-api-certificate.yaml" | envsubst | oc apply -f -
oc -n openshift-config wait --for=condition=Ready certificate/hub-api-certificate --timeout=2m

oc patch apiserver cluster --type merge -p "{
  \"spec\": {\"servingCerts\": {\"namedCertificates\": [{
    \"names\": [\"$HUB_API_HOST\"],
    \"servingCertificate\": {\"name\": \"hub-api-cert\"}
  }]}}
}"
```

The kube-apiserver rolls out a new revision (about 3 minutes on SNO, longer on
a multi-node hub), and the API is briefly unavailable. Wait for the new
certificate and the rollout, then run the checks:

```bash
wait_for_served_cert hub-root-ca
oc wait co/kube-apiserver --for=condition=Progressing=False --timeout=30m   # rerun on connection errors
./spoke-checks.sh
```

**Pass (first pass/fail point):** the served issuer is `CN=hub-root-ca` and
all checks pass.

## Step 7: Trigger certificate rotation

Force cert-manager to reissue the certificate with either option. Both create
a new private key (`rotationPolicy: Always`):

```bash
issued_serial | tee hub-api-serial.before

cmctl renew hub-api-certificate -n openshift-config      # Option A: normal renewal path
# oc -n openshift-config delete secret hub-api-cert      # Option B: delete the secret
```

Wait for the new serial to be served, then run the checks:

```bash
oc -n openshift-config wait --for=condition=Ready certificate/hub-api-certificate --timeout=5m
issued_serial | tee hub-api-serial.after
cmp -s hub-api-serial.before hub-api-serial.after && echo "FAIL: serial did not change"
wait_for_served_cert "$(cat hub-api-serial.after)"
./spoke-checks.sh
```

A rotation does not roll out a new kube-apiserver revision. The new serial is
served within seconds, with no API outage.

**Pass (second pass/fail point):** the hub serves the new serial and all
checks pass. Repeat Step 7 two or three times, using both options.

To test expiry-driven renewal instead, set `spec.duration: 1h` and
`spec.renewBefore: 30m` on the certificate.

## Cleanup

Revert the hub to its OpenShift-managed certificate. The spoke still trusts the
OpenShift CAs from the Step 4 bundle; confirm with `spoke_bootstrap_ca |
pem_subjects` first.

```bash
oc patch apiserver cluster --type json -p '[{"op":"remove","path":"/spec/servingCerts/namedCertificates"}]'
wait_for_served_cert "$(sed -n 's/^issuer=//p' hub-api-cert.baseline)"
oc wait co/kube-apiserver --for=condition=Progressing=False --timeout=30m
cp "$HUB_KUBECONFIG.bak" "$HUB_KUBECONFIG"
```

Remove the test resources. cert-manager does not delete secrets with their
`Certificate`, so delete those too:

```bash
oc annotate managedcluster "$SPOKE_NAME" agent.open-cluster-management.io/klusterlet-config-
oc delete klusterletconfig cert-manager-ca-config
oc -n multicluster-engine delete configmap cert-manager-hub-ca-bundle
oc -n openshift-config delete certificate hub-api-certificate
oc -n openshift-config delete secret hub-api-cert
oc delete -f "$base/manifests/hub-root-ca-issuer.yaml"
oc -n cert-manager delete secret hub-root-ca
```

Removing the annotation returns the spoke to the auto-detected CA, and the
klusterlet agent restarts once more. Wait two minutes, then confirm:

```bash
./spoke-checks.sh
```

## Troubleshooting

```bash
# Trust configuration on the hub
oc -n multicluster-engine get configmap cert-manager-hub-ca-bundle --show-labels
oc get klusterletconfig cert-manager-ca-config -o yaml
oc get managedcluster "$SPOKE_NAME" -o jsonpath='{.metadata.annotations}{"\n"}'
hub_bootstrap_ca | pem_subjects
spoke_bootstrap_ca | pem_subjects

# Import controller: two replicas, check both
for p in $(oc -n multicluster-engine get pod -o name | grep managedcluster-import-controller); do
  oc -n multicluster-engine logs "$p" --since=30m | grep -i "bootstrap kubeconfig.*$SPOKE_NAME"
done

# cert-manager and the kube-apiserver
oc -n openshift-config describe certificate hub-api-certificate
oc -n cert-manager logs deploy/cert-manager --since=30m
oc get co kube-apiserver
oc get apiserver cluster -o jsonpath='{.spec.servingCerts}{"\n"}'

# Spoke klusterlet
oc --kubeconfig "$SPOKE_KUBECONFIG" -n open-cluster-management-agent get pods
```

### Recovering a disconnected spoke

**Symptom:** the hub shows the spoke `AVAILABLE=Unknown`, its lease stops
renewing, and the klusterlet logs `x509: certificate signed by unknown
authority`. Compare `spoke_bootstrap_ca | pem_subjects` with
`hub_served_cert -issuer`: the served issuer is missing from the spoke's
bundle.

The spoke cannot recover on its own, because the fix reaches it through a
ManifestWork it can no longer fetch. To recover:

1. Fix the ConfigMap on the hub as in Step 4.
2. **Wait** until `hub_bootstrap_ca | pem_subjects` includes the served issuer.
   This can take several minutes. If you skip the wait, the spoke's work agent
   re-applies the old bundle as soon as the spoke reconnects, and it
   disconnects again.
3. Copy that bundle into the spoke and delete the agent pods. Use
   `delete pod`; `oc rollout restart` is reverted by the klusterlet operator.

```bash
hub_bootstrap_ca > recovery-ca.pem
oc --kubeconfig "$SPOKE_KUBECONFIG" -n open-cluster-management-agent \
  get secret bootstrap-hub-kubeconfig -o jsonpath='{.data.kubeconfig}' \
  | base64 -d > spoke-bootstrap.kubeconfig
cp spoke-bootstrap.kubeconfig spoke-bootstrap.kubeconfig.bak
BOOT_CLUSTER="$(oc --kubeconfig spoke-bootstrap.kubeconfig config view -o jsonpath='{.clusters[0].name}')"
oc --kubeconfig spoke-bootstrap.kubeconfig config set \
  "clusters.$BOOT_CLUSTER.certificate-authority-data" "$(base64 < recovery-ca.pem | tr -d '\n')"
oc --kubeconfig "$SPOKE_KUBECONFIG" -n open-cluster-management-agent \
  set data secret/bootstrap-hub-kubeconfig --from-file=kubeconfig=spoke-bootstrap.kubeconfig
oc --kubeconfig "$SPOKE_KUBECONFIG" -n open-cluster-management-agent \
  delete pod -l app=klusterlet-agent
```

Wait two minutes, then run `./spoke-checks.sh`. Re-importing the spoke also
works.
