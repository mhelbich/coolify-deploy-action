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

## Limitations

- `env` only works for Coolify **Applications** (including git-backed Docker Compose
  applications): it uses the applications API. Triggering and waiting work for any resource UUID
  that `/api/v1/deploy` accepts.
- Variables are updated, not created (see Coolify setup).
- Tested against a self-hosted Coolify v4 (beta) instance. The API calls used are listed in the
  table above; if a Coolify release changes them, this action needs an update.

## Versions

Use `@v2`, which follows the latest `v2.x.y`, or pin a full commit SHA. There is no usable `v1`:
the first, JavaScript-based version never worked against a real Coolify instance and has been
removed.

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

## License

[MIT](LICENSE)
