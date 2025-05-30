import fs from 'fs';
import path from 'path';

const uploadsDir = '/uploads';

console.log(`Watching ${uploadsDir}...`);

fs.watch(uploadsDir, (eventType, filename) => {
  if (filename) {
    const fullPath = path.join(uploadsDir, filename);

    fs.stat(fullPath, (err, stats) => {
      if (err) {
        if (err.code === 'ENOENT') {
          console.log(`File was deleted or renamed: ${filename}`);
        } else {
          console.error(`Error accessing ${filename}:`, err);
        }
        return;
      }

      if (stats.isFile()) {
        console.log(`Detected new file: ${filename}`);
        // TODO: handle processing
      }
    });
  } else {
    console.log(`Change detected but no filename provided.`);
  }
});
