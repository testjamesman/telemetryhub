#!/bin/bash

# This script updates the IAM role's trust policy to allow the EKS service account
# to assume it. It should be run AFTER the EKS cluster is created and BEFORE
# deploying the Kubernetes applications.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
echo "--- Gathering Configuration ---"

STACK_NAME="TelemetryHubStack"
CLUSTER_NAME="telemetry-hub-cluster"
SERVICE_ACCOUNT_NAME="python-processor-sa"
K8S_NAMESPACE="default"

# Check for required CLIs
if ! command -v aws &> /dev/null || ! command -v eksctl &> /dev/null; then
    echo "Error: AWS CLI and eksctl are required."
    exit 1
fi
if [ -z "$AWS_REGION" ]; then AWS_REGION=$(aws configure get region 2>/dev/null); fi
if [ -z "$AWS_REGION" ]; then read -p "Enter AWS Region: " AWS_REGION; fi
if [ -z "$AWS_ACCOUNT_ID" ]; then AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); fi

echo "Using AWS Region: ${AWS_REGION}"
echo "Using AWS Account ID: ${AWS_ACCOUNT_ID}"

# --- Step 1: Get EKS OIDC Provider URL ---
echo "--- Retrieving EKS OIDC Provider URL ---"
OIDC_PROVIDER_URL=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.identity.oidc.issuer" --output text)
if [ -z "$OIDC_PROVIDER_URL" ]; then
    echo "❌ Error: Could not retrieve OIDC Provider URL for cluster '${CLUSTER_NAME}'."
    exit 1
fi
# Extract the hostname part of the URL (e.g., oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53BF441)
OIDC_PROVIDER_HOST=$(echo $OIDC_PROVIDER_URL | sed 's|https://||')
echo "✅ Found OIDC Provider: ${OIDC_PROVIDER_HOST}"


# --- Step 2: Get IAM Role Name ---
echo "--- Retrieving IAM Role Name from CloudFormation ---"
ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs[?OutputKey=='SqsReaderRoleArn'].OutputValue" --output text --region "${AWS_REGION}")
if [ -z "$ROLE_ARN" ]; then
    echo "❌ Error: Could not retrieve SqsReaderRoleArn from stack '${STACK_NAME}'."
    exit 1
fi
ROLE_NAME=$(echo $ROLE_ARN | awk -F/ '{print $2}')
echo "✅ Found IAM Role: ${ROLE_NAME}"


# --- Step 3: Construct and Apply New Trust Policy ---
echo "--- Constructing new IAM trust policy ---"
# This policy allows the EKS OIDC provider to assume this role, but only
# for the specific service account we care about.
TRUST_POLICY_JSON=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_HOST}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER_HOST}:sub": "system:serviceaccount:${K8S_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
                }
            }
        }
    ]
}
EOF
)

echo "--- Applying new trust policy to IAM role '${ROLE_NAME}' ---"
aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUST_POLICY_JSON}" --region "${AWS_REGION}"

echo "✅ IAM trust policy updated successfully."
