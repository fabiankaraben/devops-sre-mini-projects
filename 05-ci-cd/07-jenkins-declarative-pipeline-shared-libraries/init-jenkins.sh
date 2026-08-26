#!/bin/bash
set -e

echo "[JENKINS-INIT] Setting up local Git repositories for Shared Library and Pipeline..."

GIT_CONFIG_USER="Jenkins CI"
GIT_CONFIG_EMAIL="ci@jenkins.local"

# Clear cached shared library workspaces
rm -rf /var/jenkins_home/workspace@libs 2>/dev/null || true

# 1. Initialize local Shared Library Git repo
mkdir -p /var/jenkins_home/shared-library.git
cd /var/jenkins_home/shared-library.git
if [ ! -f "HEAD" ]; then
    git init --bare --shared
    git symbolic-ref HEAD refs/heads/main
fi

mkdir -p /tmp/seed-shared-lib
cd /tmp/seed-shared-lib
rm -rf ./* .git
git init
git config user.name "$GIT_CONFIG_USER"
git config user.email "$GIT_CONFIG_EMAIL"

if [ -d "/seed/project/vars" ]; then
    cp -r /seed/project/vars ./
fi
if [ -d "/seed/project/src" ]; then
    cp -r /seed/project/src ./
fi

git add -A
git commit -m "feat(shared-lib): seed enterprise shared library" || true
git branch -M main
git remote add origin /var/jenkins_home/shared-library.git || true
git push -u origin main -f || true
echo "[JENKINS-INIT] Shared library repository initialized at file:///var/jenkins_home/shared-library.git"

# 2. Initialize local Pipeline Workload Git repo
mkdir -p /var/jenkins_home/pipeline-repo.git
cd /var/jenkins_home/pipeline-repo.git
if [ ! -f "HEAD" ]; then
    git init --bare --shared
    git symbolic-ref HEAD refs/heads/main
fi

mkdir -p /tmp/seed-pipeline-repo
cd /tmp/seed-pipeline-repo
rm -rf ./* .git
git init
git config user.name "$GIT_CONFIG_USER"
git config user.email "$GIT_CONFIG_EMAIL"

if [ -f "/seed/project/Jenkinsfile" ]; then
    cp /seed/project/Jenkinsfile ./
fi
if [ -d "/seed/project/app" ]; then
    cp -r /seed/project/app ./
fi

git add -A
git commit -m "feat(pipeline): initial application and Jenkinsfile" || true
git branch -M main
git remote add origin /var/jenkins_home/pipeline-repo.git || true
git push -u origin main -f || true
echo "[JENKINS-INIT] Pipeline repository initialized at file:///var/jenkins_home/pipeline-repo.git"

# Allow file protocol in Git for local clones (CVE mitigation bypass for local trusted tests)
git config --global protocol.file.allow always

echo "[JENKINS-INIT] Launching Jenkins controller..."
exec /usr/local/bin/jenkins.sh "$@"
