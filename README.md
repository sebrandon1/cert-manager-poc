# cert-manager POC image builder

This private repository builds the current upstream branches of:

- `openshift/cert-manager-operator` (`master`)
- `openshift-kni/lifecycle-agent` (`main`)
- `rh-ecosystem-edge/recert` (`main`)

The workflow publishes immutable, multi-architecture images to the `bapalm`
namespace in Quay. It is manually dispatched so the source refs and resulting
tag are visible before a build starts.

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
produce a tag containing the UTC date and the three resolved source SHAs, or
provide an explicit tag.

The workflow publishes runtime images, OLM bundles, and multi-architecture
catalog images. The final image list and exact source commits are recorded in
the workflow summary.
