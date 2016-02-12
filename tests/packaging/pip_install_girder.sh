#!/bin/bash

virtualenv_pip="${1}"
PROJECT_SOURCE_DIR="${2}"
virtualenv_activate="${3}"
virtualenv_dir="${4}"
CURL="${5}"
GREP="${6}"
unset PYTHONPATH

# Install girder inside the virtualenv
"${virtualenv_pip}" uninstall -y girder > /dev/null
"${virtualenv_pip}" --no-cache-dir install -U "${PROJECT_SOURCE_DIR}"/girder-[0-9].[0-9]*.tar.gz
if [ $? -ne 0 ]; then
    echo "Error during pip install girder package"
    exit 1
fi

# Make sure girder-server entrypoint is on the path
source "${virtualenv_activate}"
which girder-server
if [ $? -ne 0 ]; then
    echo "Error: girder-server not found on the executable path"
    exit 1
fi

# Make sure extra data files were installed correctly
ls "${virtualenv_dir}"/lib/python*/site-packages/girder/mail_templates/_header.mako
if [ $? -ne 0 ]; then
    echo "Error: mail templates were not installed"
    exit 1
fi

# Start the server
export GIRDER_PORT=31200
python -m girder &> /dev/null &

girder_pid=$!
sleep 1
if ! ps -p $girder_pid &> /dev/null ; then
    echo "Error: Girder could not be started"
    exit 1
fi

version="$(girder-install version)"
echo "Detected api version ${version}"

# Connect to the REST API and request the version
timeout=0
until [ $timeout -eq 5 ]; do
    json=$("${CURL}" --connect-timeout 5 --max-time 5 --silent http://localhost:${GIRDER_PORT}/api/v1/system/version)
    if [ -n "$json" ] && [[ $json == *shortSHA* ]]; then
        break
    fi
    timeout=$((timeout+1))
    sleep 1
done

# Make sure we got the correct version
if [ -n "$json" ]; then
    echo "Girder responded with ${json}"
    python <<EOF
import json
assert json.loads("""${json}""")['apiVersion'].strip() == """${version}""".strip()
EOF
    if [ "$?" -ne  "0" ]; then
        echo "Error: Invalid version returned."
        exit 1
    fi
else
    echo "Error: Girder did not respond"
    exit 1
fi

# Build the web client code
girder-install web || exit 1

# Make sure that our grunt targets got built
webroot=$(girder-install web-root)
if [ ! -f "${webroot}/static/built/plugins/jobs/plugin.min.js" ] ; then
    echo "Error: grunt targets were not built correctly"
    exit 1
fi

# Start Girder server
export GIRDER_PORT=50202
python -m girder &> /dev/null &

# Ensure the server started
girder_pid=$!
sleep 1
if ! ps -p $girder_pid &> /dev/null; then
    echo "Error: Girder could not be started"
    exit 1
fi

# Loop until Girder is giving answers
timeout=0
until [ $timeout -eq 15 ]; do
    json=$("${CURL}" --connect-timeout 5 --max-time 5 --silent http://localhost:${GIRDER_PORT}/api/v1/system/version)
    if [ -n "$json" ]; then
        break
    fi
    timeout=$((timeout+1))
    sleep 1
done

# Make sure our HTML is sent correctly for the main app
"${CURL}" --max-time 5 --silent http://localhost:${GIRDER_PORT} | "${GREP}" "g-global-info-apiroot" > /dev/null
if [ $? -ne 0 ] ; then
    echo "Error: Failed to load main page"
    exit 1
fi

# Make sure swagger page loads correctly
"${CURL}" --max-time 5 --silent http://localhost:${GIRDER_PORT}/api/v1 | "${GREP}" "swagger" > /dev/null
if [ $? -ne 0 ] ; then
    echo "Error: Failed to load Swagger docs"
    exit 1
fi

# Kill the server inelegantly
kill -9 %+
