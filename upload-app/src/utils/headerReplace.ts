import { readFile, writeFile } from "fs/promises";
import fs from "fs";

// Header mapping configuration
const HEADER_MAPPING: Record<string, string> = {
  Title: "Title",
  "Option1 Value": "Colour",
  "Option2 Value": "Size",
  "Variant SKU": "Variant SKU",
  "Variant Inventory Qty": "Local Stock",
  "Variant Metafield: custom._7_10_day_dispatch_stock [number_integer]":
    "7-10 Day Stock",
};

/**
 * Processes CSV file to rename headers according to HEADER_MAPPING
 * @param {string} inputFilePath - Path to the original CSV file
 * @returns {Promise<string>} - Path to the processed CSV file
 */
export async function processCSVHeaders(
  inputFilePath: string
): Promise<string> {
  try {
    const fileContent = await readFile(inputFilePath, "utf-8");
    const lines = fileContent.split("\n");

    if (lines.length === 0) {
      throw new Error("CSV file is empty");
    }

    // Process the header row (first line)
    const originalHeaders = lines[0].split(",");
    const newHeaders = originalHeaders.map((header) => {
      const trimmedHeader = header.trim().replace(/^"|"$/g, "");
      return HEADER_MAPPING[trimmedHeader] || trimmedHeader; // Use mapping or keep original
    });

    // Replace the first line with new headers
    lines[0] = newHeaders.join(",");
    const processedContent = lines.join("\n");

    // Create a temporary processed file
    const processedFilePath = inputFilePath.replace(
      /\.csv$/i,
      "_processed.csv"
    );
    await writeFile(processedFilePath, processedContent, "utf-8");

    console.log(`Processed CSV saved to: ${processedFilePath}`);
    return processedFilePath;
  } catch (error) {
    console.error("Error processing CSV headers:", error);
    throw error;
  }
}
