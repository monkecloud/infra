# Templates

Not applied by Flux — `clusters/tamarin/` is the only reconciled path. These are starting
points for a new app repo.

- `app-repo/` — the skeleton a new app repo starts from: its `CLAUDE.md`, the `deploy` and
  `troubleshoot` skills, `k8s/` (site, ingress, and an optional single-pod cache), and the
  GitHub Actions workflow that builds to `ghcr.io/monkecloud/<repo>` and commits the new tag
  back for Flux to pick up. It carries no credentials — those are applied from
  `clusters/tamarin/apps/`.
- `new-app-repo.sh <owner> <app> [domain] [dest]` — copies the skeleton and substitutes the
  names. Edit the skeleton and re-scaffold; do not edit generated repos or they drift.

Wiring a repo to Flux is not a template — an app's namespace and its Flux objects are real
resources. See `clusters/tamarin/apps/README.md`.
