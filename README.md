# cert-manager POC image builder

This repository builds and publishes test images from the current upstream
branches of:

- `openshift/cert-manager-operator` (`master`)
- `openshift-kni/lifecycle-agent` (`main`)
- `rh-ecosystem-edge/recert` (`main`)

The workflow runs nightly at 06:00 UTC and can also be manually dispatched from
[Actions](../../actions). It resolves the source commits, builds `linux/amd64`
and `linux/arm64` images, publishes the operator bundles and catalogs, and
records the exact source commits in the workflow summary.

These images are for OpenShift hub/spoke and SNO testing only. They are not
production release artifacts.

## Current image set

The current build uses these readable tags:

```bash
export RECERT_IMAGE=quay.io/bapalm/recert:main-78abf4
export LCA_IMAGE=quay.io/bapalm/lifecycle-agent-operator:main-cb8304
export LCA_BUNDLE_IMAGE=quay.io/bapalm/lifecycle-agent-operator-bundle:main-cb8304
export LCA_CATALOG_IMAGE=quay.io/bapalm/lifecycle-agent-operator-catalog:main-cb8304
export CERT_MANAGER_IMAGE=quay.io/bapalm/cert-manager-operator:master-a5aacc
export CERT_MANAGER_BUNDLE_IMAGE=quay.io/bapalm/cert-manager-operator-bundle:master-a5aacc
export CERT_MANAGER_CATALOG_IMAGE=quay.io/bapalm/cert-manager-operator-catalog:master-a5aacc
```

The tag format is `<source-ref>-<first-six-characters-of-source-SHA>`. When a
new build completes, copy the image references from its workflow summary and
replace the variables above.

---

## Scenario A: ECDSA/RSA certificate preservation across IBU

This scenario validates that cert-manager-issued ECDSA and RSA certificates
survive an image-based upgrade. It exercises both
[cert-manager-operator PR #424](https://github.com/openshift/cert-manager-operator/pull/424)
(consoleless support) and
[recert PR #1758](https://github.com/rh-ecosystem-edge/recert/pull/1758)
(ECDSA PKCS#8 handling during post-pivot recert).

### Prerequisites

- OpenShift 4.19 or newer SNO spoke, preferably disposable.
- A seed image at the target version (see [Seed image creation](#seed-image-creation)).
- OADP / Velero installed and a working `DataProtectionApplication` on the spoke.
- `oc` logged in with cluster-admin privileges.

```bash
export KUBECONFIG="$SPOKE_KUBECONFIG"
oc whoami
oc version
```

### Step 1: Set up CatalogSources and namespaces

Apply the catalog sources, namespaces, and operator groups in a single manifest:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-lifecycle-agent
  annotations:
    workload.openshift.io/allowed: management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec: {}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: lifecycle-agent
  namespace: openshift-lifecycle-agent
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: bapalm-cert-manager-poc
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/bapalm/cert-manager-operator-catalog:master-a5aacc
  displayName: bapalm cert-manager POC
  publisher: bapalm
  updateStrategy:
    registryPoll:
      interval: 10m
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: bapalm-lifecycle-agent-poc
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/bapalm/lifecycle-agent-operator-catalog:main-cb8304
  displayName: bapalm lifecycle-agent POC
  publisher: bapalm
  updateStrategy:
    registryPoll:
      interval: 10m
```

```bash
oc apply -f catalogs-and-namespaces.yaml
oc -n openshift-marketplace wait --for=condition=READY \
  catalogsource/bapalm-cert-manager-poc --timeout=5m
oc -n openshift-marketplace wait --for=condition=READY \
  catalogsource/bapalm-lifecycle-agent-poc --timeout=5m
oc -n openshift-marketplace get packagemanifest \
  cert-manager-operator lifecycle-agent
```

### Step 2: Install lifecycle-agent operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lifecycle-agent
  namespace: openshift-lifecycle-agent
spec:
  channel: alpha
  name: lifecycle-agent
  source: bapalm-lifecycle-agent-poc
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

```bash
oc apply -f subscription-lca.yaml
oc -n openshift-lifecycle-agent get subscription,installplan,csv
oc -n openshift-lifecycle-agent rollout status deploy/lifecycle-agent-controller-manager
```

Confirm the deployment uses the expected image:

```bash
oc -n openshift-lifecycle-agent get deploy lifecycle-agent-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

### Step 3: Install cert-manager-operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: cert-manager-operator
  source: bapalm-cert-manager-poc
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

```bash
oc apply -f subscription-cert-manager.yaml
oc -n cert-manager-operator get subscription,installplan,csv
oc -n cert-manager-operator rollout status deploy/cert-manager-operator-controller-manager
```

Create the singleton `CertManager` resource:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: CertManager
metadata:
  name: cluster
spec:
  managementState: Managed
  logLevel: Normal
```

```bash
oc apply -f cert-manager.yaml
oc -n cert-manager get deploy,pods
oc -n cert-manager rollout status deploy/cert-manager
oc -n cert-manager rollout status deploy/cert-manager-webhook
oc -n cert-manager rollout status deploy/cert-manager-cainjector
```

### Step 4: Create test certificates (ECDSA and RSA)

Create a self-signed issuer and one certificate of each key type:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-poc
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: cert-manager-poc
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-ecdsa
  namespace: cert-manager-poc
spec:
  secretName: test-ecdsa-tls
  commonName: test-ecdsa.example.com
  dnsNames:
  - test-ecdsa.example.com
  issuerRef:
    name: selfsigned
    kind: Issuer
  privateKey:
    algorithm: ECDSA
    size: 256
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-rsa
  namespace: cert-manager-poc
spec:
  secretName: test-rsa-tls
  commonName: test-rsa.example.com
  dnsNames:
  - test-rsa.example.com
  issuerRef:
    name: selfsigned
    kind: Issuer
  privateKey:
    algorithm: RSA
    size: 2048
```

```bash
oc apply -f test-certificates.yaml
oc -n cert-manager-poc wait --for=condition=Ready certificate/test-ecdsa --timeout=2m
oc -n cert-manager-poc wait --for=condition=Ready certificate/test-rsa --timeout=2m
oc -n cert-manager-poc get certificate
```

Record the key types for post-upgrade comparison:

```bash
echo "=== ECDSA key type (expect: EC) ==="
oc -n cert-manager-poc get secret test-ecdsa-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -text -noout | grep 'EC\|Algorithm'

echo "=== RSA key type (expect: RSA) ==="
oc -n cert-manager-poc get secret test-rsa-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -text -noout | grep 'RSA\|Algorithm'
```

### Step 5: Configure the recert image

Set the recert image override on the `ImageBasedUpgrade` object before entering
`Prep`. LCA creates the singleton named `upgrade`.

```bash
oc annotate imagebasedupgrade upgrade \
  lca.openshift.io/recert-image="$RECERT_IMAGE" --overwrite
oc get imagebasedupgrade upgrade \
  -o jsonpath='{.metadata.annotations.lca\.openshift\.io/recert-image}{"\n"}'
```

If the recert image is in a private repository, also set the pull-secret
annotation pointing to a secret in `openshift-lifecycle-agent`:

```bash
oc annotate imagebasedupgrade upgrade \
  lca.openshift.io/recert-pull-secret=bapalm-quay-pull --overwrite
```

### Step 6: Perform the image-based upgrade

Replace `<seed-image>` and `<target-version>` with the values from your seed
cluster.

```yaml
apiVersion: lca.openshift.io/v1
kind: ImageBasedUpgrade
metadata:
  name: upgrade
  annotations:
    lca.openshift.io/recert-image: quay.io/bapalm/recert:main-78abf4
spec:
  stage: Prep
  seedImageRef:
    version: "<target-version>"
    image: "<seed-image>"
  oadpContent:
  - name: oadp-backup-restore-cm
    namespace: openshift-adp
  autoRollbackOnFailure:
    initMonitorTimeoutSeconds: 1800
```

```bash
oc apply -f ibu.yaml
oc get imagebasedupgrade upgrade -w
```

Wait for `PrepCompleted` before continuing. Once Prep is done, advance to
`Upgrade`:

```bash
oc patch imagebasedupgrade upgrade --type merge -p '{"spec":{"stage":"Upgrade"}}'
```

**The cluster will reboot.** You will lose connectivity for approximately
8–10 minutes while the node pivots to the new stateroot, recert runs, and
cluster operators stabilize. Reconnect and verify:

```bash
oc get clusterversion
oc get nodes
oc get co | grep -v 'True.*False.*False'
oc get imagebasedupgrade upgrade -o yaml
```

### Step 7: Verify certificates survived

Confirm both TLS secrets are present and contain the expected key types:

```bash
echo "=== Check ECDSA cert preserved ==="
oc -n cert-manager-poc get secret test-ecdsa-tls
oc -n cert-manager-poc get secret test-ecdsa-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -text -noout | grep 'EC\|Algorithm'

echo "=== Check RSA cert preserved ==="
oc -n cert-manager-poc get secret test-rsa-tls
oc -n cert-manager-poc get secret test-rsa-tls \
  -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -text -noout | grep 'RSA\|Algorithm'

echo "=== Certificate status ==="
oc -n cert-manager-poc get certificate
```

Check the LCA controller logs for recert processing:

```bash
oc -n openshift-lifecycle-agent logs deploy/lifecycle-agent-controller-manager \
  -c manager --since=2h | grep -i 'recert\|ecdsa\|pkcs\|postpivot'
```

A successful result shows both secrets intact with their original key types and
no recert errors in the LCA logs.

---

## Scenario B: cert-manager on a consoleless cluster

This scenario confirms that cert-manager-operator installs and issues
certificates correctly on a cluster without the OpenShift console
(`console-operator` disabled or absent). No browser or console URL is needed.

### Prerequisites

- An OpenShift cluster (SNO or multi-node) with the console operator disabled
  or removed. A standard SNO with
  `oc patch consoles.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Removed"}}'`
  is sufficient.
- `oc` logged in with cluster-admin privileges.

```bash
# Confirm console is not running
oc get co console
oc get deployment -n openshift-console 2>/dev/null || echo "no console deployment"
```

### Step 1: Install cert-manager-operator

Follow Steps 1 and 3 from [Scenario A](#scenario-a-ecdsarsa-certificate-preservation-across-ibu)
to apply the CatalogSource, Subscription, and `CertManager` CR.

```bash
oc apply -f catalogs-and-namespaces.yaml
oc -n openshift-marketplace wait --for=condition=READY \
  catalogsource/bapalm-cert-manager-poc --timeout=5m
oc apply -f subscription-cert-manager.yaml
oc apply -f cert-manager.yaml
```

### Step 2: Verify operator health on a consoleless cluster

Confirm the CSV, deployments, and cert issuance work using only `oc`:

```bash
# CSV ready
oc -n cert-manager-operator get csv -o wide

# All three operand deployments healthy
oc -n cert-manager get deploy,pods
oc -n cert-manager rollout status deploy/cert-manager
oc -n cert-manager rollout status deploy/cert-manager-webhook
oc -n cert-manager rollout status deploy/cert-manager-cainjector

# No degraded cluster operators related to cert-manager
oc get co | grep cert
```

Issue a test certificate to confirm core functionality:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-poc
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: cert-manager-poc
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: consoleless-test
  namespace: cert-manager-poc
spec:
  secretName: consoleless-test-tls
  commonName: consoleless.example.com
  dnsNames:
  - consoleless.example.com
  issuerRef:
    name: selfsigned
    kind: Issuer
  privateKey:
    algorithm: ECDSA
    size: 256
```

```bash
oc apply -f consoleless-test-cert.yaml
oc -n cert-manager-poc wait --for=condition=Ready certificate/consoleless-test --timeout=2m
oc -n cert-manager-poc get certificate consoleless-test -o wide
oc -n cert-manager-poc get secret consoleless-test-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
```

A `Ready=True` certificate and a valid x509 subject confirm that cert-manager
operates correctly with no console present.

---

## Seed image creation

The IBU seed image is a snapshot of a running SNO at the target OCP version.
Create it on a dedicated seed cluster before running Scenario A.

1. Create a pull-secret for the registry on the seed cluster:

```bash
export KUBECONFIG="$SEED_KUBECONFIG"
oc create secret generic seedgen \
  -n openshift-lifecycle-agent \
  --from-file=.dockerconfigjson=<path-to-pull-secret> \
  --type=kubernetes.io/dockerconfigjson
```

2. Apply the `SeedGenerator` CR:

```yaml
apiVersion: lca.openshift.io/v1
kind: SeedGenerator
metadata:
  name: seedimage
spec:
  seedImage: quay.io/<your-repo>/ibu-seed:<target-version>
```

```bash
oc apply -f seedgenerator.yaml
oc get seedgenerator seedimage -w
```

The seed cluster reboots during image creation (~15–20 minutes). The node
returns to normal operation after the image is pushed.

---

## Building custom images

To build images from feature branches or pull requests, dispatch the workflow
manually:

```bash
gh workflow run build-images.yml \
  --repo sebrandon1/cert-manager-poc \
  --ref main \
  --field lifecycle_ref=main \
  --field recert_ref=pull/1758/head \
  --field cert_manager_ref=pull/424/head \
  --field image_tag=auto
```

Use `pull/<number>/head` for fork PR code. Keep `image_tag=auto` so builds
from different branches do not overwrite one another.

Monitor progress and copy the image references from the completed workflow
summary:

```bash
gh run list --repo sebrandon1/cert-manager-poc \
  --workflow build-images.yml --limit 5
gh run view RUN_ID --repo sebrandon1/cert-manager-poc --web
```

Update the `Current image set` variables above with the tags from the summary
before running either scenario.

---

## Optional: private Quay pull credentials

If the POC repositories are private, create a registry secret and link it to
the operator service accounts:

```bash
oc -n cert-manager-operator create secret docker-registry bapalm-quay-pull \
  --docker-server=quay.io \
  --docker-username="$QUAY_USERNAME" \
  --docker-password="$QUAY_TOKEN"
oc -n cert-manager-operator secrets link cert-manager-operator-controller-manager \
  bapalm-quay-pull --for=pull

oc -n openshift-lifecycle-agent create secret docker-registry bapalm-quay-pull \
  --docker-server=quay.io \
  --docker-username="$QUAY_USERNAME" \
  --docker-password="$QUAY_TOKEN"
oc -n openshift-lifecycle-agent secrets link lifecycle-agent-controller-manager \
  bapalm-quay-pull --for=pull
```

Do not commit registry credentials to this repository.

---

## Troubleshooting

```bash
# Catalog and package discovery
oc -n openshift-marketplace describe catalogsource bapalm-cert-manager-poc
oc -n openshift-marketplace get pods -l olm.catalogSource=bapalm-cert-manager-poc
oc -n openshift-marketplace get packagemanifest cert-manager-operator -o yaml

# Subscription and install plan
oc -n cert-manager-operator describe subscription cert-manager-operator
oc -n cert-manager-operator get installplan -o yaml
oc -n cert-manager-operator get csv -o wide

# Operator events and logs
oc -n cert-manager-operator get events --sort-by=.lastTimestamp
oc -n cert-manager-operator logs deploy/cert-manager-operator-controller-manager \
  -c manager --since=30m
oc -n openshift-lifecycle-agent get events --sort-by=.lastTimestamp
oc -n openshift-lifecycle-agent logs deploy/lifecycle-agent-controller-manager \
  -c manager --since=30m

# Image resolution
oc -n cert-manager-operator get deploy -o yaml | grep 'image:'
oc -n openshift-lifecycle-agent get deploy -o yaml | grep 'image:'

# IBU status
oc get imagebasedupgrade upgrade -o yaml
oc get imagebasedupgrade upgrade \
  -o jsonpath='{range .status.history[*]}{.stage}{"\t"}{.startTime}{"\t"}{.completionTime}{"\n"}{end}'
oc -n openshift-lifecycle-agent logs deploy/lifecycle-agent-controller-manager \
  -c manager --since=2h | grep -i 'recert\|ecdsa\|pkcs\|rollback'
```
