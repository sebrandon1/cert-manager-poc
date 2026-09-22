# cert-manager POC image builder

This private repository builds the current upstream branches of:

- `openshift/cert-manager-operator` (`master`)
- `openshift-kni/lifecycle-agent` (`main`)
- `rh-ecosystem-edge/recert` (`main`)

The workflow publishes immutable, multi-architecture images to the `bapalm`
namespace in Quay. It is manually dispatched so the source refs and resulting
tags are visible before a build starts.

## One-time setup

Add these repository secrets:

```text
QUAY_USERNAME
QUAY_TOKEN
```

`QUAY_TOKEN` must be allowed to push to the seven repositories used by the
workflow.

## Run a build

Open **Actions → Build and publish POC images → Run workflow**. The defaults
track the current upstream default branches. Leave `image_tag` as `auto` to
produce readable per-repository tags in the form `<ref>-<6-character-SHA>`.
For example, a run might publish `main-cb8304` for lifecycle-agent,
`main-78abf4` for recert, and `master-a5aacc` for cert-manager-operator. An
explicit `image_tag` applies the same override tag to every image.

The workflow publishes runtime images, OLM bundles, and multi-architecture
catalog images. The final image list and exact source commits are recorded in
the workflow summary.
