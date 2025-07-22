import path, { dirname } from "path";
import { fileURLToPath } from "url";

// for local testing look for the uploads dir on the root of app
const __dirname = dirname(fileURLToPath(import.meta.url));
export const uploadsDir = path.resolve(__dirname, "../../uploads");

// export const uploadsDir = "/uploads";
