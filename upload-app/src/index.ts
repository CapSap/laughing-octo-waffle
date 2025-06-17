import fs from "fs";
import { readFile } from "fs/promises";
import path from "path";
import "dotenv/config";
import { getShopifyGraphqlClient, initShopify } from "./shop";
import { fileURLToPath } from "url";
import { dirname } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));

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
          /* 3 step process:
          1. generate the upload url via stagedUploadsCreate
          2. upload via http post
          3. "register" the file on the Files API via fileCreate (and overwrite the existing file)
          */
          // shared variables across scoped try blocks
          let client;
          let uploadUrl;
          let params: { name: string; value: string }[];
          // stagedUploads graphql setup (so we can get the url we can upload to)
          const stagedUploadsCreateMutation = `
              mutation stagedUploadsCreate($input: [StagedUploadInput!]!) {
                stagedUploadsCreate(input: $input) {
                  stagedTargets {
                    url
                    resourceUrl
                    parameters {
                      name
                      value
                    }
                  }
                  userErrors {
                    field
                    message
                  }
                }
              }
            `;
          const variables = {
            input: [
              {
                resource: "BULK_MUTATION_VARIABLES", // or "IMAGE" etc.
                filename: filename,
                mimeType: "text/csv",
                fileSize: stats.size.toString(), // size in bytes
              },
            ],
          };

          try {
            client = getShopifyGraphqlClient();
            const response = await client.request(stagedUploadsCreateMutation, {
              variables: variables,
              retries: 2,
            });
            console.log("Staged upload response:");
            console.dir(response.data, { depth: null, colors: true });

            // set url and params
            uploadUrl = response.data.stagedUploadsCreate.stagedTargets[0].url;
            params =
              response.data.stagedUploadsCreate.stagedTargets[0].parameters;

            console.log("Extensions:");
            console.dir(response.extensions, { depth: null, colors: true });
          } catch (e) {
            console.error(
              `Failed to process file ${filename} with Shopify API:`,
              e
            );
            return;
          }
          // setup for fetch
          const formData = new FormData();
          params.forEach((param) => {
            formData.append(param.name, param.value);
          });
          // Read your file into a buffer
          const fileBuffer = await readFile(fullPath);
          const file = new File([fileBuffer], filename, { type: "text/csv" });
          formData.append("file", file);

          try {
            const response = await fetch(uploadUrl, {
              method: "POST",
              body: formData,
            });
          } catch (e) {
            console.error(
              `Failed to upload file ${filename} via http fetch:`,
              e
            );
          }
        }
      });
    }, debounceDelay);
  });
}

main();
