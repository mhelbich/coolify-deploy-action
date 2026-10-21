# coolify-deploy-action

A composite GitHub Action that deploys a [Coolify](https://coolify.io) resource:

1. optionally sets environment variables on the resource (e.g. pin `IMAGE_TAG` to a release),
2. triggers a deployment,
3. waits for it to finish and fails the step if it doesn't succeed.

Plain bash, `curl` and `jq`. No build step, no Node runtime.

## Usage

```yaml
- uses: mhelbich/coolify-deploy-action@v2
  with:
    url: ${{ vars.COOLIFY_URL }}
    token: ${{ secrets.COOLIFY_TOKEN }}
    uuid: ${{ vars.COOLIFY_APP_UUID }}
    env: |
      IMAGE_TAG=${{ github.ref_name }}
```

Only the token is a secret. The URL and the resource UUID are not sensitive, and keeping them in
repository **variables** keeps them readable in logs.

## Inputs

| Input           | Required | Default | Description                                                                                 |
| --------------- | -------- | ------- | ------------------------------------------------------------------------------------------- |
| `url`           | yes      |         | Coolify base URL including scheme, e.g. `https://coolify.example.com`                       |
| `token`         | yes      |         | Coolify API token                                                                           |
| `uuid`          | yes      |         | UUID of the Coolify resource                                                                |
| `env`           | no       | `""`    | Newline-separated `KEY=value` pairs set before deploying. Each variable must already exist. |
| `wait`          | no       | `true`  | Wait for the deployment to finish. `false` returns right after triggering                   |
| `timeout`       | no       | `600`   | Seconds to wait before failing                                                              |
| `poll-interval` | no       | `10`    | Seconds between status checks                                                               |

## Outputs

| Output            | Description                 |
| ----------------- | --------------------------- |
| `deployment-uuid` | The Coolify deployment UUID |

## Coolify setup

- Settings → Advanced → **API Access** enabled.
- An API token (Keys & Tokens → API Tokens) with permission **`deploy`**, plus **`write`** when
  using `env`.
- Define every variable passed via `env` on the resource first. The action only calls Coolify's
  update endpoint (`PATCH`); creating variables through it is not supported or tested.

## How it works

| Step                | Request                                                             |
| ------------------- | ------------------------------------------------------------------- |
| Set each `env` pair | `PATCH /api/v1/applications/{uuid}/envs` with `{"key","value"}`     |
| Trigger             | `GET /api/v1/deploy?uuid={uuid}` → `deployments[0].deployment_uuid` |
| Wait                | `GET /api/v1/deployments/{deployment_uuid}` until a final status    |

Final statuses: `finished` succeeds; `failed` and `cancelled-by-user` fail the step. `queued` and
`in_progress` keep waiting. A failed status request is logged as a warning and retried until the
timeout. The result is written to the job summary.

Any other API error (wrong token, unknown UUID, missing variable) fails the step with Coolify's
response body in the log.

## Using it from a private repository

This repository is private. GitHub only lets other repositories use its action when Settings →
Actions → General → **Access** is set to "Accessible from repositories owned by the user".

## Development

```sh
bash test/run.sh                         # scenario tests against test/mock-coolify.py
shellcheck deploy.sh test/run.sh
```

CI runs both, plus actionlint and the action itself (`uses: ./`) against the mock.

### Releasing

1. Tag and push the exact version: `git tag v2.0.1 && git push origin v2.0.1`
2. Publish a GitHub release for that tag.

The release workflow then moves the major tag (`v2`) to the same commit, so `@v2` users get the
update.
