// 1. IMPORTS
// We bring in "types" from aws-lambda. These don't run in your code;
// they just help TypeScript know what a Lambda event looks like so it can auto-complete for us.
import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

// We bring in the DynamoDB tools. In the new AWS SDK (v3), everything is modular
// so we only import exactly what we need, which keeps the final code small.
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";

// Node's built-in cryptography tool. We use this to scramble URLs into random hashes.
import * as crypto from "crypto";

// 2. DATABASE SETUP (OUTSIDE THE HANDLER)
// We set up the database connection out here. AWS keeps this file loaded in memory
// for a little while after it runs. By putting this outside the main function,
// the next person who clicks a link doesn't have to wait for a new database connection.
const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client); // DocumentClient makes it easier to use regular JavaScript objects
const TABLE_NAME = process.env.TABLE_NAME || "";

// 3. THE MAIN TRAFFIC COP (THE HANDLER)
// This is the front door of your Lambda. Every request comes here first.
export const handler = async (
  event: APIGatewayProxyEvent,
): Promise<APIGatewayProxyResult> => {
  try {
    // Figure out what the user is trying to do
    const httpMethod = event.httpMethod; // e.g., "GET" or "POST"
    const path = event.path; // e.g., "/shorten" or "/Abc123x"

    // Route 1: The user wants to create a new short URL
    if (httpMethod === "POST" && path === "/shorten") {
      return await createShortUrl(event);
    }
    // Route 2: The user clicked a short link and wants to go to the real page
    else if (httpMethod === "GET" && path.startsWith("/")) {
      return await redirectToLongUrl(event);
    }
    // Route 3: They tried to go somewhere that doesn't exist
    else {
      return {
        statusCode: 404,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*", // Allows websites from other domains to talk to this API
        },
        body: JSON.stringify({ error: "Endpoint not found" }), // Always turn objects into strings before sending back
      };
    }
  } catch (error) {
    // If anything completely crashes, we catch it here so the user gets a clean error, not a blank page
    console.error("Error processing request:", error);
    return {
      statusCode: 500,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};

// 4. CREATING THE SHORT URL
async function createShortUrl(
  event: APIGatewayProxyEvent,
): Promise<APIGatewayProxyResult> {
  try {
    // AWS API Gateway sometimes encodes the request body weirdly (Base64).
    // This safely unpacks the payload so we can read it.
    let bodyContent = event.body || "";
    if (event.isBase64Encoded) {
      bodyContent = Buffer.from(bodyContent, "base64").toString("utf-8");
    }

    // Convert the string payload back into a usable JavaScript object
    const requestData = JSON.parse(bodyContent);
    const originalUrl = requestData.url;

    // Stop them if they didn't actually send a URL
    if (!originalUrl) {
      return createErrorResponse(400, "URL is required");
    }

    // Make sure it looks like a real website (e.g., has "http://" and "something.com")
    try {
      const parsedUrl = new URL(originalUrl);
      if (!parsedUrl.protocol || !parsedUrl.host) throw new Error();
    } catch {
      return createErrorResponse(400, "Invalid URL format");
    }

    // Create the 8-character random text (e.g., "Abc123x")
    const shortId = generateShortId(originalUrl);

    // Figure out when this link should die (defaults to 30 days from right now)
    const expirationDays = parseInt(
      process.env.URL_EXPIRATION_DAYS || "30",
      10,
    );
    const expirationTime = new Date();
    expirationTime.setDate(expirationTime.getDate() + expirationDays);
    const expirationTimestamp = Math.floor(expirationTime.getTime() / 1000); // DynamoDB likes time as seconds

    // Save everything into our DynamoDB database
    await docClient.send(
      new PutCommand({
        TableName: TABLE_NAME,
        Item: {
          short_id: shortId, // This is the primary key we will search for later
          original_url: originalUrl, // Where they actually want to go
          created_at: new Date().toISOString(),
          expires_at: expirationTime.toISOString(),
          expires_at_timestamp: expirationTimestamp,
          click_count: 0, // Starts at 0 clicks
          is_active: true, // An easy switch if we ever want to manually ban a link
        },
      }),
    );

    // Tell the user it worked! Send back a 201 (Created) status and their new shiny link.
    const apiUrl = process.env.API_URL || "https://your-domain.com";
    return {
      statusCode: 201,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      body: JSON.stringify({
        short_id: shortId,
        short_url: `${apiUrl}/${shortId}`, // The final link they can copy/paste
        original_url: originalUrl,
        expires_at: expirationTime.toISOString(),
      }),
    };
  } catch (error) {
    console.error("Error creating short URL:", error);
    return createErrorResponse(500, "Could not create short URL");
  }
}

// 5. REDIRECTING A USER
async function redirectToLongUrl(
  event: APIGatewayProxyEvent,
): Promise<APIGatewayProxyResult> {
  try {
    // If the path is "/Abc123x", this cuts off the "/" so we just have "Abc123x"
    const shortId = event.path.substring(1);

    if (!shortId) {
      return createErrorResponse(400, "Short ID is required");
    }

    // Ask the database for the link record using that short ID
    const response = await docClient.send(
      new GetCommand({
        TableName: TABLE_NAME,
        Key: { short_id: shortId },
      }),
    );

    const item = response.Item;

    // If the database returns nothing, the link doesn't exist
    if (!item) {
      return createErrorResponse(404, "Short URL not found");
    }

    // Safety check 1: Did an admin manually disable this link?
    if (item.is_active === false) {
      return createErrorResponse(410, "Short URL has been disabled");
    }

    // Safety check 2: Is it past the 30-day limit?
    const expiresAt = new Date(item.expires_at);
    if (new Date() > expiresAt) {
      return createErrorResponse(410, "Short URL has expired");
    }

    // Update the database to add 1 to the total clicks.
    // We do this instantly in the database so we don't accidentally overwrite data if 2 people click at the same exact millisecond.
    await docClient.send(
      new UpdateCommand({
        TableName: TABLE_NAME,
        Key: { short_id: shortId },
        UpdateExpression: "SET click_count = click_count + :inc", // Math happens on AWS's side
        ExpressionAttributeValues: { ":inc": 1 },
      }),
    );

    // The magic happens here: A 302 code tells the browser "Bounce the user to the URL in the 'Location' header immediately"
    return {
      statusCode: 302,
      headers: {
        Location: item.original_url,
        "Access-Control-Allow-Origin": "*",
      },
      body: "", // No body needed because the browser leaves the page before it can read it
    };
  } catch (error) {
    console.error("Error redirecting URL:", error);
    return createErrorResponse(500, "Could not redirect to URL");
  }
}

// 6. HELPER FUNCTIONS
// This turns a long URL into an 8-character string
function generateShortId(url: string): string {
  // We add the current time and a random UUID to the URL.
  // This guarantees that if two people submit the exact same Google link, they still get unique short links.
  const timestamp = new Date().toISOString();
  const uuidStr = crypto.randomUUID().replace(/-/g, "").substring(0, 8);
  const hashInput = `${url}${timestamp}${uuidStr}`;

  // Scramble the massive string into a fixed-length hexadecimal sequence
  const hashHex = crypto.createHash("sha256").update(hashInput).digest("hex");

  // Take the first chunk of the scramble, turn it into a giant number, and encode it into letters/numbers
  const hexPrefix = hashHex.substring(0, 16);
  const num = BigInt(`0x${hexPrefix}`); // BigInt allows JavaScript to handle massively long numbers without losing accuracy

  return base62Encode(num).substring(0, 8); // Cut it down to exactly 8 characters
}

// This is the math that translates giant numbers into a mix of a-z, A-Z, and 0-9
function base62Encode(num: bigint): string {
  const alphabet =
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  if (num === 0n) return alphabet[0];

  let result = "";
  while (num > 0n) {
    const rem = Number(num % 62n); // Find the remainder
    result = alphabet[rem] + result; // Pick the matching letter
    num = num / 62n; // Shrink the number and repeat
  }

  return result;
}

// Just a shortcut so we don't have to type out the same 9 lines of code every time an error happens
function createErrorResponse(
  statusCode: number,
  message: string,
): APIGatewayProxyResult {
  return {
    statusCode,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
    body: JSON.stringify({ error: message }),
  };
}
