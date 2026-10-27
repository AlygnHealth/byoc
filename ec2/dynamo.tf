# DynamoDB table for storing Unison Cloud state
#
# The key schema is nimbus's: a binary hash key `K` and a string range key
# `NS`, as the Docker Compose setup creates its local table. (The template's
# single string key `id` is not one nimbus can use.)
resource "aws_dynamodb_table" "unison_cloud_byoc_state" {
  name         = local.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "K"
  range_key    = "NS"

  attribute {
    name = "K"
    type = "B"
  }

  attribute {
    name = "NS"
    type = "S"
  }

  # Every app table and every release record lives here.
  deletion_protection_enabled = true

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name        = "${var.cluster_name}-state"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}
