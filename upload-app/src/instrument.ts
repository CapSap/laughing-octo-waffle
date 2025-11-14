import * as Sentry from "@sentry/node";
// Ensure to call this before importing any other modules!

import { readDockerSecret } from "./utils/readDockerSecret";
const dsn = readDockerSecret("sentry_dsn");

Sentry.init({
  dsn: dsn,
  // Adds request headers and IP for users, for more info visit:
  // https://docs.sentry.io/platforms/javascript/guides/node/configuration/options/#sendDefaultPii
  sendDefaultPii: true,
  // Enable logs to be sent to Sentry
  enableLogs: true,
  tracesSampleRate: 1.0,
  serverName: "node upload app",
  release: "dev",
});
