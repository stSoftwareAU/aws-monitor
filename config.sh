#!/bin/bash
set -e
ACCESS_KEY=$1
SECRET_KEY=$2
REGION=$3

if [ -z "${SECRET_KEY}" ]; then
    echo "secret key required"
    exit 1
fi

if [ -z "${REGION}" ]; then
echo "aaa"
fi
mkdir -p ~/.aws

echo "[default]" > ~/.aws/config
echo "output = json" >> ~/.aws/config
echo "region = ${REGION}" >> ~/.aws/config

echo "[default]" > ~/.aws/credentials
echo "aws_access_key_id = ${ACCESS_KEY}" >> ~/.aws/credentials
echo "aws_secret_access_key = ${SECRET_KEY}" >> ~/.aws/credentials

chmod go-rwx ~/.aws/*
