

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

