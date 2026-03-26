#!/bin/bash

# Configuration
EMAIL="michaelj.johnstone@yahoo.com" # Change this to your GitHub email
REPO_URL="git@github.com:Squid-Bomb/Base_Build.git"
KEY_PATH="$HOME/.ssh/id_ed25519"

echo "🚀 Starting SSH setup for GitHub..."

# 1. Generate SSH Key if it doesn't exist
if [ ! -f "$KEY_PATH" ]; then
    echo "🔑 Generating new SSH key..."
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N ""
else
    echo "✅ SSH key already exists at $KEY_PATH"
fi

# 2. Start ssh-agent and add key
echo "🛡️ Adding key to ssh-agent..."
eval "$(ssh-agent -s)"
ssh-add "$KEY_PATH"

# 3. Display the Public Key
echo "-------------------------------------------------------"
echo "📋 COPY THE KEY BELOW TO YOUR GITHUB SETTINGS:"
echo "-------------------------------------------------------"
cat "${KEY_PATH}.pub"
echo "-------------------------------------------------------"
echo "Go to: https://github.com/settings/keys"
echo "Click 'New SSH Key', give it a title, and paste the code above."
echo "-------------------------------------------------------"

# 4. Final Instructions
read -p "Press Enter once you have added the key to GitHub to test the connection..."

echo "Testing connection..."
ssh -T git@github.com

echo "🛠️ To clone your repo, run:"
echo "git clone $REPO_URL"
