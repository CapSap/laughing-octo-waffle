import fs from "fs";
import path from "path";

import { uploadsDir } from "./config.js";

// 15 days
const FILE_AGE = 15 * 24 * 60 * 60 * 1000;

export function cleanupOldFiles() {
  console.log("Starting periodic cleanup job...");

  fs.readdir(uploadsDir, (err, files) => {
    if (err) {
      console.error("Error reading uploads directory during cleanup:", err);
      return;
    }

    const now = Date.now();

    files.forEach((file) => {
      const filePath = path.join(uploadsDir, file);

      fs.stat(filePath, (err, stats) => {
        if (err) {
          console.error(`Error getting stats for file ${file}:`, err);
          return;
        }

        const age = now - stats.mtimeMs; // file modification time

        if (age > FILE_AGE) {
          fs.unlink(filePath, (err) => {
            if (err) {
              console.error(`Error deleting old file ${file}:`, err);
            } else {
              console.log(`Deleted old file: ${file}`);
            }
          });
        }
      });
    });
  });
}
