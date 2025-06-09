import "@shopify/shopify-api/adapters/node";
import { shopifyApi, ApiVersion, Session } from "@shopify/shopify-api";

type ShopifyApiReturnType = ReturnType<typeof shopifyApi>;
type GraphqlClientConstructor = ShopifyApiReturnType["clients"]["Graphql"];

// global var
let client: InstanceType<GraphqlClientConstructor> | null = null; // Use InstanceType here, and allow it to be null initially

export async function initShopify() {
  if (
    !process.env.SHOPIFY_SHOP_DOMAIN ||
    !process.env.SERVER_HOST ||
    !process.env.SHOPIFY_ADMIN_API_ACCESS_TOKEN ||
    !process.env.SHOPIFY_API_KEY ||
    !process.env.SHOPIFY_API_SECRET_KEY
  ) {
    const missingVars = [
      "SHOPIFY_SHOP_DOMAIN",
      "SERVER_HOST",
      "SHOPIFY_ADMIN_API_ACCESS_TOKEN",
      "SHOPIFY_API_KEY",
      "SHOPIFY_API_SECRET_KEY",
    ].filter((envVar) => !process.env[envVar]);
    console.log("missing key", missingVars);
    return;
  }

  const shopify = shopifyApi({
    apiKey: process.env.SHOPIFY_API_KEY,
    apiSecretKey: process.env.SHOPIFY_API_SECRET_KEY,
    scopes: ["write_files"],
    apiVersion: ApiVersion.July25,
    hostName: process.env.SERVER_HOST,
    hostScheme: "http",
    isEmbeddedApp: false,
    logger: {
      log: (severity, message) => {
        console.log(severity, message);
      },
    },
  });

  const session = new Session({
    id: "custom_app_session_id", // Can be a static ID for your private app
    shop: process.env.SHOPIFY_SHOP_DOMAIN,
    state: "STATE_NOT_REQUIRED_FOR_PRIVATE_APP", // OAuth state, not needed for private app
    isOnline: false, // Private app tokens are generally considered "offline" as they don't expire based on user presence
    scopes: ["write_files"],
    accessToken: process.env.SHOPIFY_ADMIN_API_ACCESS_TOKEN,
  });

  // 3. You can now use this session to create a GraphQL client:
  client = new shopify.clients.Graphql({ session });
}

export function getShopifyGraphqlClient() {
  if (!client) {
    throw new Error(
      "Shopify GraphQL client has not been initialized. Call initializeShopifyClient() first."
    );
  }
  return client;
}
