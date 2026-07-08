

resource "random_id" "aws_suffix" {
  byte_length = 3
}

locals {
  name_prefix = "url_shotener-dev"
  name_surfix = random_id.aws_suffix

  common_tags = merge(
    {
        Project = "url_shotener-dev"
        Environment = "dev"
        ManagedBy = "Terraform"
    }
  )
}

//DynamoDb

resource "aws_dynamodb_table" "url_storage" {
  name = "${local.name_prefix}-${local.name_surfix}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key = "short_id"

  attribute {
    name = "short_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  ttl {
    attribute_name = "expires_at_timestamp"
    enabled = true
  }

  tags = merge(
    local.common_tags,
    {
     Name = "${local.name_prefix}-table-${local.name_surfix}"
    }
  )
}

//lambda function

resource "local_file" "lambda_code" {
  filename = "${path.module}/lambda_function.ts"
  content = <<-EOF
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
          short_url: `${apiUrl}/${shortId}`,
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
    const hashInput = `${url}${timestamp}${uuidStr}`;
    const hashHex = crypto.createHash("sha256").update(hashInput).digest("hex");
    const hexPrefix = hashHex.substring(0, 16);
    const num = BigInt(`0x${hexPrefix}`);
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
   EOF
}






//iam role and permissions for lambda
resource "aws_iam_role" "lambda_execution" {
  name = "${local.name_prefix}-lambda-role-${local.name_surfix}"
  assume_role_policy = jsonencode({
  Version = "2012-10-17"
  Statement = {
     Action = "sts:AssumeRole"
     Effect = "Allow"
     Principal = {
        Service = "lambda.amazonaws.com"
     }
  }
})
tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_execution_policy_attachement" {
  role = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "dynamodb_access" {
   name = "${local.name_prefix}-dynamodb-plicy-${local.name_surfix}"
   description = "IAM policy for DynamoDB access from lambda "
   policy = jsondecode({
      Version = "2012-10-17"
      Statement = {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.url_storage.arn
      }
   })
   tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_access" {
  role = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.dynamodb_access.arn
}

#CloudWatch
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name = "/aws/lambda/${local.name_prefix}-${local.name_surfix}"
  retention_in_days = 14
  tags = merge(local.common_tags,{
    Name = "${local.name_prefix}-${local.name_surfix}"
  })
}

