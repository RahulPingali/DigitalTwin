#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}
PROJECT_NAME=${2:-twin}

echo "Deploying $PROJECT_NAME to $ENVIRONMENT ..."

# Navigate to project root (script lives in scripts/)
cd "$(dirname "$0")/.."

# 1. Build Lambda package
echo "Building Lambda package..."
cd backend
uv run deploy.py
cd ..

# 2. Terraform workspace & apply
cd terraform

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace select "$ENVIRONMENT"
else
  terraform workspace new "$ENVIRONMENT"
fi

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
  terraform apply -var-file="prod.tfvars" -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
else
  terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
fi

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || echo "")

# 3. Build + deploy frontend
cd ../frontend

echo "Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete

cd ..

# 4. Final summary
CF_URL=$(terraform -chdir=terraform output -raw cloudfront_url)
echo "Deployment complete!"
echo "CloudFront URL : $CF_URL"
[ -n "$CUSTOM_URL" ] && echo "Custom domain  : $CUSTOM_URL"
echo "API Gateway    : $API_URL"