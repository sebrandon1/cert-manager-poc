# cert-manager POC image builder

This repository builds and publishes test images from the current upstream
branches of:

- [`openshift/cert-manager-operator`](https://github.com/openshift/cert-manager-operator) (`master`)
- [`openshift-kni/lifecycle-agent`](https://github.com/openshift-kni/lifecycle-agent) (`main`)
- [`rh-ecosystem-edge/recert`](https://github.com/rh-ecosystem-edge/recert) (`main`)

The workflow runs nightly at 06:00 UTC and can also be manually dispatched from
[Actions](../../actions). It resolves the source commits, builds `linux/amd64`
and `linux/arm64` images, publishes the operator bundles and catalogs, and
records the exact source commits in the workflow summary.

These images are for OpenShift hub/spoke and SNO testing only. They are not
production release artifacts.

## Current image set

The current build uses these readable tags from the [recert](https://quay.io/repository/bapalm/recert),
[Lifecycle Agent operator](https://quay.io/repository/bapalm/lifecycle-agent-operator),
[Lifecycle Agent bundle](https://quay.io/repository/bapalm/lifecycle-agent-operator-bundle),
[Lifecycle Agent catalog](https://quay.io/repository/bapalm/lifecycle-agent-operator-catalog),
[cert-manager operator](https://quay.io/repository/bapalm/cert-manager-operator),
[cert-manager bundle](https://quay.io/repository/bapalm/cert-manager-operator-bundle),
and [cert-manager catalog](https://quay.io/repository/bapalm/cert-manager-operator-catalog)
repositories:

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

## Optional: provision a ZTP hub and SNO spoke

If you already have a target SNO, skip provisioning and continue to
[Scenario A](#scenario-a-ecdsa-and-rsa-certificate-preservation-across-ibu).
If you want a dedicated ZTP hub and spoke for testing, follow the
[optional Succulent CLI provisioning guide](docs/ztp-hub-spoke-setup.md).

---

## Scenario A: ECDSA and RSA certificate preservation across IBU

This scenario validates that [cert-manager](https://cert-manager.io/docs/)-issued
[Certificate resources](https://cert-manager.io/docs/usage/certificate/) for
ECDSA and RSA survive an image-based upgrade. It exercises both
[cert-manager-operator PR #424](https://github.com/openshift/cert-manager-operator/pull/424)
(consoleless support) and
[recert PR #1758](https://github.com/rh-ecosystem-edge/recert/pull/1758)
(ECDSA PKCS#8 handling during post-pivot recert).
For background on the failure mode and the original end-to-end validation, see
the [cert-manager certificate preservation investigation](https://gist.github.com/sebrandon1/9c93733b4a0b2ea8dec0784b0c253209).

### Prerequisites

- A SNO spoke using an OCP source and target version supported by the selected
  Lifecycle Agent and seed image. This flow has been exercised end-to-end from
  OCP 4.20.2 to 4.22.3.
- A compatible seed image at the target version (see
  [Seed image creation](#seed-image-creation)). The seed cluster must match the
  target's [hardware and configuration requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#seed-image-guidelines).
- A dedicated `/var/lib/containers` partition on both seed and target, created
  at install time with the `varlibcontainers` partition label, as described in
  the [IBU partition requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#configuring-a-shared-container-partition-for-the-image-based-upgrade).
- [OADP / Velero](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/backup_and_restore/index#oadp-application-backup-and-restore), a configured `DataProtectionApplication`, an accessible
  [S3-compatible backup bucket](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/backup_and_restore/oadp-application-backup-and-restore#configuring-oadp-with-aws-s3-compatible-storage), and backup and restore resources on the target
  spoke.
- A Lifecycle Agent version compatible with the one used to generate the seed;
  see the [minimum component versions](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#minimum-software-version-of-components).
- If RHACM manages the target, the hub must be at least as new as the IBU
  target release, as described in the [hub cluster guidelines](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#hub-cluster-guidelines).
- `oc` logged in with cluster-admin privileges.

Read the [OpenShift IBU preparation and upgrade guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters)
for the complete version-specific requirements, including the
[seed image guidelines](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#seed-image-guidelines)
and [OADP backup and restore requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#oadp-backup-and-restore-guidelines). In particular, the shared
container partition must be present when the seed and target clusters are
installed; adding it after provisioning does not satisfy this prerequisite.

Set `KUBECONFIG` to the target SNO's cluster-admin kubeconfig before running
these commands. If you followed the optional ZTP setup guide, use
`export KUBECONFIG="$SPOKE_KUBECONFIG"`; otherwise, point it at your existing
SNO kubeconfig.

```bash
oc whoami
oc version
```

### Step 1: Set up CatalogSources and namespaces

Set the env vars from the [Current image set](#current-image-set) section above,
then apply the [catalog sources, namespaces, and operator groups manifest](manifests/catalogs-and-namespaces.yaml):

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

The [Lifecycle Agent subscription manifest](manifests/subscription-lca.yaml)
installs the operator:

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

Apply the [cert-manager subscription](manifests/subscription-cert-manager.yaml)
and [operator configuration](manifests/cert-manager-cr.yaml):

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

Use the [ECDSA and RSA test certificate manifest](manifests/test-certificates.yaml)
to create self-signed ECDSA P-256, ECDSA P-384, and RSA-2048 certificates.
These cover the key formats exercised in the successful full-upgrade validation:

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

Follow the [Lifecycle Agent image-based upgrade procedure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#performing-an-image-based-upgrade-for-single-node-openshift-clusters-with-the-lifecycle-agent).

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

Issue a test certificate using the [consoleless test manifest](manifests/consoleless-test-cert.yaml)
to confirm core functionality:

```bash
oc apply -f https://raw.githubusercontent.com/sebrandon1/cert-manager-poc/main/manifests/consoleless-test-cert.yaml
oc -n cert-manager-poc wait --for=condition=Ready certificate/consoleless-test --timeout=2m
oc -n cert-manager-poc get certificate consoleless-test -o wide
oc -n cert-manager-poc get secret consoleless-test-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
```

A `Ready=True` [Certificate](https://cert-manager.io/docs/usage/certificate/)
and a valid x509 subject confirm that cert-manager operates correctly with no
console present. See [cert-manager-operator PR #424](https://github.com/openshift/cert-manager-operator/pull/424)
for the consoleless support under test.

---

## Seed image creation

The IBU seed image is a snapshot of a running SNO at the target OCP version.
Create it on a dedicated seed cluster before running Scenario A. The seed
cluster must not have RHACM or multicluster engine installed, and it must meet
the official [image-based installation seed requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-installation-for-single-node-openshift).
Its hardware, CPU topology, machine configuration, network family, FIPS
setting, registry configuration, and day-2 operators must match the target as
required by the [IBU seed image guidelines](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#seed-image-guidelines).
The seed must also have the `varlibcontainers` partition configured during
installation.

Before generating the image, detach the seed from ZTP / RHACM and verify the
[seed image generation procedure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#generating-a-seed-image-for-the-image-based-upgrade-with-the-lifecycle-agent).
Do not configure persistent volumes or an OADP
[`DataProtectionApplication`](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#seed-image-configuration)
on the seed. Remove any `LocalVolume` or `LVMCluster` custom resource from the
seed as applicable.

Fetch the dedicated seed SNO kubeconfig through
[Succulent CLI](https://github.com/sebrandon1/succulent-cli) using its
[`sno kubeconfig` command](https://github.com/sebrandon1/succulent-cli/blob/main/docs/commands.md#sno-kubeconfig),
then use it for the seed preparation steps:

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

2. Edit the local [SeedGenerator manifest](manifests/seedgenerator.yaml) with
your registry and target version, then apply that file:

```bash
oc apply -f manifests/seedgenerator.yaml
oc get seedgenerator seedimage -w
```

The seed cluster reboots during image creation (~15–20 minutes). The node
returns to normal operation after the image is pushed.

---

## Building custom images

To build images from feature branches or pull requests, dispatch the
[GitHub Actions workflow](.github/workflows/build-images.yml) manually. See the
[`gh workflow run` reference](https://cli.github.com/manual/gh_workflow_run):

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

Monitor progress with the [`gh run list`](https://cli.github.com/manual/gh_run_list)
and [`gh run view`](https://cli.github.com/manual/gh_run_view) commands, then
copy the image references from the completed workflow summary:

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
the operator service accounts as described in the OpenShift
[image pull secret documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/managing-images#using-image-pull-secrets):

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
