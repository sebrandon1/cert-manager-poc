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
export RECERT_IMAGE=quay.io/bapalm/recert:main-d00524
export LCA_IMAGE=quay.io/bapalm/lifecycle-agent-operator:main-8d3ff6
export LCA_BUNDLE_IMAGE=quay.io/bapalm/lifecycle-agent-operator-bundle:main-8d3ff6
export LCA_CATALOG_IMAGE=quay.io/bapalm/lifecycle-agent-operator-catalog:main-8d3ff6
export CERT_MANAGER_IMAGE=quay.io/bapalm/cert-manager-operator:master-a5aacc
export CERT_MANAGER_BUNDLE_IMAGE=quay.io/bapalm/cert-manager-operator-bundle:master-a5aacc
export CERT_MANAGER_CATALOG_IMAGE=quay.io/bapalm/cert-manager-operator-catalog:master-a5aacc
```

The tag format is `<source-ref>-<first-six-characters-of-source-SHA>`. When a
new build completes, copy the image references from its workflow summary and
replace the variables above.

---

## Prepare a ZTP hub and spoke

Use [succulent-cli](https://github.com/sebrandon1/succulent-cli) to inspect the
plan, submit a ZTP hub-and-spoke provisioning request, and retrieve each
cluster's kubeconfig. Install the CLI using its
[installation guide](https://github.com/sebrandon1/succulent-cli/blob/main/docs/installation.md),
then set the plan name and exact hub and spoke build tags:

```bash
succulent-cli version
export ZTP_ENV="my-ztp-plan"
export HUB_TAG="copy-exact-hub-build-tag"
export SPOKE_TAG="copy-exact-spoke-build-tag"
export ZTP_OWNER="your-username"
export ZTP_EMAIL="you@example.com"

succulent-cli get info --env "$ZTP_ENV"
```

Review the plan and hardware assignment before requesting a rebuild. Preview
the request first; the CLI requires `--confirm` for this preview as well, while
`--dry-run` prevents submission:

```bash
succulent-cli ztp provision --env "$ZTP_ENV" \
  --owner "$ZTP_OWNER" --email "$ZTP_EMAIL" \
  --sno-full-tag "$HUB_TAG" --spoke-full-tag "$SPOKE_TAG" \
  --type sno --confirm --dry-run
```

After checking the environment, release tags, and SNO type, submit it by
removing `--dry-run`:

```bash
succulent-cli ztp provision --env "$ZTP_ENV" \
  --owner "$ZTP_OWNER" --email "$ZTP_EMAIL" \
  --sno-full-tag "$HUB_TAG" --spoke-full-tag "$SPOKE_TAG" \
  --type sno --confirm
```

Monitor the environment while Succulent and the ZTP GitOps pipeline provision
the clusters:

```bash
succulent-cli get log --env "$ZTP_ENV" | tail -n 30
succulent-cli watch --env "$ZTP_ENV"
```

If the spoke needs an installation-time GitOps change before deployment, the
CLI supports `--stop-before-deployment` so the request can pause for that work.
Apply the environment's GitOps changes and resume its deployment through the
documented plan workflow before continuing. For example, the IBU container
partition must be configured as part of cluster installation; see the
[IBU prerequisites](#scenario-a-ecdsa-and-rsa-certificate-preservation-across-ibu).

Retrieve and check both credentials separately. The `management` choice is the
hub; `spoke` is the target SNO:

```bash
succulent-cli ztp kubeconfig --env "$ZTP_ENV" --choice management
succulent-cli ztp kubeconfig --env "$ZTP_ENV" --choice spoke

export HUB_KUBECONFIG="$HOME/Downloads/succulent/$ZTP_ENV/ztp-management-kubeconfig"
export SPOKE_KUBECONFIG="$HOME/Downloads/succulent/$ZTP_ENV/ztp-spoke-kubeconfig"

oc --kubeconfig "$HUB_KUBECONFIG" whoami
oc --kubeconfig "$HUB_KUBECONFIG" get nodes
oc --kubeconfig "$HUB_KUBECONFIG" get managedclusters
oc --kubeconfig "$SPOKE_KUBECONFIG" whoami
oc --kubeconfig "$SPOKE_KUBECONFIG" get clusterversion
oc --kubeconfig "$SPOKE_KUBECONFIG" get nodes
```

Proceed when both kubeconfigs authenticate, the spoke is Ready from the hub,
and the spoke version and node match the intended test target. Check the hub's
managed-cluster conditions for `Available=True`. If kubeconfig
retrieval returns an invalid file or `oc whoami` fails, fix access before
continuing. Use the spoke kubeconfig for Scenario A:

```bash
export KUBECONFIG="$SPOKE_KUBECONFIG"
```

---

## Scenario A: ECDSA and RSA certificate preservation across IBU

This scenario validates that cert-manager-issued ECDSA and RSA certificates
survive an image-based upgrade. It exercises both
[cert-manager-operator PR #424](https://github.com/openshift/cert-manager-operator/pull/424)
(consoleless support) and
[recert PR #1758](https://github.com/rh-ecosystem-edge/recert/pull/1758)
(ECDSA PKCS#8 handling during post-pivot recert).

### Prerequisites

- A SNO spoke using an OCP source and target version supported by the selected
  Lifecycle Agent and seed image. This flow has been exercised end-to-end from
  OCP 4.20.2 to 4.22.3.
- A compatible seed image at the target version (see
  [Seed image creation](#seed-image-creation)). The seed cluster must match the
  target's relevant hardware and configuration.
- A dedicated `/var/lib/containers` partition on both seed and target, created
  during installation, with the `varlibcontainers` partition label on both.
- OADP / Velero, a configured `DataProtectionApplication`, an accessible
  S3-compatible backup bucket, and backup and restore resources on the target
  spoke.
- A Lifecycle Agent version compatible with the one used to generate the seed.
- If RHACM manages the target, the hub must be at least as new as the IBU
  target release.
- `oc` logged in with cluster-admin privileges.

Read the [OpenShift IBU preparation and upgrade guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters)
for the complete version-specific requirements. In particular, the shared
container partition must be present when the seed and target clusters are
installed; adding it after provisioning does not satisfy this prerequisite.

```bash
export KUBECONFIG="$SPOKE_KUBECONFIG"
oc whoami
oc version
```

### Step 1: Set up CatalogSources and namespaces

Set the env vars from the [Current image set](#current-image-set) section above,
then apply the catalog sources, namespaces, and operator groups:

```bash
curl -sL https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/catalogs-and-namespaces.yaml \
  | envsubst | oc apply -f -
```

```bash
oc -n openshift-marketplace wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
  catalogsource/bapalm-cert-manager-poc --timeout=5m
oc -n openshift-marketplace wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
  catalogsource/bapalm-lifecycle-agent-poc --timeout=5m
oc -n openshift-marketplace get packagemanifest \
  cert-manager-operator lifecycle-agent
```

### Step 2: Install lifecycle-agent operator

```bash
oc apply -f https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/subscription-lca.yaml
oc -n openshift-lifecycle-agent get subscription,installplan,csv
oc -n openshift-lifecycle-agent rollout status deploy/lifecycle-agent-controller-manager
```

Confirm the deployment uses the expected image:

```bash
oc -n openshift-lifecycle-agent get deploy lifecycle-agent-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

### Step 3: Install cert-manager-operator

```bash
oc apply -f https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/subscription-cert-manager.yaml
oc -n cert-manager-operator get subscription,installplan,csv
oc -n cert-manager-operator rollout status deploy/cert-manager-operator-controller-manager
```

Create the singleton `CertManager` resource:

```bash
oc apply -f https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/cert-manager-cr.yaml
oc -n cert-manager get deploy,pods
oc -n cert-manager rollout status deploy/cert-manager
oc -n cert-manager rollout status deploy/cert-manager-webhook
oc -n cert-manager rollout status deploy/cert-manager-cainjector
```

### Step 4: Create test certificates (ECDSA and RSA)

Create self-signed ECDSA P-256, ECDSA P-384, and RSA-2048 certificates. These
cover the key formats exercised in the successful full-upgrade validation:

```bash
oc apply -f https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/test-certificates.yaml
oc -n cert-manager-poc wait --for=condition=Ready certificate/test-ecdsa --timeout=2m
oc -n cert-manager-poc wait --for=condition=Ready certificate/test-ecdsa-p384 --timeout=2m
oc -n cert-manager-poc wait --for=condition=Ready certificate/test-rsa --timeout=2m
oc -n cert-manager-poc get certificate
```

Record the private-key fingerprints before IBU. Compare these exact hashes
after the upgrade to detect an unexpected key replacement:

```bash
for secret in test-ecdsa-tls test-ecdsa-p384-tls test-rsa-tls; do
  printf '%s ' "$secret"
  oc -n cert-manager-poc get secret "$secret" \
    -o jsonpath='{.data.tls\.key}' | base64 -d | \
    openssl pkey -outform DER | openssl dgst -sha256
done | tee "$HOME/ibu-key-checksums.before"
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

Set `SEED_IMAGE` and `TARGET_VERSION` for your seed cluster, then apply the
`ImageBasedUpgrade` CR:

```bash
export SEED_IMAGE="quay.io/<your-repo>/ibu-seed:4.22.3"
export TARGET_VERSION="4.22.3"
```

```bash
cat <<EOF | oc apply -f -
apiVersion: lca.openshift.io/v1
kind: ImageBasedUpgrade
metadata:
  name: upgrade
  annotations:
    lca.openshift.io/recert-image: ${RECERT_IMAGE}
spec:
  stage: Prep
  seedImageRef:
    version: "${TARGET_VERSION}"
    image: "${SEED_IMAGE}"
  oadpContent:
  - name: oadp-backup-restore-cm
    namespace: openshift-adp
  autoRollbackOnFailure:
    initMonitorTimeoutSeconds: 1800
EOF
```

```bash
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

Confirm all three TLS secrets are present, their key fingerprints match the
pre-upgrade values, and their certificates still have the expected subjects:

```bash
for secret in test-ecdsa-tls test-ecdsa-p384-tls test-rsa-tls; do
  printf '%s ' "$secret"
  oc -n cert-manager-poc get secret "$secret" \
    -o jsonpath='{.data.tls\.key}' | base64 -d | \
    openssl pkey -outform DER | openssl dgst -sha256
done | tee "$HOME/ibu-key-checksums.after"
diff -u "$HOME/ibu-key-checksums.before" "$HOME/ibu-key-checksums.after"

oc -n cert-manager-poc get certificate
oc -n cert-manager-poc get secret test-ecdsa-tls test-ecdsa-p384-tls test-rsa-tls
for secret in test-ecdsa-tls test-ecdsa-p384-tls test-rsa-tls; do
  printf '%s ' "$secret"
  oc -n cert-manager-poc get secret "$secret" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | \
    openssl x509 -noout -subject -ext subjectAltName
done
oc -n cert-manager-poc get events --sort-by=.lastTimestamp
oc -n cert-manager-poc get certificaterequests
```

The three key fingerprints should match, certificates should remain `Ready`,
and there should be no post-upgrade reissuance. Review recent events and
CertificateRequests for unexpected issuance.

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

Set the env vars from the [Current image set](#current-image-set) section, then
follow Step 1 and Step 3 from Scenario A to apply the CatalogSource, Subscription,
and `CertManager` CR.

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

```bash
oc apply -f https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/consoleless-test-cert.yaml
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
Create it on a dedicated seed cluster before running Scenario A. Do not use the
RHACM hub as a seed: the seed cluster must not have RHACM or multicluster engine
installed. The seed's hardware, CPU topology, machine configuration, network
family, FIPS setting, registry configuration, and day-2 operators must match
the target as required by the IBU documentation. The seed must also have the
`varlibcontainers` partition configured during installation.

Before generating the image, detach the seed from ZTP / RHACM and verify the
seed-cluster requirements in the official IBU guide. In particular, the seed
must not contain PVCs, PersistentVolumes, or the OADP
`DataProtectionApplication`; those resources belong on the target cluster.
Remove any `LocalVolume` or
`LVMCluster` custom resource from the seed as applicable. After seed generation
completes, do not use that seed cluster again. Provision a fresh seed if another
image is needed.

Fetch the dedicated seed SNO kubeconfig through Succulent, then use it for the
seed preparation steps:

```bash
export SEED_ENV="my-seed-environment"
succulent-cli sno kubeconfig --env "$SEED_ENV"
export SEED_KUBECONFIG="$HOME/Downloads/succulent/$SEED_ENV/sno-kubeconfig"
```

1. Create a pull-secret for the registry on the seed cluster:

```bash
export KUBECONFIG="$SEED_KUBECONFIG"
export REGISTRY_AUTH_FILE="$HOME/.docker/config.json"

oc create secret generic seedgen \
  -n openshift-lifecycle-agent \
  --from-file=.dockerconfigjson="$REGISTRY_AUTH_FILE" \
  --type=kubernetes.io/dockerconfigjson
```

2. Edit the local `manifests/seedgenerator.yaml` with your registry and target
version, then apply that file:

```bash
oc apply -f manifests/seedgenerator.yaml
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
