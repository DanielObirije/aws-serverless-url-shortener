import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import crypto from "crypto";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";

const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);
const tableName = process.env.TABLE_NAME!;

export const handler = async (event: APIGatewayProxyEvent) => {
  try {
    const httpMethod = event.httpMethod;
    const path = event.path;
    if (httpMethod === "POST" && path === "/shorten") {
      return createShortUrl(event);
    }
    if (httpMethod === "GET" && path.startsWith("/")) {
      return redirectToLongUrl(event);
    }
    return createErrorResponse(404, "Endpoint not found");
  } catch (error) {
    console.error("Error processing this request", error);
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

const createShortUrl = async (
  event: APIGatewayProxyEvent,
): Promise<APIGatewayProxyResult> => {
  try {
    let bodyContent = event.body || "";

    if (event.isBase64Encoded) {
      bodyContent = Buffer.from(bodyContent, "base64").toString("utf-8");
    }
    const { url: originalUrl } = JSON.parse(bodyContent);

    if (!originalUrl) {
      return createErrorResponse(400, "URL is required");
    }

    try {
      new URL(originalUrl);
      const parsed = new URL(originalUrl);

      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        return createErrorResponse(400, "Invalid URL");
      }
    } catch (error) {
      return createErrorResponse(400, "Invalid URL format");
    }

    const shortId = generateShortId(originalUrl);

    const expirationDays = Number(process.env.URL_EXPIRATION_DAYS ?? "30");

    const expirationTime = new Date();

    expirationTime.setDate(expirationTime.getDate() + expirationDays);

    const expirationTimestamp = Math.floor(expirationTime.getTime() / 1000);

    await docClient.send(
      new PutCommand({
        TableName: tableName,
        Item: {
          short_id: shortId,
          original_url: originalUrl,
          created_at: new Date().toISOString(),
          expires_at: expirationTimestamp,
          click_count: 0,
          is_active: true,
        },
      }),
    );

    const apiUrl = process.env.API_URL || "https://your-domain.com";
    return {
      statusCode: 201,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      body: JSON.stringify({
        short_id: shortId,
        short_url: `$${apiUrl}/$${shortId}`,
        original_url: originalUrl,
        expires_at: expirationTime.toISOString(),
      }),
    };
  } catch (error) {
    console.error("Error creating short url", error);
    return createErrorResponse(500, "Could not create short url");
  }
};

const redirectToLongUrl = async (
  event: APIGatewayProxyEvent,
): Promise<APIGatewayProxyResult> => {
  try {
    const shortId = event.path.substring(1);

    if (!shortId) {
      return createErrorResponse(400, "Short ID is required");
    }
    const response = await docClient.send(
      new GetCommand({
        TableName: tableName,
        Key: { short_id: shortId },
      }),
    );
    const item = response.Item;

    if (!item) {
      return createErrorResponse(404, "Short url not found");
    }

    if (item.is_active === false) {
      return createErrorResponse(410, "Short URL has been disabled");
    }

    const expiresAt = new Date(item.expires_at * 1000);

    if (new Date() > expiresAt) {
      return createErrorResponse(410, "Short url has expired");
    }

    await docClient.send(
      new UpdateCommand({
        TableName: tableName,
        Key: { short_id: shortId },
        UpdateExpression: "SET click_count = click_count + :inc",
        ExpressionAttributeValues: { ":inc": 1 },
      }),
    );

    return {
      statusCode: 302,
      headers: {
        Location: item.original_url,
        "Access-Control-Allow-Origin": "*",
      },
      body: "",
    };
  } catch (error) {
    console.error("Error redirecting URL:", error);
    return createErrorResponse(500, "Could not redirect to url");
  }
};

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

function generateShortId(url: string) {
  const timestamp = new Date().toISOString();
  const uuidStr = crypto.randomUUID().replace(/-/g, "").substring(0, 8);
  const hashInput = `$${url}$${timestamp}$${uuidStr}`;
  const hashHex = crypto.createHash("sha256").update(hashInput).digest("hex");
  const hexPrefix = hashHex.substring(0, 16);
  const num = BigInt(`0x$${hexPrefix}`);
  return base62Encode(num).substring(0, 8);
}

function base62Encode(num: bigint): string {
  const alphabet =
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  if (num === 0n) return alphabet[0];

  let result = "";
  while (num > 0n) {
    const rem = Number(num % 62n);
    result = alphabet[rem] + result;
    num = num / 62n;
  }

  return result;
}
