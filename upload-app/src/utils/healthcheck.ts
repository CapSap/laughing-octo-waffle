import { readDockerSecret } from "./readDockerSecret.js";

const SECRET_NAME = "upload_healthcheck_url";

let cachedUrl: string | null | undefined;

function healthcheckUrl(): string | null {
  if (cachedUrl === undefined) {
    try {
      cachedUrl = readDockerSecret(SECRET_NAME);
    } catch {
      // env fallback for local dev, mirroring the go service
      cachedUrl = process.env[SECRET_NAME.toUpperCase()]?.trim() || null;
    }
  }
  return cachedUrl;
}

/**
 * Signals the healthchecks.io dead-man's switch for the upload flow.
 * Success pings the check URL; failure pings <url>/fail so the alert fires
 * immediately instead of waiting for the check period to lapse.
 * The URL is optional monitoring config: if unset the ping is skipped, and
 * ping errors are logged only — monitoring must never break the upload path.
 */
export async function pingHealthcheck(failed: boolean): Promise<void> {
  const url = healthcheckUrl();
  if (!url) {
    console.log(`healthcheck ping skipped: ${SECRET_NAME} not configured`);
    return;
  }

  try {
    await fetch(failed ? `${url}/fail` : url, {
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    console.error("healthcheck ping failed:", e);
  }
}
