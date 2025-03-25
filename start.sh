#!/bin/bash

REPOSITORY=$REPO
ACCESS_TOKEN=$TOKEN

echo "REPO ${REPOSITORY}"
echo "ACCESS_TOKEN ${ACCESS_TOKEN}"



cd /home/docker/actions-runner
REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${REPOSITORY}/actions/runners/registration-token | jq .token --raw-output)
echo "REGISTRATION_TOKEN ${REG_TOKEN}"

#./config.sh --unattended \
#  --url "https://github.com/${REPOSITORY}" \
#  --token "${REG_TOKEN}" \
#  --runnergroup "Default" \
#  --name "devpod-default-gi-e7bcd" \
#  --labels "self-hosted,self-hosted-test" \
#  --work "_work" \
#  --replace

./config.sh --url https://github.com/${REPOSITORY} --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh & wait $!