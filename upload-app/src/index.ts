import fs from "fs";
import path from "path";

const uploadsDir = "/uploads";
console.log(`Watching ${uploadsDir}...`);
const debounceDelay = 500; // milliseconds
const watchTimers: Record<string, NodeJS.Timeout> = {};

fs.watch(uploadsDir, (eventType, filename) => {
  if (!filename) {
    console.log(`Change detected but no filename provided.`);
    return;
  }

  const fullPath = path.join(uploadsDir, filename);

  // proftpd's option HiddenStores writes files to a temp filename .in.*
  if (filename.startsWith(".in.")) {
    console.log(`Ignoring temporary file: ${filename} (prefix .in. detected)`);
    return;
  }

  // Clear any existing timer for this file
  if (watchTimers[filename]) {
    clearTimeout(watchTimers[filename]);
  }

  // Set a new timer
  watchTimers[filename] = setTimeout(() => {
    delete watchTimers[filename]; // Remove the timer once it fires

    fs.stat(fullPath, (err, stats) => {
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
      }
    });
  }, debounceDelay);
});
