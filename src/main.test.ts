import { beforeEach, describe, expect, it, vi } from "vitest";
import { HttpClient } from "@actions/http-client";
import * as core from "@actions/core";
import { run } from "./main.js";

// --- mocks ---

vi.mock("@actions/core", () => ({
  getInput: vi.fn(),
  setOutput: vi.fn(),
  setFailed: vi.fn(),
  setSecret: vi.fn(),
  info: vi.fn(),
}));

const getJsonMock = vi.fn();
vi.mock("@actions/http-client", () => ({
  HttpClient: vi.fn(),
}));

// --- helpers ---

function mockInputs(overrides: Record<string, string> = {}) {
  const defaults: Record<string, string> = {
    host: "coolify.example.com",
    token: "test-token",
    uuid: "app-uuid-123",
    "pr-number": "",
  };
  vi.mocked(core.getInput).mockImplementation(
    (name: string) => overrides[name] ?? defaults[name] ?? ""
  );
}

function makeDeployResponse(deploymentUuid = "deploy-uuid-abc") {
  return { result: { deployment_uuid: deploymentUuid } };
}

function makeStatusResponse(status: string) {
  return { result: { status } };
}

// --- tests ---

describe("run", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    vi.useFakeTimers();
    vi.mocked(HttpClient).mockImplementation(
      class {
        getJson = getJsonMock;
      } as unknown as typeof HttpClient
    );
  });

  it("triggers a deployment and waits until finished", async () => {
    mockInputs();
    getJsonMock
      .mockResolvedValueOnce(makeDeployResponse())
      .mockResolvedValueOnce(makeStatusResponse("in_progress"))
      .mockResolvedValueOnce(makeStatusResponse("finished"));

    const runPromise = run();
    await vi.runAllTimersAsync();
    await runPromise;

    expect(core.setOutput).toHaveBeenCalledWith("deployment-uuid", "deploy-uuid-abc");
    expect(core.setFailed).not.toHaveBeenCalled();
    expect(core.info).toHaveBeenCalledWith("Deployment succeeded.");
  });

  it("appends pull_request_id for preview deployments", async () => {
    mockInputs({ "pr-number": "42" });
    getJsonMock
      .mockResolvedValueOnce(makeDeployResponse())
      .mockResolvedValueOnce(makeStatusResponse("finished"));

    const runPromise = run();
    await vi.runAllTimersAsync();
    await runPromise;

    const deployUrl = getJsonMock.mock.calls[0][0] as string;
    expect(deployUrl).toContain("pull_request_id=42");
    expect(core.setFailed).not.toHaveBeenCalled();
  });

  it("does not append pull_request_id when pr-number is empty", async () => {
    mockInputs({ "pr-number": "" });
    getJsonMock
      .mockResolvedValueOnce(makeDeployResponse())
      .mockResolvedValueOnce(makeStatusResponse("finished"));

    const runPromise = run();
    await vi.runAllTimersAsync();
    await runPromise;

    const deployUrl = getJsonMock.mock.calls[0][0] as string;
    expect(deployUrl).not.toContain("pull_request_id");
  });

  it.each(["failed", "error", "cancelled"])(
    "calls setFailed when deployment status is %s",
    async (status) => {
      mockInputs();
      getJsonMock
        .mockResolvedValueOnce(makeDeployResponse())
        .mockResolvedValueOnce(makeStatusResponse(status));

      const runPromise = run();
      await vi.runAllTimersAsync();
      await runPromise;

      expect(core.setFailed).toHaveBeenCalledWith(`Deployment failed with status: ${status}`);
    }
  );

  it("calls setFailed on timeout after max attempts", async () => {
    mockInputs();
    getJsonMock
      .mockResolvedValueOnce(makeDeployResponse())
      .mockResolvedValue(makeStatusResponse("in_progress"));

    const runPromise = run();
    await vi.runAllTimersAsync();
    await runPromise;

    expect(core.setFailed).toHaveBeenCalledWith("Timed out waiting for deployment to finish.");
  });

  it("calls setFailed when Coolify returns no deployment UUID", async () => {
    mockInputs();
    getJsonMock.mockResolvedValueOnce({ result: {} });

    const runPromise = run();
    await vi.runAllTimersAsync();
    await runPromise;

    expect(core.setFailed).toHaveBeenCalledWith(
      expect.stringContaining("Unexpected response from Coolify deploy endpoint")
    );
  });

  it("masks the token as a secret", async () => {
    mockInputs();
    getJsonMock
      .mockResolvedValueOnce(makeDeployResponse())
      .mockResolvedValueOnce(makeStatusResponse("finished"));

    const runPromise = run();
    await vi.runAllTimersAsync();
    await runPromise;

    expect(core.setSecret).toHaveBeenCalledWith("test-token");
  });
});
