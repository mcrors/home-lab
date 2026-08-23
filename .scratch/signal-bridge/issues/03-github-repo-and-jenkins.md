Status: ready-for-human
Blocked by: 02

# M1: create GitHub repo and Jenkins pipeline

## Context

The subscriber image needs a build pipeline. A separate GitHub repo holds the image source. Jenkins builds the image and pushes it to GHCR. This ticket creates the repo and wires up the pipeline.

See `docs/alerting/signal-bridge-prd.md` section 7.1 (Image build).

## Scope

1. Create a new public GitHub repo named `signal-bridge`.
2. Push the four files from ticket 02 to the repo.
3. Create a Jenkins job pointing at the new repo using the DinD pipeline pattern (same as `arr-exporter`).
4. Trigger the first build.
5. Confirm the image appears in GHCR as `ghcr.io/<user>/signal-bridge:<sha>`.
6. Confirm the cluster can pull the image (run a throwaway pod or inspect pull behaviour from a node).

## Notes

- A public GHCR package needs no pull secret. Keep the package public to avoid adding an `imagePullSecret` to the `ntfy` namespace.
- Never push the `latest` tag. The Deployment references an exact SHA tag.

## Acceptance criteria

- The image exists in GHCR with a SHA tag.
- The cluster can pull the image without a pull secret.
- The Jenkins job builds on every push to the repo's main branch.
