#!/bin/bash

# This script automates the creation of the EKS cluster and its node group.
#
# NON-INTERACTIVE USAGE:
# You can bypass the interactive prompts by setting the following environment
# variables before running the script:
#
#   export AWS_REGION="us-east-1"
#
#   Example:
#   AWS_REGION="us-east-1" ./deploy-eks.sh
#

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
echo "--- Gathering Configuration ---"

STACK_NAME="TelemetryHubStack"
CLUSTER_NAME="telemetry-hub-cluster"
NODEGROUP_NAME="telemetry-hub-cluster-nodes"

# Check for required CLIs
if ! command -v aws &> /dev/null || ! command -v eksctl &> /dev/null || ! command -v kubectl &> /dev/null; then
    echo "Error: AWS CLI, eksctl, and kubectl are required. Please install them to continue."
    exit 1
fi
echo "✅ Required CLIs (aws, eksctl, kubectl) found."

# Check for AWS Region
if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(aws configure get region 2>/dev/null)
fi
if [ -z "$AWS_REGION" ]; then
    echo "AWS Region not set or configured."
    read -p "Please enter your target AWS Region (e.g., us-east-1): " AWS_REGION
    if [ -z "$AWS_REGION" ]; then
        echo "Error: AWS Region is required."
        exit 1
    fi
fi
echo "Using AWS Region: ${AWS_REGION}"


# --- Step 1: Retrieve Network Configuration from CloudFormation ---
echo "--- Retrieving Network Configuration from CloudFormation ---"
VPC_ID=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs[?OutputKey=='VPCAId'].OutputValue" --output text --region "${AWS_REGION}")
# CORRECTED: Query for the plural 'EKSSubnetIds' output
SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --query "Stacks[0].Outputs[?OutputKey=='EKSSubnetIds'].OutputValue" --output text --region "${AWS_REGION}")

if [ -z "$VPC_ID" ] || [ -z "$SUBNET_IDS" ]; then
    echo "❌ Error: Could not retrieve VPC and Subnet details from CloudFormation stack '${STACK_NAME}'."
    echo "Please ensure the stack deployed successfully."
    exit 1
fi
echo "✅ Successfully retrieved network details for VPC ${VPC_ID}."


# --- Step 2: Create EKS Cluster Control Plane ---
echo "--- Creating EKS Cluster Control Plane: ${CLUSTER_NAME} ---"
echo "This process can take 15-20 minutes. Please wait..."
eksctl create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --vpc-private-subnets "${SUBNET_IDS}" \
  --without-nodegroup

echo "✅ EKS control plane created successfully."


# --- Step 3: Enable IAM OIDC Provider for the Cluster ---
echo "--- Enabling OIDC Provider for IAM Roles for Service Accounts ---"
eksctl utils associate-iam-oidc-provider --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --approve

echo "✅ OIDC provider associated successfully."


# --- Step 4: Create EKS Node Group ---
echo "--- Creating EKS Node Group: ${NODEGROUP_NAME} ---"
eksctl create nodegroup \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --name "${NODEGROUP_NAME}" \
  --node-type t3.medium \
  --nodes 2 \
  --node-private-networking

echo "✅ EKS node group created successfully."


# --- Step 5: Verify Cluster Access ---
echo "--- Verifying Cluster Access ---"
echo "Your ~/.kube/config has been updated. Verifying connection to the cluster..."
kubectl get nodes

echo "✅ EKS Cluster '${CLUSTER_NAME}' is ready."
