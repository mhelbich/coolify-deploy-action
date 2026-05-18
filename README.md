# coolify-deploy-action

A GitHub Action that triggers a [Coolify](https://coolify.io) deployment and waits for it to finish before the workflow step completes. Supports both production and pull request preview deployments.

## Usage

```yaml
- uses: mhelbich/coolify-deploy-action@v1
  with:
    host: ${{ secrets.COOLIFY_HOST }}
    token: ${{ secrets.COOLIFY_API_TOKEN }}
    uuid: ${{ secrets.COOLIFY_APP_UUID }}
```

### Preview deployment (pull requests)

Pass `pr-number` to trigger a Coolify PR preview deployment instead of the main deployment:

```yaml
- uses: mhelbich/coolify-deploy-action@v1
  with:
    host: ${{ secrets.COOLIFY_HOST }}
    token: ${{ secrets.COOLIFY_API_TOKEN }}
    uuid: ${{ secrets.COOLIFY_APP_UUID }}
    pr-number: ${{ github.event.pull_request.number }}
```

## Inputs

| Input       | Required | Description                                                  |
| ----------- | -------- | ------------------------------------------------------------ |
| `host`      | yes      | Coolify host, e.g. `coolify.example.com`                     |
| `token`     | yes      | Coolify API token                                            |
| `uuid`      | yes      | UUID of the Coolify application to deploy                    |
| `pr-number` | no       | Pull request number — triggers a preview deployment when set |

## Outputs

| Output            | Description                                                                       |
| ----------------- | --------------------------------------------------------------------------------- |
| `deployment-uuid` | The Coolify deployment UUID, useful for linking to the deployment in Coolify's UI |

## How it works

1. Calls `GET /api/v1/deploy?uuid=<uuid>` (with `&pull_request_id=<n>` for previews) to trigger the deployment and receive a `deployment_uuid`.
2. Polls `GET /api/v1/deployments/<deployment_uuid>` every 10 seconds until the status is one of `finished`, `failed`, `error`, or `cancelled` — or until 60 attempts (10 minutes) have elapsed.
3. Exits successfully on `finished`, fails the step on any other terminal status or timeout.

This means the workflow step only completes once Coolify has actually finished deploying, giving you accurate deployment status in GitHub rather than just confirming the webhook was received.

## Full example workflow

```yaml
name: CI / Deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6
      - name: Set up Node
        uses: actions/setup-node@v6
        with:
          node-version: 24
          cache: npm
      - name: Install dependencies
        run: npm ci
      - name: Lint
        run: npm run lint
      - name: Build
        run: npm run build

  deploy-production:
    needs: ci
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://example.com
    steps:
      - uses: mhelbich/coolify-deploy-action@v1
        with:
          host: ${{ secrets.COOLIFY_HOST }}
          token: ${{ secrets.COOLIFY_API_TOKEN }}
          uuid: ${{ secrets.COOLIFY_APP_UUID }}

  deploy-preview:
    needs: ci
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    environment:
      name: preview
      url: https://${{ github.event.pull_request.number }}.preview.example.com
    steps:
      - uses: mhelbich/coolify-deploy-action@v1
        with:
          host: ${{ secrets.COOLIFY_HOST }}
          token: ${{ secrets.COOLIFY_API_TOKEN }}
          uuid: ${{ secrets.COOLIFY_APP_UUID }}
          pr-number: ${{ github.event.pull_request.number }}
```

## Development

### Prerequisites

- Node.js 24+

### Setup

```sh
npm install
```

### Build

Compiles `src/` and bundles everything into `dist/index.js` via Rollup:

```sh
npm run package
```

Run formatting and then build in one step:

```sh
npm run bundle
```

The `dist/` directory is committed to the repository. The CI workflow verifies that the committed `dist/` matches what would be built from source — if you change `src/`, run `npm run bundle` and commit both.

### Releasing

Releases use semantic version tags (e.g. `v1.0.0`). A release workflow automatically keeps the major version tag (e.g. `v1`) pointing at the latest release in that major, so consumers using `@v1` always get the latest compatible version without updating their workflows.

To release:

1. Push the exact version tag:
   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```
2. Go to the repo on GitHub → **Releases** → **Draft a new release**
3. Select the tag you just pushed, add release notes, and click **Publish release**

Publishing the release triggers the release workflow, which automatically force-updates the `v1` major tag to point at the same commit.

### Project structure

```
src/
  index.ts    — entrypoint, calls run()
  main.ts     — all logic: trigger deploy, poll for status
dist/         — compiled bundle (committed)
action.yml    — action metadata, inputs, outputs
rollup.config.ts
tsconfig.json
```
