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

## Prerequisites

- OpenShift 4.19 or newer, preferably a disposable SNO spoke.
- `oc` logged in with cluster-admin privileges.
- An ACM hub if using the hub/spoke deployment path.
- A Quay pull secret only if the repositories are private. The examples assume
  the images can be pulled anonymously.

The examples below use `SPOKE_KUBECONFIG` as a placeholder for the spoke
kubeconfig. Run the commands against the spoke unless a section says to use
the hub.

```bash
export KUBECONFIG="$SPOKE_KUBECONFIG"
oc whoami
oc version
```

## Install directly on a spoke

The catalogs contain the generated OLM bundles. Create the catalog sources,
operator namespaces, and operator groups first:

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

Apply it and wait for both catalogs to become ready:

```bash
oc apply -f catalogs-and-namespaces.yaml
oc -n openshift-marketplace get catalogsource \
  bapalm-cert-manager-poc bapalm-lifecycle-agent-poc
oc -n openshift-marketplace wait --for=condition=READY \
  catalogsource/bapalm-cert-manager-poc --timeout=5m
oc -n openshift-marketplace wait --for=condition=READY \
  catalogsource/bapalm-lifecycle-agent-poc --timeout=5m
oc -n openshift-marketplace get packagemanifest \
  cert-manager-operator lifecycle-agent
```

Install both operators through subscriptions. The cert-manager bundle exposes
`stable-v1` and `stable-v1.20`; the lifecycle-agent bundle exposes `alpha`.

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
---
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
oc apply -f subscriptions.yaml
oc -n cert-manager-operator get subscription,installplan,csv
oc -n openshift-lifecycle-agent get subscription,installplan,csv
oc -n cert-manager-operator get deploy,pods
oc -n openshift-lifecycle-agent get deploy,pods
```

The expected CSVs are `cert-manager-operator.v1.20.0` and
`lifecycle-agent.v5.1.0`. Confirm that the deployments resolve the intended
images before continuing:

```bash
oc -n cert-manager-operator get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
oc -n openshift-lifecycle-agent get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
```

## Optional private Quay pull credentials

If the POC repositories are private, create a registry secret on the spoke and
link it to the operator service accounts. Catalog sources may additionally
need the secret in `openshift-marketplace` and in `spec.secrets`.

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

Do not commit registry credentials to this repository or to ACM policies.

## Configure cert-manager

Create the singleton `CertManager` resource after the operator is healthy:

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
oc get certmanager cluster -o yaml
oc -n cert-manager get deploy,pods
```

For a consoleless functional check, issue an ECDSA certificate using a
self-signed issuer:

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
  name: ecdsa-test
  namespace: cert-manager-poc
spec:
  secretName: ecdsa-test-tls
  commonName: ecdsa-test.example.com
  dnsNames:
  - ecdsa-test.example.com
  issuerRef:
    name: selfsigned
    kind: Issuer
  privateKey:
    algorithm: ECDSA
    size: 256
```

```bash
oc apply -f ecdsa-certificate.yaml
oc -n cert-manager-poc wait --for=condition=Ready certificate/ecdsa-test --timeout=5m
oc -n cert-manager-poc get certificate ecdsa-test -o wide
oc -n cert-manager-poc get secret ecdsa-test-tls -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -text -noout
```

This validates cert-manager ECDSA issuance. The IBU validation below is the
separate test for recert's handling of cluster cryptographic material.

## Configure the recert image for IBU

`ImageBasedUpgrade` is cluster-scoped and LCA creates the singleton named
`upgrade`. Set the recert override before entering the `Prep` stage:

```bash
oc annotate imagebasedupgrade upgrade \
  lca.openshift.io/recert-image="$RECERT_IMAGE" --overwrite
oc get imagebasedupgrade upgrade -o yaml
```

If the recert repository is private, also set the pull-secret annotation to a
secret in `openshift-lifecycle-agent`:

```bash
oc annotate imagebasedupgrade upgrade \
  lca.openshift.io/recert-pull-secret=bapalm-quay-pull --overwrite
```

Confirm the annotation before starting an upgrade:

```bash
oc get imagebasedupgrade upgrade \
  -o jsonpath='{.metadata.annotations.lca\.openshift\.io/recert-image}{"\n"}'
```

Use the normal LCA seed-image and OADP prerequisites for the spoke. A minimal
test CR looks like this; replace the seed image and version with the image
prepared for the target OpenShift release:

```yaml
apiVersion: lca.openshift.io/v1
kind: ImageBasedUpgrade
metadata:
  name: upgrade
  annotations:
    lca.openshift.io/recert-image: quay.io/bapalm/recert:main-78abf4
spec:
  stage: Idle
  seedImageRef:
    version: 4.19.0
    image: quay.io/example/seed-image:4.19.0
  autoRollbackOnFailure: {}
```

Do not advance to `Prep` until the seed image, OADP content, pull secrets, and
extra manifests are ready. Observe the complete lifecycle with:

```bash
oc get imagebasedupgrade upgrade -o yaml
oc get imagebasedupgrade upgrade \
  -o jsonpath='{range .status.history[*]}{.stage}{"\t"}{.startTime}{"\t"}{.completionTime}{"\n"}{end}'
oc -n openshift-lifecycle-agent logs deploy/lifecycle-agent-controller-manager \
  -c manager --since=30m | tee lca-controller.log
```

## ECDSA validation during IBU

The recert change under test accepts both common PEM encodings for EC private
keys and normalizes them to PKCS#8 internally. Create local fixtures to verify
the two encodings used by the test procedure:

```bash
openssl ecparam -name prime256v1 -genkey -noout -out ecdsa-sec1.key
openssl pkcs8 -topk8 -nocrypt \
  -in ecdsa-sec1.key -out ecdsa-pkcs8.key
openssl pkey -in ecdsa-sec1.key -pubout -out ecdsa-public.pem
openssl pkey -in ecdsa-pkcs8.key -pubout -out ecdsa-pkcs8-public.pem
```

For an actual IBU test, the seed cluster must contain ECDSA-backed cluster
cryptographic material that recert will process. The standalone cert-manager
Secret above is useful for verifying certificate issuance, but it is not by
itself proof that recert processed a cluster certificate. Record the source
encoding, run the IBU through `Prep` and `Upgrade`, and verify the post-pivot
certificate/key material and recert logs on the target:

```bash
oc get imagebasedupgrade upgrade -o jsonpath='{.status.conditions}'
oc get imagebasedupgrade upgrade -o jsonpath='{.status.history}'
oc -n openshift-lifecycle-agent logs deploy/lifecycle-agent-controller-manager \
  -c manager --since=2h | rg -i 'recert|ecdsa|pkcs|postpivot|rollback'
```

If the upgrade fails, preserve the IBU YAML, LCA controller log, machine and
seed-generation logs, and the recert image tag before retrying or returning to
`Idle`.

## Hub/spoke deployment with ACM

The direct spoke resources above can be delivered through ACM. The hub-side
pattern is:

1. Put the `CatalogSource`, namespaces, `OperatorGroup`, `Subscription`, and
   operator configuration resources into an ACM `Policy` or `PolicyGenerator`
   input.
2. Bind the policy to a `Placement` selecting the intended SNO spokes.
3. Let ACM enforce the resources and verify the resulting CSVs on each spoke.

For a simple ACM policy, the spoke objects are placed inside a
`ConfigurationPolicy` under `spec.policy-templates`, and the policy is bound
to a Placement in the hub namespace:

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: cert-manager-lifecycle-agent-poc
  namespace: open-cluster-management
spec:
  remediationAction: enforce
  policy-templates:
  - objectDefinition:
      apiVersion: policy.open-cluster-management.io/v1
      kind: ConfigurationPolicy
      metadata:
        name: cert-manager-lifecycle-agent-poc-resources
      spec:
        remediationAction: enforce
        severity: medium
        object-templates:
        - complianceType: musthave
          objectDefinition:
            apiVersion: operators.coreos.com/v1alpha1
            kind: CatalogSource
            metadata:
              name: bapalm-cert-manager-poc
              namespace: openshift-marketplace
            spec:
              sourceType: grpc
              image: quay.io/bapalm/cert-manager-operator-catalog:master-a5aacc
        - complianceType: musthave
          objectDefinition:
            apiVersion: operators.coreos.com/v1alpha1
            kind: CatalogSource
            metadata:
              name: bapalm-lifecycle-agent-poc
              namespace: openshift-marketplace
            spec:
              sourceType: grpc
              image: quay.io/bapalm/lifecycle-agent-operator-catalog:main-cb8304
```

Add the namespace, OperatorGroup, Subscription, `CertManager`, and IBU
objects to the same policy or to separate policies with the same Placement.
Keep the catalog resources separate from operator configuration when possible;
this makes catalog failures easier to distinguish from operator failures.

On the hub, inspect policy compliance and managed-cluster placement:

```bash
oc -n open-cluster-management get policy cert-manager-lifecycle-agent-poc -o yaml
oc -n open-cluster-management get placement,placementbinding
oc get managedcluster
```

Then use the spoke kubeconfig and run the direct verification commands from
above. ACM compliance only proves that the manifests were delivered; the CSV,
deployment, cert-manager, and IBU checks prove that the operators actually
started and used the intended images.

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
oc -n cert-manager-operator get deploy -o yaml | rg 'image:'
oc -n openshift-lifecycle-agent get deploy -o yaml | rg 'image:'
```

To rebuild manually, dispatch the workflow with the desired source refs. Use
`auto` for the readable per-repository tags, then update the variables and
manifests in this README from the completed workflow summary. Scheduled runs
always use the upstream `main` branches for lifecycle-agent and recert and the
upstream `master` branch for cert-manager-operator.
