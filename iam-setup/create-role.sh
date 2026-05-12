#!/usr/bin/env bash
# Creates the IAM role that Terraform will assume to deploy Langfuse.
# Run this once with admin credentials BEFORE running terraform.
#
# Usage:
#   chmod +x iam-setup/create-role.sh
#   ./iam-setup/create-role.sh [role-name]
#
# Default role name: langfuse-terraform-deployer

set -euo pipefail

ROLE_NAME="${1:-langfuse-terraform-deployer}"
POLICY_1_NAME="langfuse-terraform-networking-storage"
POLICY_2_NAME="langfuse-terraform-app-services"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Getting current caller identity..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "    Account : ${ACCOUNT_ID}"
echo "    Caller  : ${CALLER_ARN}"

# -------------------------------------------------------
# Trust policy — allow the current principal to assume role
# -------------------------------------------------------
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${CALLER_ARN}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

# -------------------------------------------------------
# 1. Create the role (idempotent: skip if exists)
# -------------------------------------------------------
echo ""
echo "==> Creating IAM role: ${ROLE_NAME}..."
if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
  echo "    Role already exists, skipping creation."
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Role used by Terraform to deploy Langfuse on ECS Fargate" \
    --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform
  echo "    Created."
fi

# -------------------------------------------------------
# 2. Create / update managed policy — networking & storage
# -------------------------------------------------------
echo ""
echo "==> Creating managed policy: ${POLICY_1_NAME}..."
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}" &>/dev/null; then
  echo "    Policy exists. Creating a new version..."
  # Delete oldest non-default version if at limit (max 5 versions)
  VERSIONS=$(aws iam list-policy-versions \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
    --output text)
  for v in $VERSIONS; do
    COUNT=$(echo "$VERSIONS" | wc -w | tr -d ' ')
    if [ "$COUNT" -ge 4 ]; then
      aws iam delete-policy-version \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}" \
        --version-id "$v"
      echo "    Deleted old version: $v"
      break
    fi
  done
  aws iam create-policy-version \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}" \
    --policy-document "file://${SCRIPT_DIR}/policy-networking-storage.json" \
    --set-as-default
  POLICY_1_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}"
else
  POLICY_1_ARN=$(aws iam create-policy \
    --policy-name "${POLICY_1_NAME}" \
    --policy-document "file://${SCRIPT_DIR}/policy-networking-storage.json" \
    --description "Terraform: EC2/VPC, S3, ECR, EFS, ALB permissions for Langfuse" \
    --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform \
    --query Policy.Arn --output text)
  echo "    Created: ${POLICY_1_ARN}"
fi

# -------------------------------------------------------
# 3. Create / update managed policy — app services
# -------------------------------------------------------
echo ""
echo "==> Creating managed policy: ${POLICY_2_NAME}..."
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}" &>/dev/null; then
  echo "    Policy exists. Creating a new version..."
  VERSIONS=$(aws iam list-policy-versions \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
    --output text)
  for v in $VERSIONS; do
    COUNT=$(echo "$VERSIONS" | wc -w | tr -d ' ')
    if [ "$COUNT" -ge 4 ]; then
      aws iam delete-policy-version \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}" \
        --version-id "$v"
      echo "    Deleted old version: $v"
      break
    fi
  done
  aws iam create-policy-version \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}" \
    --policy-document "file://${SCRIPT_DIR}/policy-app-services.json" \
    --set-as-default
  POLICY_2_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}"
else
  POLICY_2_ARN=$(aws iam create-policy \
    --policy-name "${POLICY_2_NAME}" \
    --policy-document "file://${SCRIPT_DIR}/policy-app-services.json" \
    --description "Terraform: ECS, RDS, ElastiCache, IAM, Secrets, Logs, CloudMap for Langfuse" \
    --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform \
    --query Policy.Arn --output text)
  echo "    Created: ${POLICY_2_ARN}"
fi

# -------------------------------------------------------
# 4. Attach both policies to the role
# -------------------------------------------------------
echo ""
echo "==> Attaching policies to role..."
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_1_NAME}"
echo "    Attached: ${POLICY_1_NAME}"

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_2_NAME}"
echo "    Attached: ${POLICY_2_NAME}"

# -------------------------------------------------------
# 5. Print summary
# -------------------------------------------------------
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo "======================================================"
echo " Setup complete!"
echo "======================================================"
echo ""
echo " Role ARN:"
echo "   ${ROLE_ARN}"
echo ""
echo " Next steps:"
echo "   1. Copy the Role ARN above"
echo "   2. Add to your terraform.tfvars:"
echo ""
echo "        terraform_role_arn = \"${ROLE_ARN}\""
echo ""
echo "   3. Run Terraform:"
echo "        terraform init"
echo "        terraform plan"
echo "        terraform apply"
echo "======================================================"
