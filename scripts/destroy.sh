#!/bin/bash
set -e

ENVIRONMENT=$1
PROJECT_NAME=${2:-twin}

# Validate environment parameter
if [[ ! "$ENVIRONMENT" =~ ^(dev|test|prod)$ ]]; then
  echo "Error: Invalid environment '$ENVIRONMENT'"
  echo "Available environments: dev, test, prod"
  exit 1
fi

echo "Preparing to destroy $PROJECT_NAME-$ENVIRONMENT infrastructure..."

# Navigate to terraform directory
cd "$(dirname "$0")/../terraform"

# Get AWS Account ID and Region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Initialize terraform with S3 backend
echo "Initializing Terraform with S3 backend..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

# Check if workspace exists
if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  echo "Error: Workspace '$ENVIRONMENT' does not exist"
  echo "Available workspaces:"
  terraform workspace list
  exit 1
fi

# Select the workspace
terraform workspace select "$ENVIRONMENT"

echo "Emptying S3 buckets..."

FRONTEND_BUCKET="$PROJECT_NAME-$ENVIRONMENT-frontend-$AWS_ACCOUNT_ID"
MEMORY_BUCKET="$PROJECT_NAME-$ENVIRONMENT-memory-$AWS_ACCOUNT_ID"

# Empty frontend bucket if it exists
if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
  echo "  Emptying $FRONTEND_BUCKET..."
  aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
  echo "  Frontend bucket not found or already empty"
fi

# Empty memory bucket if it exists
if aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
  echo "  Emptying $MEMORY_BUCKET..."
  aws s3 rm "s3://$MEMORY_BUCKET" --recursive
else
  echo "  Memory bucket not found or already empty"
fi

echo "Running terraform destroy..."

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
  terraform destroy -var-file=prod.tfvars \
                   -var="project_name=$PROJECT_NAME" \
                   -var="environment=$ENVIRONMENT" \
                   -auto-approve
else
  terraform destroy -var="project_name=$PROJECT_NAME" \
                   -var="environment=$ENVIRONMENT" \
                   -auto-approve
fi

echo "Infrastructure for $ENVIRONMENT has been destroyed!"
echo ""
echo "  To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"