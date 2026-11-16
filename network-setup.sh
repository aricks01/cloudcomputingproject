#!/usr/bin/env bash
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-1
DB_PORT=3306

SSH_CIDR="${SSH_CIDR:-}"
if [[ -z "$SSH_CIDR" ]]; then
  echo "Set SSH_CIDR to your public IPv4/32 before deployment."
  exit 1
fi

# Check AWS credentials
aws sts get-caller-identity >/dev/null

# Prevent duplicate VPC creation
existing=$(aws ec2 describe-vpcs \
  --filters Name=tag:Name,Values=ceh-vpc \
  --query 'Vpcs[].VpcId' --output text)

if [[ -n "$existing" ]]; then
  echo "Existing ceh-vpc found: $existing"
  echo "Stop and inspect it before deploying again."
  exit 1
fi

# Create VPC
VPC=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications \
  'ResourceType=vpc,Tags=[{Key=Name,Value=ceh-vpc}]' \
  --query 'Vpc.VpcId' --output text)

aws ec2 wait vpc-available --vpc-ids "$VPC"

aws ec2 modify-vpc-attribute --vpc-id "$VPC" \
  --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute --vpc-id "$VPC" \
  --enable-dns-hostnames '{"Value":true}'

# Create four subnets
create_subnet() {
  aws ec2 create-subnet \
    --vpc-id "$VPC" \
    --cidr-block "$2" \
    --availability-zone "$3" \
    --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" \
    --query 'Subnet.SubnetId' --output text
}

PUB1=$(create_subnet ceh-public-1a 10.0.1.0/24 us-east-1a)
PUB2=$(create_subnet ceh-public-1b 10.0.2.0/24 us-east-1b)
PRIV1=$(create_subnet ceh-private-1a 10.0.3.0/24 us-east-1a)
PRIV2=$(create_subnet ceh-private-1b 10.0.4.0/24 us-east-1b)

# Enable public IP assignment on public subnets
for subnet in "$PUB1" "$PUB2"; do
  aws ec2 modify-subnet-attribute \
    --subnet-id "$subnet" \
    --map-public-ip-on-launch
done

# Create and attach internet gateway
IGW=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  'ResourceType=internet-gateway,Tags=[{Key=Name,Value=ceh-igw}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW" \
  --vpc-id "$VPC"

# Create public route table
PUBLIC_RT=$(aws ec2 create-route-table \
  --vpc-id "$VPC" \
  --tag-specifications \
  'ResourceType=route-table,Tags=[{Key=Name,Value=ceh-rt-public}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id "$PUBLIC_RT" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW" >/dev/null

aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT" \
  --subnet-id "$PUB1" >/dev/null

aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT" \
  --subnet-id "$PUB2" >/dev/null

# Private subnets use the main route table
# No NAT gateway is created
MAIN_RT=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC" \
  Name=association.main,Values=true \
  --query 'RouteTables[0].RouteTableId' \
  --output text)

# Create web security group
WEB_SG=$(aws ec2 create-security-group \
  --group-name ceh-sg-web \
  --description "Campus Event Hub web access" \
  --vpc-id "$VPC" \
  --tag-specifications \
  'ResourceType=security-group,Tags=[{Key=Name,Value=ceh-sg-web}]' \
  --query GroupId --output text)

# HTTP access
aws ec2 authorize-security-group-ingress \
  --group-id "$WEB_SG" \
  --protocol tcp --port 80 \
  --cidr 0.0.0.0/0

# SSH restricted to your public IP
aws ec2 authorize-security-group-ingress \
  --group-id "$WEB_SG" \
  --protocol tcp --port 22 \
  --cidr "$SSH_CIDR"

# Create database security group
DB_SG=$(aws ec2 create-security-group \
  --group-name ceh-sg-db \
  --description "Campus Event Hub database access" \
  --vpc-id "$VPC" \
  --tag-specifications \
  'ResourceType=security-group,Tags=[{Key=Name,Value=ceh-sg-db}]' \
  --query GroupId --output text)

# MySQL only accessible from web security group
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG" \
  --protocol tcp --port "$DB_PORT" \
  --source-group "$WEB_SG"

# Publish network IDs
cat > network-ids.txt <<IDS
Region: us-east-1
VPC ID: $VPC
VPC CIDR: 10.0.0.0/16
Public subnet 1: $PUB1 (us-east-1a, 10.0.1.0/24)
Public subnet 2: $PUB2 (us-east-1b, 10.0.2.0/24)
Private subnet 1: $PRIV1 (us-east-1a, 10.0.3.0/24)
Private subnet 2: $PRIV2 (us-east-1b, 10.0.4.0/24)
Internet gateway ID: $IGW
Public route table ID: $PUBLIC_RT
Main/private route table ID: $MAIN_RT
Web security group ID: $WEB_SG
Database security group ID: $DB_SG
Database port: $DB_PORT
IDS

cat network-ids.txt
printf '\nDeployment completed. Verify before publishing IDs.\n'