import * as fs from "fs";
import * as path from "path";

/**
 * Reads a Docker Swarm secret from the file system.
 * Secrets are typically mounted by Docker Swarm at /run/secrets/<secret_name>.
 * @param secretName The name of the Docker secret (e.g., 'shopify_shop_domain').
 * @returns The content of the secret file as a string, trimmed of whitespace.
 * @throws Error if the secret file cannot be read.
 */
export function readDockerSecret(secretName: string): string {
  const secretPath = path.join("/run/secrets", secretName);
  try {
    const secretValue = fs.readFileSync(secretPath, "utf8").trim();
    return secretValue;
  } catch (error) {
    console.error(
      `Failed to read Docker secret '${secretName}' from '${secretPath}'.`
    );
    // In production, you might want to exit or throw a more specific error.
    // For local development, you might fallback to process.env for convenience
    // IF it's absolutely safe and you understand the security implications.
    // return process.env[secretName.toUpperCase()]; // Example fallback
    throw new Error(`Required secret '${secretName}' not found or unreadable.`);
  }
}
