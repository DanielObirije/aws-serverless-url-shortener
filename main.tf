

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

//lambda

