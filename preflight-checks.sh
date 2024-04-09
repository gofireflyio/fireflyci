#!/bin/bash

# Exit on failure
set -e

# Variables
FIREFLYCI_DIR="/usr/local/bin"
FIREFLYCI_URL="https://gofirefly-prod-iac-ci-cli-binaries.s3.amazonaws.com/fireflyci/${FIREFLYCI_VERSION}/fireflyci_Linux_x86_64.tar.gz"

# Handle sudo within a container
if ! sudo echo &>/dev/null; then
  if [ $(whoami) = "root" ]; then
    alias sudo=""
  else
    echo "[Error] You must run the script using root or with sudo privileges to install FireflyCI"
    exit 1
  fi
fi

# Check if fireflyci is not installed, or the version is different, then download & install it
if ! which fireflyci >/dev/null 2>&1 || ( [ "$(fireflyci version 2>&1)" != "${FIREFLYCI_VERSION:1}" ] \
  && [ "$FIREFLYCI_VERSION" != "latest" ] ); then
  # Print downloading statement
  echo "> Downloading FireFlyCI.. | Version: $FIREFLYCI_VERSION" 
  # Create installation directory if it doesn't exist 
  if [ ! -d "$FIREFLYCI_DIR" ]; then
    mkdir -p "$FIREFLYCI_DIR"
  fi
  # Download and untar fireflyci
  curl -sS "$FIREFLYCI_URL" | sudo tar xz -C "$FIREFLYCI_DIR"
  sudo chmod a+x "$FIREFLYCI_DIR/fireflyci"
  # Export to PATH
  # echo "PATH=$PATH:$FIREFLYCI_DIR" >> $GITHUB_ENV
fi