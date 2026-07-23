#!/bin/bash
# Log stdout and stderr to a file for debugging
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "=== Starting User Data Script ==="
# 1. Update and install packages
echo "Installing Java 17, jq, awscli, and dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-17-jre-headless jq awscli
# 2. Create application directory and user
echo "Creating application user and directories..."
useradd -r -s /sbin/nologin petclinic
mkdir -p /opt/petclinic
# 3. Retrieve DB Secrets from AWS Secrets Manager
echo "Retrieving database credentials from Secrets Manager..."
SECRET_VAL=$(aws secretsmanager get-secret-value --secret-id ${db_secret_id} --region ${aws_region} --query SecretString --output text)
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to retrieve secret from Secrets Manager"
  exit 1
fi
DB_USER=$(echo "$SECRET_VAL" | jq -r .username)
DB_PASS=$(echo "$SECRET_VAL" | jq -r .password)
# 4. Download application JAR from S3
echo "Downloading PetClinic JAR from S3 bucket ${bucket_name}..."
aws s3 cp s3://${bucket_name}/petclinic.jar /opt/petclinic/petclinic.jar --region ${aws_region}
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to download JAR from S3"
  exit 1
fi
chown -R petclinic:petclinic /opt/petclinic
chmod 500 /opt/petclinic/petclinic.jar
# 5. Create Systemd service
echo "Creating Systemd service..."
cat <<EOF > /etc/systemd/system/petclinic.service
[Unit]
Description=Spring PetClinic Application
After=network.target mysql.service
[Service]
User=petclinic
WorkingDirectory=/opt/petclinic
Environment="MYSQL_URL=jdbc:mysql://${db_proxy_endpoint}:3306/${db_name}?useSSL=true&requireSSL=true"
Environment="MYSQL_USER=$${DB_USER}"
Environment="MYSQL_PASS=$${DB_PASS}"
ExecStart=/usr/bin/java -jar /opt/petclinic/petclinic.jar --spring.profiles.active=mysql
SuccessExitStatus=143
TimeoutStopSec=10
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
# 6. Start and enable service
echo "Starting Spring PetClinic service..."
systemctl daemon-reload
systemctl enable petclinic
systemctl start petclinic
echo "=== User Data Script Completed ==="