#!/bin/bash
# Script pour nettoyer les VPCs petclinic orphelins
set -e

for VPC_ID in vpc-045dd6f2ad677f272 vpc-04b613f575a07bbb5 vpc-06c71d9a553ce8a00; do
  echo "=== Nettoyage VPC: $VPC_ID ==="

  # NAT Gateways
  NAT_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" --query "NatGateways[*].NatGatewayId" --output text)
  for nat in $NAT_IDS; do
    echo "  Suppression NAT: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id $nat
  done

  # Attente suppression NAT
  if [ -n "$NAT_IDS" ]; then
    echo "  Attente suppression NAT gateways..."
    sleep 30
  fi

  # Internet Gateways
  IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[*].InternetGatewayId" --output text)
  for igw in $IGW_IDS; do
    echo "  Détachement IGW: $igw"
    aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC_ID
    echo "  Suppression IGW: $igw"
    aws ec2 delete-internet-gateway --internet-gateway-id $igw
  done

  # Subnets
  SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)
  for subnet in $SUBNET_IDS; do
    echo "  Suppression Subnet: $subnet"
    aws ec2 delete-subnet --subnet-id $subnet
  done

  # Route Tables (non-default)
  RTB_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[?Main!=\`true\`]].RouteTableId" --output text)
  for rtb in $RTB_IDS; do
    # Remove non-main associations first
    ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids $rtb --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text)
    for assoc in $ASSOC_IDS; do
      aws ec2 disassociate-route-table --association-id $assoc 2>/dev/null || true
    done
    echo "  Suppression Route Table: $rtb"
    aws ec2 delete-route-table --route-table-id $rtb 2>/dev/null || true
  done

  # Security Groups (non-default)
  SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
  for sg in $SG_IDS; do
    echo "  Suppression SG: $sg"
    aws ec2 delete-security-group --group-id $sg 2>/dev/null || true
  done

  # VPC
  echo "  Suppression VPC: $VPC_ID"
  aws ec2 delete-vpc --vpc-id $VPC_ID

  echo "  VPC $VPC_ID supprimé avec succès"
  echo ""
done

echo "=== Nettoyage terminé ==="
