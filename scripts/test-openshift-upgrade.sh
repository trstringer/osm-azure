#!/bin/bash

# This script creates an Azure RedHat OpenShift cluster.
set -aeo pipefail

# shellcheck disable=SC1091

if [[ -z "$ARC_ARO_DEV" ]]; then
    az login --identity > /dev/null 2>&1
fi

resource_name() {
    local PREFIX
    PREFIX="$1"
    echo "${PREFIX}$(date '+%Y%m%d%H%M%S')"
}

LOCATION="eastus"
ARC_LOCATION="eastus2euap"
PREFIX="arcosmaro"
RESOURCEGROUP=${ARO_RESOURCE_NAME:-$(resource_name "$PREFIX")}
CLUSTER="$RESOURCEGROUP"

echo "$(date) - Using resource group $RESOURCEGROUP and cluster $CLUSTER"

if [[ -z "$SKIP_PREP" ]]; then
    echo "$(date) - Installing oc"
    rm -rf ./oc
    mkdir ./oc
    curl -L --output ./oc/oc.tar.gz \
        "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz"
    tar -xvf ./oc/oc.tar.gz -C ./oc

    ./oc/oc version --client

    # az account set --subscription="$SUBSCRIPTION"

    echo "$(date) - Registering providers"

    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait

    echo "$(date) - Creating resource group"
    az group create \
      --name "$RESOURCEGROUP" \
      --location "$LOCATION"

    echo "$(date) - Creating vnet"
    az network vnet create \
       --resource-group "$RESOURCEGROUP" \
       --name aro-vnet \
       --address-prefixes 10.0.0.0/22


    echo "$(date) - Creating control-plane subnet"
    az network vnet subnet create \
      --resource-group "$RESOURCEGROUP" \
      --vnet-name aro-vnet \
      --name control-plane-subnet \
      --address-prefixes 10.0.0.0/23 \
      --service-endpoints Microsoft.ContainerRegistry

    echo "$(date) - Creating worker subnet"

    az network vnet subnet create \
      --resource-group "$RESOURCEGROUP" \
      --vnet-name aro-vnet \
      --name worker-subnet \
      --address-prefixes 10.0.2.0/23 \
      --service-endpoints Microsoft.ContainerRegistry

    echo "$(date) - Disable private link service network policies"

    az network vnet subnet update \
      --name control-plane-subnet \
      --resource-group "$RESOURCEGROUP" \
      --vnet-name aro-vnet \
      --disable-private-link-service-network-policies true

    echo "$(date) - Creating ARO Cluster ($CLUSTER) in rg ($RESOURCEGROUP)"

    az aro create \
      --resource-group "$RESOURCEGROUP" \
      --name "$CLUSTER" \
      --vnet aro-vnet \
      --master-subnet control-plane-subnet \
      --worker-subnet worker-subnet

    echo "$(date) - Logging into the cluster"
    ./oc/oc login \
        "$(az aro show \
            --resource-group "$RESOURCEGROUP" \
            --name "$CLUSTER" \
            --query "apiserverProfile.url" -o tsv)" \
        --username="$(az aro list-credentials \
            --resource-group "$RESOURCEGROUP" \
            --name "$CLUSTER" \
            --query kubeadminUsername -o tsv)" \
        --password="$(az aro list-credentials \
            --resource-group "$RESOURCEGROUP" \
            --name "$CLUSTER" \
            --query kubeadminPassword -o tsv)"

    kubectl get no

    echo "$(date) - Connecting the cluster to Arc"
    ./oc/oc adm policy \
        add-scc-to-user \
        privileged system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa

    az connectedk8s connect \
        --resource-group "$RESOURCEGROUP" \
        --name "$CLUSTER" \
        --location "$ARC_LOCATION"
fi

CHART_VERSIONS=$(az acr repository show-manifests \
    --name upstream \
    --repository oss/openservicemesh/osm-arc \
    --query 'sort_by(@,&timestamp)[?tags].{tag:tags[0],timestamp:timestamp}' -o table)

CHART_VERSION_CURRENT=$(echo "$CHART_VERSIONS" | tail -n 1 | awk '{print $1}')
CHART_VERSION_PREVIOUS=$(echo "$CHART_VERSIONS" | tail -n 2 | head -n 1 | awk '{print $1}')
echo "$(date) - Current chart version: $CHART_VERSION_CURRENT"
echo "$(date) - Previous chart version: $CHART_VERSION_PREVIOUS"

if [[ -z "$SKIP_PREP" ]]; then
    echo "$(date) - Installing chart version $CHART_VERSION_PREVIOUS"
    az k8s-extension create \
        --resource-group "$RESOURCEGROUP" \
        --cluster-name "$CLUSTER" \
        --cluster-type connectedClusters \
        --extension-type "microsoft.openservicemesh" \
        --scope cluster \
        --release-train staging \
        --version "$CHART_VERSION_PREVIOUS" \
        --name osm

    echo "$(date) - Running e2e tests for chart version $CHART_VERSION_PREVIOUS"
    EXTENSION_TAG="$CHART_VERSION_PREVIOUS" make test-e2e
fi

# This will only be done for versions up to 0.10.0.
OSM_VERSION="v$(yq -r '.dependencies[] | select(.name=="osm").version' ./charts/osm-arc/Chart.yaml)"
OSM_LOCATION="https://github.com/openservicemesh/osm.git"
echo "$(date) - Getting OSM version $OSM_VERSION from $OSM_LOCATION"

TEMP_OSM_REPO="/tmp/osm"
rm -rf "$TEMP_OSM_REPO"
git clone "$OSM_LOCATION" /tmp/osm
CWD=$(pwd)
cd "$TEMP_OSM_REPO"

git checkout "$OSM_VERSION"
kubectl delete --ignore-not-found --recursive -f ./charts/osm/crds/
kubectl apply -f charts/osm/crds/

cd "$CWD"
# End of pre 0.10.0 testing.

echo "$(date) - Installing chart version $CHART_VERSION_CURRENT"
az k8s-extension create \
    --resource-group "$RESOURCEGROUP" \
    --cluster-name "$CLUSTER" \
    --cluster-type connectedClusters \
    --extension-type "microsoft.openservicemesh" \
    --scope cluster \
    --release-train staging \
    --version "$CHART_VERSION_CURRENT" \
    --name osm

echo "$(date) - Running e2e tests for chart version $CHART_VERSION_CURRENT"
EXTENSION_TAG="$CHART_VERSION_CURRENT" make test-e2e

if [[ -z "$SKIP_CLEANUP" ]]; then
    echo "$(date) - Cleanup"
    az group delete -y --no-wait -n "$RESOURCEGROUP"
fi

rm -rf ./oc
rm -rf /tmp/osm

echo "$(date) - Tests completed successfully"
