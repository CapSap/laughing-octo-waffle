import fs from "fs";
import { readFile } from "fs/promises";
import path from "path";
import "dotenv/config";
import { fileURLToPath } from "url";
import { dirname } from "path";

import { uploadsDir } from "./utils/config.js";

import { getShopifyGraphqlClient, initShopify } from "./shop.js";
import { cleanupOldFiles } from "./utils/cleanup.js";

fs.mkdir(uploadsDir, { recursive: true }, (err) => {
  if (err) {
    console.error("Error creating uploads directory:", err);
  } else {
    console.log("uploads Directory created successfully!");
  }
});

// run the cleanup func every day, remove files older than 30 days
const CLEANUP_INTERVAL_MS = 24 * 60 * 60 * 1000; // every 24 hours
setInterval(cleanupOldFiles, CLEANUP_INTERVAL_MS);

console.log(`Watching ${uploadsDir}...`);
const debounceDelay = 500; // milliseconds
const watchTimers: Record<string, NodeJS.Timeout> = {};

async function main() {
  // id of file uploaded to eb
  let lastUploadedFileId: string | null = null;

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
          1. generate the upload url via stagedUploadsCreate. 
          (we cant upload files directly because we're uploading to a shopify controlled cdn. Shopify wants to safely handle file uploads)
          2. upload via http post on the returned url from above
          3. "register" the file (make the file avaliable to our shopify store) on the Files API via fileCreate (and overwrite the existing file)
          */
          // shared variables across scoped try blocks
          let client;
          let uploadUrl;
          let shopifyResourceUrl;
          let params: { name: string; value: string }[];

          // init the client
          try {
            client = getShopifyGraphqlClient();
          } catch (e) {
            console.error("not able to get a shopify graphql client", e);
            return;
          }

          if (lastUploadedFileId !== null) {
            console.log("Deleting previous file:", lastUploadedFileId);

            // Example delete mutation here
            const deleteFileMutation = `
              mutation fileDelete($fileIds: [ID!]!) {
                fileDelete(fileIds: $fileIds) {
                  deletedFileIds
                  userErrors {
                    field
                    message
                  }
                }
              }
            `;

            const deleteFileVariables = {
              fileIds: [lastUploadedFileId],
            };

            try {
              const deleteResponse = await client.request(deleteFileMutation, {
                variables: deleteFileVariables,
              });
              console.log("File delete response:");
              console.dir(deleteResponse, { depth: null, colors: true });
            } catch (e) {
              console.error("Failed to delete previous file:", e);
            }
          }

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
                resource: "FILE", // or "IMAGE" etc.
                filename: "eb-soh.csv",
                mimeType: "text/csv",
                fileSize: stats.size.toString(), // size in bytes
                httpMethod: "POST",
              },
            ],
          };

          try {
            const response = await client.request(stagedUploadsCreateMutation, {
              variables: variables,
              retries: 2,
            });
            console.log("Staged upload response:");
            console.dir(response.data, { depth: null, colors: true });

            // set url and params
            const stagedTargets =
              response.data.stagedUploadsCreate.stagedTargets[0];
            uploadUrl = stagedTargets.url;
            shopifyResourceUrl = stagedTargets.resourceUrl;
            params = stagedTargets.parameters;

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
          const file = new File([fileBuffer], filename);
          const blob = new Blob([fileBuffer], { type: "text/csv" }); // optional mime type
          // formData.append("file", file, filename);
          // formData.append("file", fileBuffer);
          formData.append("file", blob, "eb-soh.csv");

          try {
            const response = await fetch(uploadUrl, {
              method: "POST",
              body: formData,
            });
            console.log("fetch response");
            console.log("Status:", response.status);
            console.log("Status Text:", response.statusText);
            console.log("OK:", response.ok);
            console.log("Headers:");
            for (const [key, value] of response.headers.entries()) {
              console.log(`  ${key}: ${value}`);
            }
            const responseText = await response.text();
            console.log("Response Body:", responseText);
            if (!response.ok) {
              console.error(
                `Upload failed with status ${response.status}: ${response.statusText}`
              );
              console.error("Response body:", responseText);
              return;
            }
          } catch (e) {
            console.error(
              `Failed to upload file ${filename} via http fetch:`,
              e
            );
            return;
          }
          // final step: "register" the uploaded file with Shopify using fileCreate mutation
          const fileCreateMutation = `
  mutation fileCreate($files: [FileCreateInput!]!) {
    fileCreate(files: $files) {
      files {
        id
      }
      userErrors {
        field
        message
      }
    }
  }
`;

          const fileCreateVariables = {
            files: [
              {
                originalSource: shopifyResourceUrl, // this is not the final file url for us.
                alt: `Uploaded CSV file from node at ${new Date().toLocaleDateString(
                  "en-AU",
                  { timeZone: "Australia/Sydney" }
                )}`, // timezone to auto adjust for daylight savings time

                filename: "eb-soh.csv",
              },
            ],
          };

          try {
            const fileCreateResponse = await client.request(
              fileCreateMutation,
              {
                variables: fileCreateVariables,
              }
            );
            console.log("File create response:");
            console.dir(fileCreateResponse, { depth: null, colors: true });
            lastUploadedFileId = fileCreateResponse.data.fileCreate.files[0].id;
          } catch (e) {
            console.error("Failed to register file via fileCreate:", e);
          }
        }
      });
    }, debounceDelay);
  });
}

main();
