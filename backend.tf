# Terraform S3 Backend Configuration
# Note: The actual bucket and DynamoDB table names are passed dynamically via -backend-config
# during terraform init in the GitHub Actions workflow. This allows for account-specific naming.

terraform {
  backend "s3" {
    # These values are provided dynamically via -backend-config flags:
    # - bucket (e.g., solar-terraform-state-<account-id>)
    # - dynamodb_table (e.g., solar-terraform-lock)
    key     = "compliance-reporting/terraform.tfstate"
    region  = "ap-southeast-1"
    encrypt = true
  }
}
