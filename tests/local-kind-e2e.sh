#!/usr/bin/env bash

set -e -o pipefail

##################################################
# Some environment variables to control the tests
##################################################

# HA_MODE="true": to enable HA mode in the tests
# DAPR_E2E_TEST: to the specific e2e test to run if not set all tests run. Values is the name of a folder name in e2e, ie: scheduler
# DAPR_SCHEDULER_REPLICAS: set to the number of replicas for the scheduler test. In HA mode the default is 3 but it can be overridden is this value > 3
# DAPR_TEST_NAMESPACE: set to the namespace to use for the tests. Default is dapr-tests
# DEBUG_LOGGING="true": to enable debug logging in daprd
# ADDITIONAL_HELM_SET:
#
# The following skip knobs SHOULD ONLY be set after running the script once and the services are already deployed:
# - DAPR_E2E_TEST_SKIP_SUPPORTING_SERVICES: set to "true" to skip deploying supporting services like Redis, Kafka, Zipkin, Postgres. After first install you can skip these
# - DAPR_E2E_BUILD_APP_SKIP: set to "true" to skip building the test apps  (after the first build usually you can skip it unless you modify the app)
# - DAPR_E2E_BUILD_DAPR_SKIP: set to "true" ONLY if you are actually testing the test apps and not Dapr itself

export ADDITIONAL_HELM_SET="dapr_operator.logLevel=debug,dapr_operator.watchInterval=20s,dapr_scheduler.logLevel=debug"

############################################
# Check if the required tools are installed
############################################

# check we are running in linux/mac
if [ "$(uname)" != "Linux" ] && [ "$(uname)" != "Darwin" ]; then
  echo "Unsupported OS $(uname)"
  exit 1
fi

# check if kind is available
if ! command -v kind &> /dev/null; then
  echo "kind is not installed. Please install kind from https://kind.sigs.k8s.io/docs/user/quick-start/"
  exit 1
fi

# check cloud-provider-kind is available
if ! command -v cloud-provider-kind &> /dev/null; then
  echo "cloud-provider-kind is not installed. Please install cloud-provider-kind from https://github.com/kubernetes-sigs/cloud-provider-kind"
  exit 1
fi

############################################
# Setup Environment
############################################

LOCAL_ARCH=$(uname -m)
if [ "$LOCAL_ARCH" == "x86_64" ]; then
	TARGET_ARCH_LOCAL=amd64
elif [ "$(echo "$LOCAL_ARCH" | head -c 5)" == "armv8" ]; then
	TARGET_ARCH_LOCAL=arm64
elif [ "$(echo "$LOCAL_ARCH" | head -c 4)" == "armv" ]; then
  TARGET_ARCH_LOCAL=arm
elif [ "$(echo "$LOCAL_ARCH" | head -c 5)" == "arm64" ]; then
  TARGET_ARCH_LOCAL=arm64
elif [ "$(echo "$LOCAL_ARCH" | head -c 7)" == "aarch64" ]; then
  TARGET_ARCH_LOCAL="arm64"
else
  TARGET_ARCH_LOCAL="amd64"
fi

# exit if TARGET_ARCH_LOCAL is not one of arm64, amd64 (no kind images for other architectures)
if [ "$TARGET_ARCH_LOCAL" != "arm64" ] && [ "$TARGET_ARCH_LOCAL" != "amd64" ]; then
  echo "Unsupported architecture $LOCAL_ARCH"
  exit 1
fi

# TARGET_ARCH, TARGET_OS is used by the Makefile to build the correct binaries
export TARGET_ARCH="${TARGET_ARCH_LOCAL}"
export TARGET_OS=linux
export GOOS=linux

echo "Setup Environment"
export REGISTRY_PORT=5000
export REGISTRY_NAME="kind-registry"
export DAPR_REGISTRY=localhost:5000/dapr
export DAPR_TAG=dev
export DAPR_NAMESPACE=dapr-tests
# Container registry where to cache e2e test images
export DAPR_CACHE_REGISTRY="dapre2eacr.azurecr.io"
export PULL_POLICY=IfNotPresent
export DAPR_GO_BUILD_TAGS=wfbackendsqlite

echo
echo "##################################################"
echo "# Setup Local Registry"
echo "##################################################"
echo

# disconnect the registry from the KinD network if it is already connected, so we can push images to it
docker network disconnect "kind" $REGISTRY_NAME || true

echo "Start registry if not running"
registry_running="$(docker container ls | grep kind-registry  || printf 'false')"
kind_running="$(kind get clusters | grep kind || printf 'false')"

if [ "${registry_running}" == "false" ]; then
  echo "check if port is available"
  netstat -an | grep $REGISTRY_PORT && echo "Registry port $REGISTRY_PORT is already in use" && exit 1

  echo "Starting registry"
  docker run -d --restart=always \
          -p $REGISTRY_PORT:$REGISTRY_PORT --name $REGISTRY_NAME registry:2
fi

echo
echo "##################################################"
echo "# Build Dapr and e2e app images and deploy to Kind"
echo "##################################################"
echo

if [ "${DAPR_E2E_BUILD_DAPR_SKIP}" != "true" ]; then
  echo "Build and push Dapr"
  make build-linux
  make docker-build
  make docker-push
else
  echo "Skipping building Dapr"
fi

echo "Build and push e2e app images"
if [ "${DAPR_E2E_BUILD_APP_SKIP}" != "true" ]; then
  make build-push-e2e-app-all
else
  echo "Skipping building e2e apps"
fi

echo
echo "###################################################"
echo "# Create Kind cluster and start kind load balancer"
echo "###################################################"
echo

echo "Setup Kind"
kind_k8s_version=v1.28.9

dapr_test_config_store="redis"

cat > kind.yaml <<EOF
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
- role: control-plane
  image: kindest/node:${kind_k8s_version}
- role: worker
  image: kindest/node:${kind_k8s_version}
- role: worker
  image: kindest/node:${kind_k8s_version}
- role: worker
  image: kindest/node:${kind_k8s_version}
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:$REGISTRY_PORT"]
    endpoint = ["http://$REGISTRY_NAME:$REGISTRY_PORT"]
EOF

if [ "${kind_running}" == "false" ]; then
  kind create cluster --config kind.yaml
  if [ "$(uname)" ==  "Linux" ]; then
    cloud-provider-kind &
  else
    sudo cloud-provider-kind &
  fi
fi

# Connect the registry to the KinD network.
docker network connect "kind" $REGISTRY_NAME

kubectl cluster-info --context kind-kind

NODE_IP=$(kubectl get nodes \
                -lkubernetes.io/hostname!=kind-control-plane \
                -ojsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
export MINIKUBE_NODE_IP=$NODE_IP

echo
echo "#################################################"
echo "# Setup Dapr and Supporting Services in Kind"
echo "#################################################"
echo

echo "Create namespace"
make create-test-namespace || true

echo "Deploy supporting services"
if [ "${DAPR_E2E_TEST_SKIP_SUPPORTING_SERVICES}" != "true" ]; then
  make setup-3rd-party || make setup-3rd-party # retry once
else
  echo "Skipping deploying supporting services"
fi

make docker-deploy-k8s

echo
echo "#################################################"
echo "# Run tests"
echo "#################################################"
echo

echo "Setup test components"
make setup-test-components

export DAPR_TEST_CONFIG_STORE="${dapr_test_config_store}"

echo "Run tests"
rm -f failed-tests.txt test-output.txt || true
make test-e2e-all 2>failed-tests.txt | tee test-output.txt || true

if [ -s failed-tests.txt ]; then
  echo "Failed tests:"
  cat failed-tests.txt
  # retry for a couple of strange flake issues
  # - connectivity: if we get context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  # - crazy error: command not found
  if grep -q "Client.Timeout exceeded while awaiting headers" test-output.txt; then
    echo "Found connectivity issue in test output"
    echo "Retrying failed tests because of connectivity issue"
    make test-e2e-all
  elif grep -q "Client.Timeout exceeded while awaiting headers" failed-tests.txt; then
    echo "Found connectivity issue in failed tests"
    echo "Retrying failed tests because of connectivity issue"
    make test-e2e-all
  elif grep -q "command not found" test-output.txt; then
    echo "Found command not found issue in test output"
    echo "Retrying failed tests because of connectivity issue"
    make test-e2e-all
  elif grep -q "command not found" failed-tests.txt; then
    echo "Found command not found issue in failed tests"
    echo "Retrying failed tests because of connectivity issue"
    make test-e2e-all
  else
    exit 1
  fi
fi
