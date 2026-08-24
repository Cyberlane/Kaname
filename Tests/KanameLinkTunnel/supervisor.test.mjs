import assert from "node:assert/strict";
import { Readable } from "node:stream";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  SecretRedactor,
  createConnectorLaunchSpec,
  readTunnelToken,
} from "../../Scripts/kaname-link-cloudflared-supervisor.mjs";
import { loadRuntimeManifest } from "../../Scripts/kaname-link-cloudflared-runtime.mjs";

const TEST_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(TEST_DIRECTORY, "../..");
const MANIFEST_PATH = path.join(
  REPOSITORY_ROOT,
  "Infrastructure",
  "KanameLinkTunnel",
  "cloudflared-runtime.json",
);
const TOKEN = "eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==";

test("supervisor accepts a tunnel token only from a single anonymous pipe value", async () => {
  const token = await readTunnelToken(Readable.from([TOKEN.slice(0, 13), TOKEN.slice(13), "\n"]));
  assert.equal(token, TOKEN);
  await assert.rejects(readTunnelToken(Readable.from(["too-short"])), {
    code: "invalid_tunnel_token",
  });
  await assert.rejects(readTunnelToken(Readable.from([`${TOKEN}\nsecond-value`])), {
    code: "invalid_tunnel_token",
  });
});

test("connector launch keeps token out of argv and strips unrelated parent secrets", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  const launch = createConnectorLaunchSpec({
    manifest,
    token: TOKEN,
    baseEnvironment: {
      PATH: "/usr/bin:/bin",
      HOME: "/private/runtime-home",
      CLOUDFLARE_API_TOKEN: "admin-token-must-not-reach-child",
      AWS_SECRET_ACCESS_KEY: "unrelated-parent-secret",
      TUNNEL_TOKEN_FILE: "/unsafe/token-file",
    },
  });
  assert.equal(JSON.stringify(launch.args).includes(TOKEN), false);
  assert.equal(launch.args.includes("--token"), false);
  assert.equal(launch.args.includes("--token-file"), false);
  assert.equal(launch.args.includes("--no-autoupdate"), true);
  assert.equal(launch.options.env.TUNNEL_TOKEN, TOKEN);
  assert.equal(launch.options.env.CLOUDFLARE_API_TOKEN, undefined);
  assert.equal(launch.options.env.AWS_SECRET_ACCESS_KEY, undefined);
  assert.equal(launch.options.env.TUNNEL_TOKEN_FILE, undefined);
  assert.equal(launch.options.env.PATH, "/usr/bin:/bin");
  assert.deepEqual(launch.options.stdio, ["ignore", "pipe", "pipe"]);
});

test("supervisor log redactor removes token even when output splits it across chunks", () => {
  const output = {
    value: "",
    write(value) {
      this.value += value;
    },
  };
  const redactor = new SecretRedactor(TOKEN, output);
  redactor.write(`prefix ${TOKEN.slice(0, 9)}`);
  redactor.write(`${TOKEN.slice(9, 28)}`);
  redactor.write(`${TOKEN.slice(28)} suffix\n`);
  redactor.flush();
  assert.equal(output.value.includes(TOKEN), false);
  assert.match(output.value, /prefix \[redacted\] suffix/);
});
