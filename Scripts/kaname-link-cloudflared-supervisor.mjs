#!/usr/bin/env node

import { spawn as nodeSpawn } from "node:child_process";
import process from "node:process";
import { pathToFileURL } from "node:url";

import {
  RuntimeDeliveryError,
  loadRuntimeManifest,
  normalizeRuntimeManifest,
  verifyPinnedRuntime,
} from "./kaname-link-cloudflared-runtime.mjs";
import { parseOptionPairs } from "./kaname-link-delivery-common.mjs";

const MAX_TOKEN_BYTES = 8192;
const CHILD_ENVIRONMENT_ALLOWLIST = new Set([
  "HOME",
  "LANG",
  "LC_ALL",
  "LOCALAPPDATA",
  "LOGNAME",
  "PATH",
  "PROGRAMDATA",
  "SSL_CERT_DIR",
  "SSL_CERT_FILE",
  "SYSTEMROOT",
  "TEMP",
  "TMP",
  "TMPDIR",
  "TZ",
  "USER",
  "WINDIR",
]);

export class SupervisorError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    this.name = "SupervisorError";
    this.code = code;
  }
}

function fail(code, message, options) {
  throw new SupervisorError(code, message, options);
}

export async function readTunnelToken(readable) {
  if (!readable || typeof readable[Symbol.asyncIterator] !== "function") {
    fail("invalid_token_pipe", "tunnel token input must be an anonymous readable pipe");
  }
  const chunks = [];
  let total = 0;
  for await (const chunk of readable) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += bytes.length;
    if (total > MAX_TOKEN_BYTES + 1) {
      fail("invalid_tunnel_token", "tunnel token exceeds the maximum accepted length");
    }
    chunks.push(bytes);
  }
  let token = Buffer.concat(chunks).toString("utf8");
  if (token.endsWith("\n")) token = token.slice(0, -1);
  if (token.endsWith("\r")) token = token.slice(0, -1);
  if (
    token.length < 20 ||
    token.length > MAX_TOKEN_BYTES ||
    !/^[A-Za-z0-9._~+/=-]+$/.test(token)
  ) {
    fail(
      "invalid_tunnel_token",
      "tunnel token must be a single printable token delivered only through the anonymous pipe",
    );
  }
  return token;
}

export function createChildEnvironment(baseEnvironment, token) {
  const environment = {};
  for (const [name, value] of Object.entries(baseEnvironment ?? {})) {
    if (
      typeof value === "string" &&
      CHILD_ENVIRONMENT_ALLOWLIST.has(name.toUpperCase())
    ) {
      environment[name] = value;
    }
  }
  environment.TUNNEL_TOKEN = token;
  return environment;
}

export function createConnectorLaunchSpec({ manifest: manifestInput, token, baseEnvironment = {} }) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  if (typeof token !== "string" || token.length < 20) {
    fail("invalid_tunnel_token", "a validated tunnel token is required");
  }
  const args = [...manifest.supervisor.arguments];
  if (
    args.some((argument) =>
      new Set(["--token", "--token-file", "token", token]).has(argument),
    ) ||
    args.some((argument) => argument.includes(token))
  ) {
    fail("unsafe_connector_arguments", "cloudflared arguments may not carry token material");
  }
  return {
    args,
    options: {
      env: createChildEnvironment(baseEnvironment, token),
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  };
}

export class SecretRedactor {
  constructor(secret, writable) {
    if (typeof secret !== "string" || secret.length === 0 || !writable?.write) {
      fail("invalid_redactor", "secret redactor requires a secret and writable output");
    }
    this.secret = secret;
    this.writable = writable;
    this.pending = "";
  }

  write(chunk) {
    this.pending += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
    const replaced = this.pending.replaceAll(this.secret, "[redacted]");
    const retainedLength = Math.min(this.secret.length - 1, replaced.length);
    const writeLength = replaced.length - retainedLength;
    if (writeLength > 0) this.writable.write(replaced.slice(0, writeLength));
    this.pending = replaced.slice(writeLength);
  }

  flush() {
    if (this.pending.length > 0) {
      this.writable.write(this.pending.replaceAll(this.secret, "[redacted]"));
      this.pending = "";
    }
  }
}

function waitForChild(child, abortSignal) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      abortSignal?.removeEventListener("abort", stopChild);
      callback(value);
    };
    const stopChild = () => {
      try {
        child.kill("SIGTERM");
      } catch {
        // The process may have exited between the signal and this callback.
      }
    };
    child.once("error", (error) => finish(reject, error));
    child.once("exit", (code, signal) => finish(resolve, { code, signal }));
    if (abortSignal?.aborted) stopChild();
    else abortSignal?.addEventListener("abort", stopChild, { once: true });
  });
}

export async function runConnectorOnce({
  manifest,
  binaryPath,
  token,
  baseEnvironment = process.env,
  stdout = process.stdout,
  stderr = process.stderr,
  spawnImpl = nodeSpawn,
  abortSignal,
}) {
  const launch = createConnectorLaunchSpec({ manifest, token, baseEnvironment });
  let child;
  try {
    child = spawnImpl(binaryPath, launch.args, launch.options);
  } catch (error) {
    fail("connector_spawn_failed", "unable to start the verified cloudflared binary", {
      cause: error,
    });
  }
  const stdoutRedactor = new SecretRedactor(token, stdout);
  const stderrRedactor = new SecretRedactor(token, stderr);
  child.stdout?.on("data", (chunk) => stdoutRedactor.write(chunk));
  child.stderr?.on("data", (chunk) => stderrRedactor.write(chunk));
  try {
    return await waitForChild(child, abortSignal);
  } catch (error) {
    fail("connector_spawn_failed", "verified cloudflared process failed to start", {
      cause: error,
    });
  } finally {
    stdoutRedactor.flush();
    stderrRedactor.flush();
  }
}

function defaultSleep(milliseconds, abortSignal) {
  return new Promise((resolve) => {
    if (abortSignal?.aborted) {
      resolve();
      return;
    }
    const timeout = setTimeout(resolve, milliseconds);
    abortSignal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timeout);
        resolve();
      },
      { once: true },
    );
  });
}

export async function superviseConnector({
  manifest: manifestInput,
  binaryPath,
  receiptPath,
  token,
  baseEnvironment = process.env,
  stdout = process.stdout,
  stderr = process.stderr,
  spawnImpl = nodeSpawn,
  sleepImpl = defaultSleep,
  abortSignal,
}) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  await verifyPinnedRuntime({ manifest, binaryPath, receiptPath });
  let restarts = 0;
  while (!abortSignal?.aborted) {
    const result = await runConnectorOnce({
      manifest,
      binaryPath,
      token,
      baseEnvironment,
      stdout,
      stderr,
      spawnImpl,
      abortSignal,
    });
    if (abortSignal?.aborted || result.code === 0) {
      return { ok: true, operation: "supervise", restarts, exit: result };
    }
    if (restarts >= manifest.supervisor.maximumConsecutiveRestarts) {
      fail(
        "connector_restart_limit",
        `cloudflared exceeded ${manifest.supervisor.maximumConsecutiveRestarts} consecutive restarts`,
      );
    }
    const delayIndex = Math.min(
      restarts,
      manifest.supervisor.restartDelaysMilliseconds.length - 1,
    );
    const delay = manifest.supervisor.restartDelaysMilliseconds[delayIndex];
    restarts += 1;
    stderr.write(`cloudflared exited without token output; restarting in ${delay} ms\n`);
    await sleepImpl(delay, abortSignal);
  }
  return { ok: true, operation: "supervise", restarts, exit: { code: null, signal: "abort" } };
}

function usage() {
  return `Usage:
  node Scripts/kaname-link-cloudflared-supervisor.mjs --binary ABSOLUTE_PATH --receipt ABSOLUTE_PATH [--manifest PATH]

The Kaname primary app must write the tunnel token to this process through an anonymous stdin pipe
and close the pipe. Interactive stdin, token arguments, token files, and pre-populated token
environment variables are rejected. The verified cloudflared child receives TUNNEL_TOKEN only in
its restricted environment; stdout and stderr are scrubbed before forwarding.`;
}

function parseArguments(argv) {
  if (argv.length === 0 || argv.includes("--help") || argv.includes("-h")) return { help: true };
  const options = { help: false, manifestPath: null, binaryPath: null, receiptPath: null };
  for (const [flag, value] of parseOptionPairs(argv, (message) =>
    fail("invalid_arguments", message),
  )) {
    if (flag === "--manifest") options.manifestPath = value;
    else if (flag === "--binary") options.binaryPath = value;
    else if (flag === "--receipt") options.receiptPath = value;
    else fail("invalid_arguments", `unknown option: ${flag}`);
  }
  if (!options.binaryPath || !options.receiptPath) {
    fail("invalid_arguments", "supervisor requires --binary and --receipt");
  }
  return options;
}

function safeError(error) {
  return {
    ok: false,
    error: {
      code: error?.code ?? "unexpected_error",
      message: error instanceof Error ? error.message : "unexpected failure",
    },
  };
}

export async function main({
  argv = process.argv.slice(2),
  env = process.env,
  stdin = process.stdin,
  stdout = process.stdout,
  stderr = process.stderr,
  abortController = new AbortController(),
} = {}) {
  try {
    const options = parseArguments(argv);
    if (options.help) {
      stdout.write(`${usage()}\n`);
      return 0;
    }
    if (env.TUNNEL_TOKEN || env.TUNNEL_TOKEN_FILE) {
      fail("unsafe_secret_source", "remove inherited tunnel token variables and use the anonymous pipe");
    }
    if (stdin.isTTY === true) {
      fail("invalid_token_pipe", "interactive stdin is forbidden for tunnel token delivery");
    }
    const manifest = await loadRuntimeManifest(options.manifestPath ?? undefined);
    const token = await readTunnelToken(stdin);
    const stop = () => abortController.abort();
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    try {
      const result = await superviseConnector({
        manifest,
        binaryPath: options.binaryPath,
        receiptPath: options.receiptPath,
        token,
        baseEnvironment: env,
        stdout,
        stderr,
        abortSignal: abortController.signal,
      });
      stdout.write(`${JSON.stringify(result)}\n`);
      return 0;
    } finally {
      process.removeListener("SIGINT", stop);
      process.removeListener("SIGTERM", stop);
    }
  } catch (error) {
    const normalized = error instanceof RuntimeDeliveryError ? error : error;
    stderr.write(`${JSON.stringify(safeError(normalized), null, 2)}\n`);
    return 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.exitCode = await main();
}
