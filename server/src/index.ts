import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Fastify, { type FastifyInstance } from "fastify";

interface PackageMetadata {
  version?: string;
}

export function getVersion(): string {
  const pkgPath = new URL("../package.json", import.meta.url);
  const raw = readFileSync(pkgPath, "utf8");
  const parsed = JSON.parse(raw) as PackageMetadata;
  return parsed.version ?? "0.0.0";
}

export function createApp(): FastifyInstance {
  return Fastify();
}

export function main(): void {
  console.log(getVersion());
}

const isEntrypoint =
  process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isEntrypoint) {
  main();
}
