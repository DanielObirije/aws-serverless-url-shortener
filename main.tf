
data "aws_region" "current" {}

resource "random_id" "aws_suffix" {
  byte_length = 3
}

locals {
  name_prefix = "url_shotener-dev"
  name_surfix = random_id.aws_suffix.hex

  enable_cors = true
  enable_cloudwatch_dashboard = true

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

resource "null_resource" "build_lambda" {
  triggers = {
    source_code = filemd5("${path.module}/src/lambda_function.ts")
    package_json = filemd5("${path.module}/package.json")
    tsconfig_json = filemd5("${path.module}/tsconfig.json")
  }

   provisioner "local-exec" {
    command = "chmod +x ${path.module}/build.sh && ${path.module}/build.sh"
  }
}





//lambda function

# resource "local_file" "lambda_code" {
#   filename = "${path.module}/lambda_function.zip"
#   content = <<-EOF
#   import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
#   import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
#   import crypto from "crypto";
#   import {
#     DynamoDBDocumentClient,
#     GetCommand,
#     PutCommand,
#     UpdateCommand,
#   } from "@aws-sdk/lib-dynamodb";

#   const client = new DynamoDBClient({});
#   const docClient = DynamoDBDocumentClient.from(client);
#   const tableName = process.env.TABLE_NAME!;

#   export const handler = async (event: APIGatewayProxyEvent) => {
#     try {
#       const httpMethod = event.httpMethod;
#       const path = event.path;
#       if (httpMethod === "POST" && path === "/shorten") {
#         return createShortUrl(event);
#       }
#       if (httpMethod === "GET" && path.startsWith("/")) {
#         return redirectToLongUrl(event);
#       }
#       return createErrorResponse(404, "Endpoint not found");
#     } catch (error) {
#       console.error("Error processing this request", error);
#       return {
#         statusCode: 500,
#         headers: {
#           "Content-Type": "application/json",
#           "Access-Control-Allow-Origin": "*",
#         },
#         body: JSON.stringify({ error: "Internal server error" }),
#       };
#     }
#   };

#   const createShortUrl = async (
#     event: APIGatewayProxyEvent,
#   ): Promise<APIGatewayProxyResult> => {
#     try {
#       let bodyContent = event.body || "";

#       if (event.isBase64Encoded) {
#         bodyContent = Buffer.from(bodyContent, "base64").toString("utf-8");
#       }
#       const { url: originalUrl } = JSON.parse(bodyContent);

#       if (!originalUrl) {
#         return createErrorResponse(400, "URL is required");
#       }

#       try {
#         new URL(originalUrl);
#         const parsed = new URL(originalUrl);

#         if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
#           return createErrorResponse(400, "Invalid URL");
#         }
#       } catch (error) {
#         return createErrorResponse(400, "Invalid URL format");
#       }

#       const shortId = generateShortId(originalUrl);

#       const expirationDays = Number(process.env.URL_EXPIRATION_DAYS ?? "30");

#       const expirationTime = new Date();

#       expirationTime.setDate(expirationTime.getDate() + expirationDays);

#       const expirationTimestamp = Math.floor(expirationTime.getTime() / 1000);

#       await docClient.send(
#         new PutCommand({
#           TableName: tableName,
#           Item: {
#             short_id: shortId,
#             original_url: originalUrl,
#             created_at: new Date().toISOString(),
#             expires_at: expirationTimestamp,
#             click_count: 0,
#             is_active: true,
#           },
#         }),
#       );

#       const apiUrl = process.env.API_URL || "https://your-domain.com";
#       return {
#         statusCode: 201,
#         headers: {
#           "Content-Type": "application/json",
#           "Access-Control-Allow-Origin": "*",
#         },
#         body: JSON.stringify({
#           short_id: shortId,
#           short_url: `$${apiUrl}/$${shortId}`,
#           original_url: originalUrl,
#           expires_at: expirationTime.toISOString(),
#         }),
#       };
#     } catch (error) {
#       console.error("Error creating short url", error);
#       return createErrorResponse(500, "Could not create short url");
#     }
#   };

#   const redirectToLongUrl = async (
#     event: APIGatewayProxyEvent,
#   ): Promise<APIGatewayProxyResult> => {
#     try {
#       const shortId = event.path.substring(1);

#       if (!shortId) {
#         return createErrorResponse(400, "Short ID is required");
#       }
#       const response = await docClient.send(
#         new GetCommand({
#           TableName: tableName,
#           Key: { short_id: shortId },
#         }),
#       );
#       const item = response.Item;

#       if (!item) {
#         return createErrorResponse(404, "Short url not found");
#       }

#       if (item.is_active === false) {
#         return createErrorResponse(410, "Short URL has been disabled");
#       }

#       const expiresAt = new Date(item.expires_at * 1000);

#       if (new Date() > expiresAt) {
#         return createErrorResponse(410, "Short url has expired");
#       }

#       await docClient.send(
#         new UpdateCommand({
#           TableName: tableName,
#           Key: { short_id: shortId },
#           UpdateExpression: "SET click_count = click_count + :inc",
#           ExpressionAttributeValues: { ":inc": 1 },
#         }),
#       );

#       return {
#         statusCode: 302,
#         headers: {
#           Location: item.original_url,
#           "Access-Control-Allow-Origin": "*",
#         },
#         body: "",
#       };
#     } catch (error) {
#       console.error("Error redirecting URL:", error);
#       return createErrorResponse(500, "Could not redirect to url");
#     }
#   };

#   function createErrorResponse(
#     statusCode: number,
#     message: string,
#   ): APIGatewayProxyResult {
#     return {
#       statusCode,
#       headers: {
#         "Content-Type": "application/json",
#         "Access-Control-Allow-Origin": "*",
#       },
#       body: JSON.stringify({ error: message }),
#     };
#   }

#   function generateShortId(url: string) {
#     const timestamp = new Date().toISOString();
#     const uuidStr = crypto.randomUUID().replace(/-/g, "").substring(0, 8);
#     const hashInput = `$${url}$${timestamp}$${uuidStr}`;
#     const hashHex = crypto.createHash("sha256").update(hashInput).digest("hex");
#     const hexPrefix = hashHex.substring(0, 16);
#     const num = BigInt(`0x$${hexPrefix}`);
#     return base62Encode(num).substring(0, 8);
#   }

#   function base62Encode(num: bigint): string {
#     const alphabet =
#       "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
#     if (num === 0n) return alphabet[0];

#     let result = "";
#     while (num > 0n) {
#       const rem = Number(num % 62n);
#       result = alphabet[rem] + result;
#       num = num / 62n;
#     }

#     return result;
#   }
#    EOF
# }

//create deployment package

# data "archive_file" "lambda_zip"{
#   type = "zip"
#   source_file = local_file.lambda_code.filename
#   output_path = "${path.module}/lambda_function.ts"
#   depends_on = [ local_file.lambda_code ]
# }


//Lambda execution role
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

data "archive_file" "lambda_zip" {
  type = "zip"

  source_file = "${path.module}/lambda_function.zip"

  output_path = "${path.module}/lambda_deployment.zip"

  depends_on = [
    null_resource.build_lambda
  ]
}

//Attach  lambda role execution policy

resource "aws_iam_role_policy_attachment" "lambda_execution_policy_attachement" {
  role = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for DynamoDB access

resource "aws_iam_policy" "dynamodb_access" {
   name = "${local.name_prefix}-dynamodb-plicy-${local.name_surfix}"
   description = "IAM policy for DynamoDB access from lambda"
   policy = jsonencode({
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

//Attach DynamoDB policy to lambda role

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_access" {
  role = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.dynamodb_access.arn
}

//CloudWatch

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name = "/aws/lambda/${local.name_prefix}-${local.name_surfix}"
  retention_in_days = 14
  tags = merge(local.common_tags,{
    Name = "${local.name_prefix}cloud-watch${local.name_surfix}"
  })
}

//Lambda function

resource "aws_lambda_function" "url_shotener" {
  # filename =  data.archive_file.lambda_zip.output_path
  # filename = "${path.module}/lambda_function.zip"
  filename = data.archive_file.lambda_zip.output_path
  function_name = "${local.name_prefix}-${local.name_surfix}"
  role = aws_iam_role.lambda_execution.arn
  # handler = "lambda_function.handler"
  handler = "index.handler"
  # source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  # source_code_hash = filebase64sha256("${path.module}/lambda_function.zip")
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime = "nodejs22.x"
  timeout = 30
  memory_size = 256
  description = "URL shortener service function"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.url_storage.name
      URL_EXPIRATION_DAYS = 30
      API_URL = "https://${aws_apigatewayv2_api.url_shotener.id}.execute-api.${data.aws_region.current.name}.amazonaws.com/prod"
    }
  }

  depends_on = [ 
    null_resource.build_lambda, 
    aws_cloudwatch_log_group.lambda_logs,
    aws_iam_role_policy_attachment.lambda_dynamodb_access,
    aws_iam_role_policy_attachment.lambda_execution_policy_attachement
   ]

  tags = merge(
    local.common_tags,
    {
     Name = "${local.name_prefix}-function-${local.name_surfix}"
    }
  )
}

//Api gateway http api

resource "aws_apigatewayv2_api" "url_shotener" {
  name = "${local.name_prefix}-api-${local.name_surfix}"
  protocol_type = "HTTP"
  description = "Url shortener api"

  dynamic "cors_configuration" {
    for_each = local.enable_cors ? [1] : []
    content {
      allow_credentials = false
      allow_methods = ["GET","POST","OPTIONS"]
      allow_origins = ["*"]
      allow_headers = [
        "Content-Type",
        "X-Amz-Date",
        "Authorization",
        "X-Api-Key", 
        "X-Amz-Security-Token"
        ]
      max_age = 300
    }
  }
   tags = merge(local.common_tags,{
    Name = "${local.name_prefix}-api-${local.name_surfix}"
  })
}

//Api gateway integration with Lambda

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id = aws_apigatewayv2_api.url_shotener.id
  integration_type = "AWS_PROXY"
  integration_uri = aws_lambda_function.url_shotener.invoke_arn
  payload_format_version = "1.0"
  depends_on = [ aws_lambda_function.url_shotener ]
}

//Routes for url shortening (POST /shorten)

resource "aws_apigatewayv2_route" "shorten_url" {
  api_id = aws_apigatewayv2_api.url_shotener.id
  route_key = "POST /shorten"
  target = "integration/${aws_apigatewayv2_integration.lambda_integration.id}"
}

//Routes for url redirection (GET /{proxy+})

resource "aws_apigatewayv2_route" "redirect_url" {
  api_id = aws_apigatewayv2_api.url_shotener.id
  route_key = "GET /{proxy+}"
  target = "integration/${aws_apigatewayv2_integration.lambda_integration.id}"
}

//Api gateway stage
resource "aws_apigatewayv2_stage" "prod" {
  api_id = aws_apigatewayv2_api.url_shotener.id
  name = "prod"
  description = "Production stage"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      requestLength  = "$context.requestLength"
      ip             = "$context.identity.sourceIp"
      userAgent      = "$context.identity.userAgent"
    })
  }

  tags = local.common_tags
  depends_on = [aws_cloudwatch_log_group.lambda_logs]
}

//Cloudwatch log group for api gateway

resource "aws_cloudwatch_log_group" "api_gateway_logs"{
 name = "aws/apigateway/${local.name_prefix}-${local.name_surfix}"
 retention_in_days = 14
 tags = merge(local.common_tags,{
    Name = "${local.name_prefix}-api-${local.name_surfix}"
  })
}

// Lambda Permission for API Gateway

resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id = "AllowExecutionFromAPIGateway"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.url_shotener.function_name
  principal = "apigateway.amazonaws.com"
  source_arn = "${aws_apigatewayv2_api.url_shotener.execution_arn}"
}

//CloudWatch Dashboard

resource "aws_cloudwatch_dashboard" "url_shotener" {
  count = local.enable_cloudwatch_dashboard ? 1 : 0
  dashboard_name = "${local.name_prefix}-dahsboard-${local.name_surfix}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x = 0
        y = 0
        widgets = 12
        height = 6
        properties = {
          metric = [
            ["AWS/Lambda", "Invocation", "FunctionName", aws_lambda_function.url_shotener.function_name],
            [".","Errors",".","."],
            [".","Duration",".","."]
          ]
          period = 300
          stat = "Average"
          title = "Lambda Function Metrics"
          view = "timeSeries"
        }
      },
      {
        type = "metric"
        x = 12
        y = 0
        widgets = 12
        height = 6

        properties = {
          metric = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName",aws_dynamodb_table.url_storage],
            [".","ConsumedWriteCapacityUnits",".","."],
          ]
          period = 300
          stat = "Sum"
          title = "DynamoDB Table Metrics"
          view = "timeSeries"
        }
      },
      {
        type = "metric"
        x = 0
        y = 6
        widgets = 24
        height = 6

        properties = {
          metric = [
            ["AWS/ApiGatewayV2", "Count", "ApiId", aws_apigatewayv2_api.url_shotener],
            [".","IntegrationLatency",".","."],
            [".","Latency",".","."],
          ]
          period = 300
          stat = "Average"
          region = data.aws_region.current.name
          title = "API Gateway Metrics"
          view = "timeSeries"
        }
      }
    ]
  })

}
