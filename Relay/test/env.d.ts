import type { D1Migration } from "cloudflare:test";

declare module "cloudflare:workers" {
  interface ProvidedEnv extends Env {
    RELAY_BEARER_TOKEN: string;
    TEST_MIGRATIONS: D1Migration[];
  }
}
