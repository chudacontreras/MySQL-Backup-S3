#!/bin/bash

# Variables
DB_HOST="your-rds-endpoint"
DB_NAME="your-db-name"
DB_USER="your-username"
DB_PASS="your-password"
BUCKET="rds-backup-bucket-example"
DATE=$(date +\%Y-\%m-\%d_%H-\%M)
BACKUP_NAME="backup-${DB_NAME}-${DATE}.sql"
DUMP_PATH="/tmp/${BACKUP_NAME}"

# Dump MySQL
mysqldump -h $DB_HOST -u $DB_USER -p$DB_PASS $DB_NAME > $DUMP_PATH

# Upload to S3
aws s3 cp $DUMP_PATH s3://$BUCKET/

# Cleanup
rm -f $DUMP_PATH
