# Templates

Not applied by Flux — `clusters/tamarin/` is the only reconciled path. These are starting
points to copy when a new project repo appears.

- `build-and-deploy.yml` — GitHub Actions workflow for a project repo. Builds, pushes to
  `ghcr.io/monkecloud/<repo>`, then commits the new tag into that repo's `k8s/`. Flux picks
  up the commit. The workflow never talks to the cluster, which is why no inbound network
  path is needed.
- `project-kustomization.example.yaml` — the `GitRepository` + `Kustomization` pair that
  makes Flux watch a project repo and apply it as the tenant.
