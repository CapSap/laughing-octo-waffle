import fs from "fs";
import path from "path";
import "dotenv/config";
import { getShopifyGraphqlClient, initShopify } from "./shop";

// test a local uploads folder
// const uploadsDir = "/uploads";
const uploadsDir = path.join(__dirname, "uploads");
fs.mkdir(uploadsDir, { recursive: true }, (err) => {
  if (err) {
    console.error("Error creating directory:", err);
  } else {
    console.log("Directory created successfully!");
  }
});

console.log(`Watching ${uploadsDir}...`);
const debounceDelay = 500; // milliseconds
const watchTimers: Record<string, NodeJS.Timeout> = {};

async function main() {
  try {
    await initShopify();
  } catch (e) {
    console.error("was not able to init shopify client", e);
  }

  fs.watch(uploadsDir, (eventType, filename) => {
    if (!filename) {
      console.log(`Change detected but no filename provided.`);
      return;
    }

    const fullPath = path.join(uploadsDir, filename);

    // proftpd's option HiddenStores writes files to a temp filename .in.*
    if (filename.startsWith(".in.")) {
      console.log(
        `Ignoring temporary file: ${filename} (prefix .in. detected)`
      );
      return;
    }

    // Clear any existing timer for this file
    if (watchTimers[filename]) {
      clearTimeout(watchTimers[filename]);
    }

    // Set a new timer
    watchTimers[filename] = setTimeout(() => {
      delete watchTimers[filename]; // Remove the timer once it fires

      fs.stat(fullPath, async (err, stats) => {
        if (err) {
          if (err.code === "ENOENT") {
            console.log(`File was deleted or renamed: ${filename}`);
          } else {
            console.error(`Error accessing ${filename}:`, err);
          }
          return;
        }

        if (stats.isFile()) {
          console.log(`Detected new file: ${filename}`);
          // make the query here
          const testQuery = `
            query {
              shop {
                name
                myshopifyDomain
              }
            }
          `;
          const client = getShopifyGraphqlClient();
          try {
            const result = await client.query({ data: { query: testQuery } });
            console.log(
              `Successfully queried shop details for ${filename}:`,
              result
            );

            // TODO: Replace with your actual file upload logic
            // (e.g., read file, stagedUploadsCreate, HTTP PUT, then another GraphQL mutation)
          } catch (e) {
            console.error(
              `Failed to process file ${filename} with Shopify API:`,
              e
            );
          }
        }
      });
    }, debounceDelay);
  });
}

main();
