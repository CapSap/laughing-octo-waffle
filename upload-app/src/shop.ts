import "@shopify/shopify-api/adapters/node";
import { shopifyApi, ApiVersion, Session } from "@shopify/shopify-api";
import { readDockerSecret } from "./utils/readDockerSecret.js";

type ShopifyApiReturnType = ReturnType<typeof shopifyApi>;
type GraphqlClientConstructor = ShopifyApiReturnType["clients"]["Graphql"];

// global var
let client: InstanceType<GraphqlClientConstructor> | null = null; // Use InstanceType here, and allow it to be null initially

export async function initShopify() {
  let shopifyShopDomain: string;
  let serverHost: string;
  let shopifyAdminApiAccessToken: string;
  let shopifyApiKey: string;
  let shopifyApiSecretKey: string;

  try {
    // Read secrets using the readDockerSecret function
    shopifyShopDomain = readDockerSecret("shopify_shop_domain");
    serverHost = readDockerSecret("server_host");
    shopifyAdminApiAccessToken = readDockerSecret(
      "shopify_admin_api_access_token"
    );
    shopifyApiKey = readDockerSecret("shopify_api_key");
    shopifyApiSecretKey = readDockerSecret("shopify_api_secret_key");
  } catch (e) {
    console.error("Failed to load one or more Shopify secrets:");
    if (e instanceof Error) {
      console.error(`Error: ${e.message}`);
    } else {
      console.error(`An unknown error occurred: ${String(e)}`);
    }
    return;
  }

  console.log("Shopify API Secrets (as seen by app):");
  console.log("SHOPIFY_SHOP_DOMAIN:", shopifyShopDomain);
  console.log("SERVER_HOST:", serverHost);
  // Be careful not to log full secret values, especially for tokens/keys
  console.log(
    "SHOPIFY_ADMIN_API_ACCESS_TOKEN (first 5 chars):",
    shopifyAdminApiAccessToken.substring(0, 5) + "..."
  );
  console.log("SHOPIFY_API_KEY:", shopifyApiKey);
  console.log(
    "SHOPIFY_API_SECRET_KEY (first 5 chars):",
    shopifyApiSecretKey.substring(0, 5) + "..."
  );

  const shopify = shopifyApi({
    apiKey: shopifyApiKey,
    apiSecretKey: shopifyApiSecretKey,
    scopes: ["write_files"],
    apiVersion: ApiVersion.July25, // Or your specific API version
    hostName: serverHost,
    hostScheme: "http", // Or 'https' if your SERVER_HOST is HTTPS enabled
    isEmbeddedApp: false,
    logger: {
      log: (severity, message) => {
        console.log(severity, message);
      },
    },
  });

  const session = new Session({
    id: "custom_app_session_id", // Can be a static ID for your private app
    shop: shopifyShopDomain,
    state: "STATE_NOT_REQUIRED_FOR_PRIVATE_APP", // OAuth state, not needed for private app
    isOnline: false, // Private app tokens are generally considered "offline"
    scopes: ["write_files"],
    accessToken: shopifyAdminApiAccessToken,
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
