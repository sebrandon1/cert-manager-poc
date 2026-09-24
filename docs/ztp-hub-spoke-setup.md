# Optional: prepare a ZTP hub and SNO spoke

Use this guide only if you need a dedicated ZTP hub and spoke for testing. If
you already have a target SNO, skip these provisioning steps and continue to
[Scenario A in the main guide](../README.md#scenario-a-ecdsa-and-rsa-certificate-preservation-across-ibu).
The process uses [Succulent CLI](https://github.com/sebrandon1/succulent-cli)
with a ZTP environment plan. For general OpenShift GitOps ZTP concepts, see the
[OCP 4.22 managed cluster installation guide](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/ztp-deploying-far-edge-sites#installing-managed-clusters-with-rhacm-and-clusterinstance-resources).


Use [succulent-cli](https://github.com/sebrandon1/succulent-cli) to inspect the
plan, submit a ZTP hub-and-spoke provisioning request, and retrieve each
cluster's kubeconfig. Install the CLI using its
[installation guide](https://github.com/sebrandon1/succulent-cli/blob/main/docs/installation.md).
See the [ZTP command reference](https://github.com/sebrandon1/succulent-cli/blob/main/docs/commands.md#ztp-provision)
for available flags. The current implementation requires `--confirm` even with
`--dry-run` (see the [provision command](https://github.com/sebrandon1/succulent-cli/blob/main/cmd/ztp.go)).
Set the plan name and exact hub and spoke build tags assigned to your
environment:

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
the request first; `--dry-run` prevents submission:

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

Monitor the environment with Succulent CLI's [`get log`](https://github.com/sebrandon1/succulent-cli/blob/main/docs/commands.md#get-log)
and [`watch`](https://github.com/sebrandon1/succulent-cli/blob/main/docs/commands.md#watch)
commands while the [GitOps ZTP pipeline](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/ztp-deploying-far-edge-sites)
provisions the clusters:

```bash
succulent-cli get log --env "$ZTP_ENV" | tail -n 30
succulent-cli watch --env "$ZTP_ENV"
```

If the spoke needs an installation-time GitOps change before deployment, the
CLI supports `--stop-before-deployment` so the request can pause for that work.
Apply the environment's GitOps changes and resume its deployment through the
documented plan workflow before continuing. For example, the IBU container
partition must be configured at installation time; see the
[OCP 4.22 shared partition procedure for GitOps ZTP](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/image-based-upgrade-for-single-node-openshift-clusters#configuring-a-shared-container-directory-between-ostree-stateroots-when-using-gitops-ztp) and the
[IBU prerequisites in the main guide](../README.md#scenario-a-ecdsa-and-rsa-certificate-preservation-across-ibu).

Retrieve and check both credentials separately using the [ZTP kubeconfig command](https://github.com/sebrandon1/succulent-cli/blob/main/docs/commands.md#ztp-kubeconfig).
The `management` choice is the hub; `spoke` is the target SNO:

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
[`ManagedCluster`](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/edge_computing/ztp-deploying-far-edge-sites#installing-managed-clusters-with-rhacm-and-clusterinstance-resources)
conditions for `Available=True`. If kubeconfig retrieval returns an invalid
file or `oc whoami` fails, fix access before continuing. Use the spoke
kubeconfig for Scenario A:

```bash
export KUBECONFIG="$SPOKE_KUBECONFIG"
```
