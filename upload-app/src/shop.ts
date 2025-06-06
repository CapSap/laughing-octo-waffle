import "@shopify/shopify-api/adapters/node";
import { shopifyApi, ApiVersion } from "@shopify/shopify-api";

// For an independent Node.js server using a Custom App / Private App token

function doQuery() {
  if (!process.env.SHOPIFY_API_SECRET_KEY || !process.env.SERVER_HOST) {
    console.log("missing key");
    return;
  }

  const shopify = shopifyApi({
    apiKey: process.env.SHOPIFY_API_KEY,
    apiSecretKey: process.env.SHOPIFY_API_SECRET_KEY,
    scopes: ["write_files"],
    apiVersion: ApiVersion.July25,
    hostName: process.env.SERVER_HOST,
    isEmbeddedApp: false,
  });
}
