import * as core from "@actions/core";
import { HttpClient } from "@actions/http-client";

interface DeployResponse {
  deployment_uuid: string;
}

interface DeploymentStatusResponse {
  status: string;
}

const TERMINAL_STATUSES = new Set(["finished", "failed", "error", "cancelled"]);
const POLL_INTERVAL_MS = 10_000;
const MAX_ATTEMPTS = 60;

export async function run(): Promise<void> {
  const host = core.getInput("host", { required: true });
  const token = core.getInput("token", { required: true });
  const uuid = core.getInput("uuid", { required: true });
  const prNumber = core.getInput("pr-number");

  core.setSecret(token);

  const client = new HttpClient("coolify-deploy-action", [], {
    headers: { Authorization: `Bearer ${token}` },
  });

  try {
    const deploymentUuid = await triggerDeploy(client, host, uuid, prNumber);
    core.setOutput("deployment-uuid", deploymentUuid);
    await pollUntilDone(client, host, deploymentUuid);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : "An unexpected error occurred");
  }
}

async function triggerDeploy(
  client: HttpClient,
  host: string,
  uuid: string,
  prNumber: string
): Promise<string> {
  let url = `https://${host}/api/v1/deploy?uuid=${uuid}`;
  if (prNumber) {
    url += `&pull_request_id=${prNumber}`;
  }

  const response = await client.getJson<DeployResponse>(url);

  if (!response.result?.deployment_uuid) {
    throw new Error(
      `Unexpected response from Coolify deploy endpoint: ${JSON.stringify(response.result)}`
    );
  }

  const deploymentUuid = response.result.deployment_uuid;
  core.info(`Coolify deployment UUID: ${deploymentUuid}`);
  return deploymentUuid;
}

async function pollUntilDone(
  client: HttpClient,
  host: string,
  deploymentUuid: string
): Promise<void> {
  for (let i = 1; i <= MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);

    const response = await client.getJson<DeploymentStatusResponse>(
      `https://${host}/api/v1/deployments/${deploymentUuid}`
    );

    const status = response.result?.status ?? "unknown";
    core.info(`[${i}/${MAX_ATTEMPTS}] Status: ${status}`);

    if (!TERMINAL_STATUSES.has(status)) continue;

    if (status === "finished") {
      core.info("Deployment succeeded.");
      return;
    }

    throw new Error(`Deployment failed with status: ${status}`);
  }

  throw new Error("Timed out waiting for deployment to finish.");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
